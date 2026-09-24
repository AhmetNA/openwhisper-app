#!/bin/bash
# Build OpenWhisper and package into .app bundle cleanly
set -e

cd "$(dirname "$0")"

echo "==> Cleaning old build artifacts and processes..."
pkill -9 -x OpenWhisper 2>/dev/null || true
rm -rf build

echo "==> Building OpenWhisper via SwiftPM..."
swift build -c debug

BIN_DIR="$(swift build -c debug --show-bin-path)"
APP_BUNDLE="build/OpenWhisper.app"
APP_DIR="$APP_BUNDLE/Contents"
EXEC_SRC="$BIN_DIR/OpenWhisper"
BUNDLE_SRC="$BIN_DIR/OpenWhisper_OpenWhisper.bundle"

# Create the app bundle layout
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
cp "OpenWhisper/Info.plist" "$APP_DIR/Info.plist"

# DeepFilterNet 3 (libdf.dylib, capi build) — vendored native library + model. The dylib's
# install name is @rpath/libdf.dylib and the executable already carries an @loader_path rpath
# (set by SwiftPM), so placing it next to the executable is enough for it to be found.
DF_LIB_SRC="Vendor/DeepFilter/lib/libdf.dylib"
DF_MODEL_SRC="Vendor/DeepFilter/model/DeepFilterNet3_onnx.tar.gz"
if [ ! -f "$DF_LIB_SRC" ] || [ ! -f "$DF_MODEL_SRC" ]; then
    echo "ERROR: Missing DeepFilterNet vendor files ($DF_LIB_SRC / $DF_MODEL_SRC)"
    exit 1
fi
cp "$DF_MODEL_SRC" "$APP_DIR/Resources/DeepFilterNet3_onnx.tar.gz"

# Copy executable
cp "$EXEC_SRC" "$APP_DIR/MacOS/OpenWhisper"
# SwiftPM stamps the binary with sdk == deployment target (14.0), which makes macOS
# run it in compatibility mode and disables Liquid Glass. Re-stamp with the real SDK.
SDK_VERSION="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
    -output "$APP_DIR/MacOS/OpenWhisper" "$APP_DIR/MacOS/OpenWhisper"
cp "$DF_LIB_SRC" "$APP_DIR/MacOS/libdf.dylib"

# Copy resource bundle if exists
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP_DIR/Resources/"
fi

# Copy app icon and set in Info.plist
cp "OpenWhisper/Resources/AppIcon.icns" "$APP_DIR/Resources/AppIcon.icns" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_DIR/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Info.plist"

# Copy any framework dependencies
if [ -d ".build/debug/PackageFrameworks" ]; then
    mkdir -p "$APP_DIR/Frameworks"
    cp -R .build/debug/PackageFrameworks/* "$APP_DIR/Frameworks/" 2>/dev/null || true
fi

# Sign with stable Apple identity (or fallback to ad-hoc)
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:|Developer ID Application:/{print $2; exit}')"
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "WARNING: No Apple signing identity found. Falling back to ad-hoc signing (-)."
    SIGNING_IDENTITY="-"
fi

echo "==> Signing with '$SIGNING_IDENTITY'..."
codesign --force --deep --options runtime \
    --entitlements OpenWhisper/OpenWhisper.entitlements \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

install_app() {
    if [ "${SKIP_INSTALL:-}" != "1" ]; then
        echo "==> Installing to /Applications..."
        rm -rf /Applications/OpenWhisper.app
        cp -R "$APP_BUNDLE" /Applications/
        echo "  Installed at /Applications/OpenWhisper.app"

        echo "==> Launching newly installed OpenWhisper..."
        open /Applications/OpenWhisper.app
    fi
}

echo "Done! App bundle at: build/OpenWhisper.app"
install_app
echo ""
