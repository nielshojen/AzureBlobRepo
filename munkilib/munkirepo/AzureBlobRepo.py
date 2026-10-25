# encoding: utf-8
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       https://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
"""Defines AzureBlobRepo plugin. See docstring for AzureBlobRepo class

Python counterpart of the Munki 7 AzureBlobRepo.plugin, for tools that
still load Python repo plugins from munkilib/munkirepo (e.g. AutoPkg's
MunkiImporter). Both share repo URL forms and credential env vars.
"""

import base64
import hashlib
import hmac
import os
import shutil
import subprocess
import xml.etree.ElementTree as ElementTree
from email.utils import formatdate
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

from munkilib.munkirepo import Repo, RepoError

API_VERSION = "2021-08-06"
# Files larger than this are uploaded as blocks of this size
BLOCK_SIZE = 64 * 1024 * 1024
TIMEOUT = 300


class AzureBlobRepo(Repo):
    """Class for working with a repo in an Azure Blob Storage container.

    Supported repo URLs:
      https://<account>.blob.core.windows.net/<container>[/path/to/repo]
        (any host containing ".blob.", e.g. sovereign clouds)
      http(s)://<host>[:port]/<account>/<container>[/path/to/repo]
        (path-style, e.g. Azurite)

    Credentials come from the environment, first match wins:
      AZURE_STORAGE_SAS_TOKEN: a SAS token for the container or account
      AZURE_STORAGE_KEY: the storage account key (Shared Key auth)
      otherwise a Microsoft Entra ID token from `az account get-access-token`
    """

    # pylint: disable=super-init-not-called
    def __init__(self, baseurl):
        """Constructor"""
        parts = urlsplit(baseurl)
        if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
            raise RepoError("Repo URL must be http(s)://<host>/...: %s" % baseurl)
        segments = [segment for segment in parts.path.split("/") if segment]
        # Path-style URLs carry the account as the first path segment
        path_style = ".blob." not in parts.hostname.lower()
        container_index = 1 if path_style else 0
        if len(segments) <= container_index:
            raise RepoError(
                "Repo URL must include %sa container name: %s"
                % ("an account and " if path_style else "", baseurl)
            )
        self.account = segments[0] if path_style else parts.hostname.split(".")[0]
        self.container_path = "/" + "/".join(
            quote(segment, safe="") for segment in segments[: container_index + 1]
        )
        self.prefix = "/".join(segments[container_index + 1 :])
        self.endpoint = "%s://%s" % (parts.scheme.lower(), parts.netloc)
        self.sas_token, self.shared_key, self.bearer_token = _credentials()
    # pylint: enable=super-init-not-called

    def itemlist(self, kind):
        """Returns identifiers relative to kind, recursively, like FileRepo"""
        list_prefix = self._full_name(kind) + "/"
        names = []
        marker = ""
        while True:
            query = {"restype": "container", "comp": "list", "prefix": list_prefix}
            if marker:
                query["marker"] = marker
            root = ElementTree.fromstring(self._request("GET", None, query=query))
            for name in root.iterfind("./Blobs/Blob/Name"):
                relative_name = (name.text or "")[len(list_prefix) :]
                if relative_name:
                    names.append(relative_name)
            marker = root.findtext("NextMarker") or ""
            if not marker:
                return names

    def get(self, resource_identifier):
        """Returns the content of item with given resource_identifier"""
        return self._request("GET", self._full_name(resource_identifier))

    def get_to_local_file(self, resource_identifier, local_file_path):
        """Saves the content of item with given resource_identifier to
        local_file_path"""
        self._request(
            "GET", self._full_name(resource_identifier), to_file=local_file_path
        )

    def put(self, resource_identifier, content):
        """Stores content on the repo based on resource_identifier"""
        if isinstance(content, str):
            content = content.encode("utf-8")
        self._request(
            "PUT",
            self._full_name(resource_identifier),
            headers={
                "Content-Type": "application/octet-stream",
                "x-ms-blob-type": "BlockBlob",
            },
            body=content,
            content_length=len(content),
        )

    def put_from_local_file(self, resource_identifier, local_file_path):
        """Copies the content of local_file_path to the repo based on
        resource_identifier"""
        blob = self._full_name(resource_identifier)
        try:
            size = os.path.getsize(local_file_path)
            fileobj = open(local_file_path, "rb")
        except OSError as err:
            raise RepoError(err) from err
        with fileobj:
            if size <= BLOCK_SIZE:
                self._request(
                    "PUT",
                    blob,
                    headers={
                        "Content-Type": "application/octet-stream",
                        "x-ms-blob-type": "BlockBlob",
                    },
                    body=fileobj,
                    content_length=size,
                )
                return
            # A single Put Blob is capped at 5000 MiB, which large installers
            # (e.g. Xcode) exceed; blocks also keep memory use to one block.
            block_ids = []
            while True:
                chunk = fileobj.read(BLOCK_SIZE)
                if not chunk:
                    break
                block_id = base64.b64encode(b"%06d" % len(block_ids)).decode("ascii")
                self._request(
                    "PUT",
                    blob,
                    query={"comp": "block", "blockid": block_id},
                    headers={"Content-Type": "application/octet-stream"},
                    body=chunk,
                    content_length=len(chunk),
                )
                block_ids.append(block_id)
        block_list = (
            '<?xml version="1.0" encoding="utf-8"?><BlockList>'
            + "".join("<Latest>%s</Latest>" % block_id for block_id in block_ids)
            + "</BlockList>"
        ).encode("utf-8")
        self._request(
            "PUT",
            blob,
            query={"comp": "blocklist"},
            headers={"Content-Type": "application/xml"},
            body=block_list,
            content_length=len(block_list),
        )

    def delete(self, resource_identifier):
        """Deletes a repo object located by resource_identifier"""
        self._request("DELETE", self._full_name(resource_identifier))

    def _full_name(self, identifier):
        return "%s/%s" % (self.prefix, identifier) if self.prefix else identifier

    def _request(
        self,
        method,
        blob,
        query=None,
        headers=None,
        body=None,
        content_length=0,
        to_file=None,
    ):
        """Sends an authorized request for the container (blob is None) or a
        blob in it. Returns the response body, or writes it to to_file."""
        query = query or {}
        path = self.container_path + ("/" + quote(blob, safe="/") if blob else "")
        query_parts = [
            "%s=%s" % (quote(key, safe=""), quote(value, safe=""))
            for key, value in sorted(query.items())
        ]
        if self.sas_token:
            query_parts.append(self.sas_token)
        url = self.endpoint + path + ("?" + "&".join(query_parts) if query_parts else "")

        all_headers = dict(headers or {})
        all_headers["x-ms-version"] = API_VERSION
        all_headers["x-ms-date"] = formatdate(usegmt=True)
        if content_length:
            all_headers["Content-Length"] = str(content_length)
        if self.bearer_token:
            all_headers["Authorization"] = "Bearer %s" % self.bearer_token
        elif self.shared_key:
            string_to_sign = self._string_to_sign(
                method, path, query, all_headers, content_length
            )
            signature = hmac.new(
                self.shared_key, string_to_sign.encode("utf-8"), hashlib.sha256
            ).digest()
            all_headers["Authorization"] = "SharedKey %s:%s" % (
                self.account,
                base64.b64encode(signature).decode("ascii"),
            )

        request = Request(url, data=body, headers=all_headers, method=method)
        try:
            with urlopen(request, timeout=TIMEOUT) as response:
                if to_file:
                    with open(to_file, "wb") as fileobj:
                        shutil.copyfileobj(response, fileobj)
                    return None
                return response.read()
        except HTTPError as err:
            code = ""
            try:
                code = ElementTree.fromstring(err.read()).findtext("Code") or ""
            except ElementTree.ParseError:
                pass
            raise RepoError(
                "HTTP %s %s for %s" % (err.code, code or err.reason, blob or "container")
            ) from err
        except (URLError, OSError) as err:
            raise RepoError("%s for %s" % (err, blob or "container")) from err

    def _string_to_sign(self, method, path, query, headers, content_length):
        """Shared Key string-to-sign, see
        https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key"""
        lower_headers = {key.lower(): value for key, value in headers.items()}
        canonical_headers = "".join(
            sorted(
                "%s:%s\n" % (key, value)
                for key, value in lower_headers.items()
                if key.startswith("x-ms-")
            )
        )
        canonical_resource = "/%s%s" % (self.account, path) + "".join(
            "\n%s:%s" % (key.lower(), value) for key, value in sorted(query.items())
        )
        return (
            "\n".join(
                [
                    method,
                    lower_headers.get("content-encoding", ""),
                    lower_headers.get("content-language", ""),
                    str(content_length) if content_length else "",
                    lower_headers.get("content-md5", ""),
                    lower_headers.get("content-type", ""),
                    "",  # Date (x-ms-date is used instead)
                    lower_headers.get("if-modified-since", ""),
                    lower_headers.get("if-match", ""),
                    lower_headers.get("if-none-match", ""),
                    lower_headers.get("if-unmodified-since", ""),
                    lower_headers.get("range", ""),
                ]
            )
            + "\n"
            + canonical_headers
            + canonical_resource
        )


