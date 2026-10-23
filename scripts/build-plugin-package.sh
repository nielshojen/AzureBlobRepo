#!/bin/bash
# Builds AzureBlobRepo.plugin (universal) and packages it as
# build/AzureBlobRepoPlugin-<version>.pkg, installing to /usr/local/munki/repoplugins

set -e

VERSION="${VERSION:-1.0.0}"
IDENTIFIER="com.github.nielshojen.azureblobrepo"
PKG_PATH="build/AzureBlobRepoPlugin-$VERSION.pkg"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "Building AzureBlobRepo plugin..."
BUILD_ARGS=(-c release --product AzureBlobRepo --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}"
DYLIB_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/libAzureBlobRepo.dylib"

if [ ! -f "$DYLIB_PATH" ]; then
    echo "❌ Error: built dylib not found at $DYLIB_PATH"
    exit 1
fi

PAYLOAD_DIR="build/payload"
rm -rf "$PAYLOAD_DIR"
# Remove packages from earlier builds so build/ holds only this version
rm -f build/AzureBlobRepoPlugin*.pkg
mkdir -p "$PAYLOAD_DIR/usr/local/munki/repoplugins"
# Munki loads plugins by name: --plugin AzureBlobRepo -> AzureBlobRepo.plugin
cp "$DYLIB_PATH" "$PAYLOAD_DIR/usr/local/munki/repoplugins/AzureBlobRepo.plugin"
chmod -R 755 "$PAYLOAD_DIR/usr"

pkgbuild \
    --root "$PAYLOAD_DIR" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    "$PKG_PATH"

echo ""
echo "✓ Package created: $PKG_PATH"
echo ""
echo "To install:"
echo "  sudo installer -pkg $PKG_PATH -target /"
