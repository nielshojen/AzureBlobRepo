# AzureBlobRepo

This project provides a [repo plugin](https://github.com/munki/munki/blob/main/code/cli/munki/munkiimport/munkiimport.swift#L190) for Munki 7 to work with an Azure Blob Storage backend.

It is modeled on [S3Repo](https://github.com/discentem/s3repo), but talks to the Blob service REST API directly, so it has no third-party dependencies.

## Install

Build the package and install it. Building needs Xcode, because the plugin is a universal binary:

```sh
./scripts/build-plugin-package.sh
sudo installer -pkg build/AzureBlobRepoPlugin-1.0.0.pkg -target /
```

This puts `AzureBlobRepo.plugin` into `/usr/local/munki/repoplugins/`.

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

### Notes

- Files over 64 MiB are uploaded in 64 MiB blocks. This keeps memory use low and lifts the 5000 MiB limit of a single upload, so large installers like Xcode work.
- `pathFor()` returns `nil`, as the Munki protocol asks of non-filesystem repos. Tools that need a local copy of a pkg (such as iconimporter) download it. makecatalogs' pkg check works without `--skip-pkg-check`.
- Storage accounts with a hierarchical namespace (ADLS Gen2) are untested.

## Tests

```sh
swift test                    # unit tests
./scripts/run-all-tests.sh    # full run; needs sudo
```

`run-all-tests.sh` runs the unit tests. It then installs munkitools and the plugin package, starts the [Azurite](https://github.com/Azure/Azurite) emulator, and runs `scripts/test-e2e.sh`. That script tests these tools against Azurite:

- munkiimport, makecatalogs, iconimporter and repoclean, with Shared Key auth and with names that contain spaces.
- A multi-block upload with SAS auth.

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