def _credentials():
    """Returns (sas_token, shared_key, bearer_token) with exactly one set"""
    sas = os.environ.get("AZURE_STORAGE_SAS_TOKEN", "")
    if sas:
        return sas[1:] if sas.startswith("?") else sas, None, None
    key = os.environ.get("AZURE_STORAGE_KEY", "")
    if key:
        try:
            return None, base64.b64decode(key, validate=True), None
        except ValueError as err:
            raise RepoError("AZURE_STORAGE_KEY is not valid base64") from err
    return None, None, _az_cli_access_token()


def _az_cli_access_token():
    """Gets an Entra ID token for Azure Storage from the Azure CLI's login"""
    failure = "Set AZURE_STORAGE_SAS_TOKEN or AZURE_STORAGE_KEY, or run `az login`"
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"
    try:
        result = subprocess.run(
            [
                "az", "account", "get-access-token",
                "--resource", "https://storage.azure.com/",
                "--query", "accessToken", "--output", "tsv",
            ],
            capture_output=True, text=True, env=env, check=False,
        )
    except OSError as err:
        raise RepoError("Could not run the Azure CLI (%s). %s" % (err, failure)) from err
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        raise RepoError(
            "Could not get an access token from the Azure CLI: %s. %s"
            % (result.stderr.strip(), failure)
        )
    return token
