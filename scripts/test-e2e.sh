#!/bin/bash
# End-to-end test of the AzureBlobRepo plugin against a running Azurite:
# munkiimport, makecatalogs, iconimporter and repoclean with Shared Key auth,
# plus a multi-block upload with SAS auth, and the Python plugin (for AutoPkg).
#
# MUNKI_DIR is the directory holding the Munki tools and a repoplugins/
# directory with AzureBlobRepo.plugin (default: /usr/local/munki).

set -e

MUNKI_DIR="${MUNKI_DIR:-/usr/local/munki}"
CONTAINER="munki-repo"
# Azurite's well-known development account and key
ACCOUNT="devstoreaccount1"
ACCOUNT_KEY="Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
BLOB_ENDPOINT="http://127.0.0.1:10000/$ACCOUNT"
REPO_URL="$BLOB_ENDPOINT/$CONTAINER"
CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=$ACCOUNT;AccountKey=$ACCOUNT_KEY;BlobEndpoint=$BLOB_ENDPOINT;"

if [ ! -f "$MUNKI_DIR/repoplugins/AzureBlobRepo.plugin" ]; then
    echo "❌ Error: $MUNKI_DIR/repoplugins/AzureBlobRepo.plugin not found"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    echo "❌ $1"
    exit 1
}

blob_names() {
    az storage blob list --container-name "$CONTAINER" --connection-string "$CONNECTION_STRING" \
        --query "[].name" --output tsv --only-show-errors
}

# Runs a Munki tool against the repo with a 120 second timeout
# (macOS has no GNU `timeout`)
munki() {
    local tool="$1"
    shift
    "$MUNKI_DIR/$tool" "$@" --plugin AzureBlobRepo --repo-url "$REPO_URL" &
    local pid=$!
    ( sleep 120; kill -TERM "$pid" 2>/dev/null && echo "ERROR: $tool timed out" ) &
    local watcher=$!
    local status=0
    wait "$pid" || status=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return $status
}

make_pkg() { # identifier version size-in-bytes output
    local root="$WORK_DIR/root-$1-$2"
    mkdir -p "$root/private/tmp/$1"
    head -c "$3" /dev/urandom > "$root/private/tmp/$1/payload"
    pkgbuild --quiet --root "$root" --identifier "$1" --version "$2" "$4"
}

echo "=== Creating container $CONTAINER ==="
az storage container create --name "$CONTAINER" --connection-string "$CONNECTION_STRING" \
    --output none --only-show-errors

export AZURE_STORAGE_KEY="$ACCOUNT_KEY"

echo "=== munkiimport (Shared Key), names with spaces ==="
for VERSION in 1.0 1.1 1.2; do
    PKG="$WORK_DIR/Test App-$VERSION.pkg"
    make_pkg com.example.testapp "$VERSION" 1024 "$PKG"
    munki munkiimport "$PKG" -n --subdirectory "Test Apps" --extract-icon || fail "munkiimport $VERSION failed"
done

echo "=== makecatalogs (with pkg check) ==="
OUTPUT=$(munki makecatalogs 2>&1) || fail "makecatalogs failed: $OUTPUT"
echo "$OUTPUT"
echo "$OUTPUT" | grep -q "WARNING\|rror" && fail "makecatalogs reported problems"
blob_names | grep -qx "catalogs/all" || fail "catalogs/all missing"

echo "=== iconimporter (downloads pkgs) ==="
munki iconimporter || fail "iconimporter failed"

echo "=== repoclean --keep 1 --auto ==="
munki repoclean --keep 1 --auto || fail "repoclean failed"
REMAINING=$(blob_names | grep "^pkgs" | sort)
EXPECTED=$(printf '%s\n' "pkgs/Test Apps/Test App-1.2.pkg" "pkgsinfo/Test Apps/Test App-1.2")
[ "$REMAINING" = "$EXPECTED" ] || fail "unexpected items after repoclean:
$REMAINING"

echo "=== munkiimport (SAS) of a multi-block package ==="
unset AZURE_STORAGE_KEY
AZURE_STORAGE_SAS_TOKEN=$(az storage container generate-sas --name "$CONTAINER" --permissions racwdl \
    --expiry "$(date -u -v+1H +%Y-%m-%dT%H:%MZ)" --connection-string "$CONNECTION_STRING" \
    --output tsv --only-show-errors)
export AZURE_STORAGE_SAS_TOKEN
BIG_PKG="$WORK_DIR/BigApp-2.0.pkg"
make_pkg com.example.bigapp 2.0 150000000 "$BIG_PKG"
munki munkiimport "$BIG_PKG" -n --extract-icon || fail "munkiimport of large package failed"
az storage blob download --container-name "$CONTAINER" --name "pkgs/BigApp-2.0.pkg" \
    --file "$WORK_DIR/downloaded.pkg" --connection-string "$CONNECTION_STRING" --output none --only-show-errors
cmp -s "$BIG_PKG" "$WORK_DIR/downloaded.pkg" || fail "uploaded large package does not match"

echo "=== Python plugin (SAS): multi-block upload, download, list, put, get, delete ==="
# MUNKILIB_DIR holds munkilib (with munkirepo/AzureBlobRepo.py); default /usr/local/munki
MUNKILIB_DIR="${MUNKILIB_DIR:-/usr/local/munki}"
# munkilib itself comes from the munkitools_pythonlibs package, which may be absent
if [ -f "$MUNKILIB_DIR/munkilib/munkirepo/__init__.py" ] && [ -f "$MUNKILIB_DIR/munkilib/munkirepo/AzureBlobRepo.py" ]; then
    /usr/bin/python3 -I - "$MUNKILIB_DIR" "$REPO_URL" "$BIG_PKG" "$WORK_DIR/python-downloaded.pkg" <<'PYEOF' || fail "Python plugin test failed"
import filecmp
import sys

sys.path.insert(0, sys.argv[1])
from munkilib import munkirepo

repo_url, big_pkg, downloaded = sys.argv[2:5]
repo = munkirepo.connect(repo_url, "AzureBlobRepo")
repo.put_from_local_file("pkgs/Python Big.pkg", big_pkg)
repo.get_to_local_file("pkgs/Python Big.pkg", downloaded)
assert filecmp.cmp(big_pkg, downloaded, shallow=False), "downloaded package differs"
assert "Python Big.pkg" in repo.itemlist("pkgs"), "uploaded package not listed"
repo.put("manifests/python test", b"<plist/>")
assert repo.get("manifests/python test") == b"<plist/>", "manifest content differs"
repo.delete("pkgs/Python Big.pkg")
repo.delete("manifests/python test")
try:
    repo.get("manifests/python test")
    raise AssertionError("deleted manifest still readable")
except munkirepo.RepoError:
    pass
PYEOF
else
    echo "⚠ Skipped: munkilib or AzureBlobRepo.py not found in $MUNKILIB_DIR/munkilib/munkirepo"
fi

echo ""
echo "✓ All end-to-end tests passed"
