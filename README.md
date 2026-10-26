# AzureBlobRepo

This project provides a [repo plugin](https://github.com/munki/munki/blob/main/code/cli/munki/munkiimport/munkiimport.swift#L190) for Munki 7 to work with an Azure Blob Storage backend.

It is modeled on [S3Repo](https://github.com/discentem/s3repo), but talks to the Blob service REST API directly, so it has no third-party dependencies.

## Install

Download `AzureBlobRepoPlugin-<version>.pkg` from [Releases](https://github.com/nielshojen/AzureBlobRepo/releases) and install it. The plugin is built for Apple silicon (arm64) only.

To build the package yourself:

```sh
./scripts/build-plugin-package.sh
sudo installer -pkg build/AzureBlobRepoPlugin-<version>.pkg -target /
```

The package version is the latest `v*` git tag (or `0.0.0-dev` before the first one). Set `VERSION` to override it.

The package installs two plugins:

- `/usr/local/munki/repoplugins/AzureBlobRepo.plugin`: the Munki 7 plugin (a dylib), used by the Munki admin tools.
- `/usr/local/munki/munkilib/munkirepo/AzureBlobRepo.py`: a Python version of the same plugin for AutoPkg's MunkiImporter, which loads only Python repo plugins. It uses the same repo URLs and credentials.

## Usage

Pass `--plugin AzureBlobRepo` and the container URL to munkiimport, makecatalogs, repoclean or iconimporter, or set them once with `munkiimport --configure`. manifestutil takes no `--plugin` flag and reads only the `--configure` settings; it is untested.

```sh
munkiimport --plugin AzureBlobRepo \
    --repo-url https://<account>.blob.core.windows.net/<container>[/path/to/repo] \
    Firefox.pkg
```

Supported repo URLs:

| Form | Example |
| --- | --- |
| Account host (any host containing `.blob.`, including sovereign clouds) | `https://contoso.blob.core.windows.net/munki` |
| Path-style, with the account as the first path segment | `http://127.0.0.1:10000/devstoreaccount1/munki` (Azurite) |

The container must already exist. Repo directories (`pkgs/`, `pkgsinfo/`, `catalogs/` and so on) are blob name prefixes, so you don't need to create them.

### Authentication

The plugin reads credentials from the environment. The first match wins:

1. `AZURE_STORAGE_SAS_TOKEN`: a SAS token for the container or the account. It needs read, add, create, write, delete and list permissions (`racwdl`).
2. `AZURE_STORAGE_KEY`: the storage account key, used for Shared Key auth.
3. Otherwise, a Microsoft Entra ID token from `az account get-access-token`. Run `az login` first. You also need the **Storage Blob Data Contributor** role on the container.

Keep secrets out of the repo URL. Munki stores that URL in its preferences and prints it in output.

### AutoPkg

MunkiImporter loads `AzureBlobRepo.py` from munkilib, which comes from Munki's `munkitools_pythonlibs` package. `MUNKILIB_DIR` defaults to `/usr/local/munki`, so you don't need to set it.

```sh
defaults write com.github.autopkg MUNKI_REPO "https://<account>.blob.core.windows.net/<container>"
defaults write com.github.autopkg MUNKI_REPO_PLUGIN AzureBlobRepo
```

Credentials are not AutoPkg settings. Set the environment variables above in the environment AutoPkg runs in, or run `az login` as the user that runs AutoPkg.

MunkiImporter reads `catalogs/all` before it imports anything, and fails on a new, empty repo with `HTTP 404 BlobNotFound for catalogs/all`. This happens with every repo plugin. Create an empty catalog once:

```sh
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><array/></plist>\n' > all.plist
az storage blob upload --account-name <account> --container-name <container> \
    --name catalogs/all --file all.plist --auth-mode login
```

MunkiImporter doesn't rebuild catalogs. Run `makecatalogs --plugin AzureBlobRepo --repo-url <url>` after your AutoPkg run.

### Notes

- Files over 64 MiB are uploaded in 64 MiB blocks. This keeps memory use low and lifts the 5000 MiB limit of a single upload, so large installers like Xcode work.
- `pathFor()` returns `nil`, as the Munki protocol asks of non-filesystem repos. Tools that need a local copy of a pkg (such as iconimporter) download it. makecatalogs' pkg check works without `--skip-pkg-check`.
- Storage accounts with a hierarchical namespace (ADLS Gen2) are untested.

## Releases

Push a version tag to release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The [release workflow](.github/workflows/release.yml) runs the tests, builds `AzureBlobRepoPlugin-1.1.0.pkg` and attaches it to a new GitHub release with generated notes.

## Tests

```sh
swift test                    # unit tests
./scripts/run-all-tests.sh    # full run; needs sudo
```

`run-all-tests.sh` runs the unit tests. It then installs munkitools and the plugin package, starts the [Azurite](https://github.com/Azure/Azurite) emulator, and runs `scripts/test-e2e.sh`. That script tests these tools against Azurite:

- munkiimport, makecatalogs, iconimporter and repoclean, with Shared Key auth and with names that contain spaces.
- A multi-block upload with SAS auth.
- The Python plugin: multi-block upload, download, list, put, get and delete. It is skipped if munkilib isn't installed.

GitHub Actions runs the same flow (see [.github/workflows/test.yml](.github/workflows/test.yml)).

To run the end-to-end tests without installing anything system-wide:

1. Copy the Munki tools into a directory.
2. Create a `repoplugins/` directory next to them, and put `AzureBlobRepo.plugin` in it.
3. Run the tests:

```sh
AZURITE_PID=$(./scripts/start-azurite.sh)
MUNKI_DIR=/path/to/that/dir ./scripts/test-e2e.sh
kill $AZURITE_PID
```

## How are repo plugins different than Munki Middleware?

### Middleware
[Munki Middleware](https://github.com/munki/munki/wiki/Middleware#munki-7-notes) is installed on Munki _clients_ so that the clients can alter an HTTP(S) request to work with servers (often cloud-based) that require specific headers, keys, or encrypted/signed requests.

### Repo Plugins

[Repo plugins](https://github.com/munki/munki/wiki/Repo-Plugins) allow the Munki command-line admin tools (specifically munkiimport, makecatalogs, iconimporter, manifestutil) to work with a repo that's not just a locally-available filesystem.
