#!/bin/bash
# Build Jarvis (OpenWhisper target) and package into .app bundle cleanly
set -e

cd "$(dirname "$0")"

echo "==> Cleaning old build artifacts and processes..."
pkill -9 -x OpenWhisper 2>/dev/null || true
rm -rf build

echo "==> Building OpenWhisper via SwiftPM..."
swift build -c debug

BIN_DIR="$(swift build -c debug --show-bin-path)"
APP_BUNDLE="build/Jarvis.app"
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

# WebRTC AEC3 and Abseil are statically linked. Keep their required notices in the app bundle.
AEC_NOTICE_DIR="$APP_DIR/Resources/ThirdPartyLicenses"
mkdir -p "$AEC_NOTICE_DIR"
cp Vendor/WebRTCAEC/LICENSE.webrtc "$AEC_NOTICE_DIR/WebRTC-LICENSE.txt"
cp Vendor/WebRTCAEC/PATENTS.webrtc "$AEC_NOTICE_DIR/WebRTC-PATENTS.txt"
cp Vendor/WebRTCAEC/LICENSE.abseil "$AEC_NOTICE_DIR/Abseil-LICENSE.txt"

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

# Local voice for spoken replies (OmniVoice): keep the installed server script and reference
# voice in sync with the repo. The Python venv itself comes from tts_server/setup.sh (once).
TTS_DEST="$HOME/Library/Application Support/OpenWhisper/tts"
if [ -x "$TTS_DEST/.venv/bin/python" ]; then
    cp tts_server/server.py tts_server/jarvis_ref.wav "$TTS_DEST/"
    echo "==> Updated local voice server in $TTS_DEST"
else
    echo "NOTE: Local voice not installed; Jarvis's spoken replies stay silent until you run tts_server/setup.sh"
fi

# Experimental local voice (Settings › Sesli cevap › EMA Lightning): keep the installed server
# script in sync. The venv and the model come from tts_ema_server/setup.sh (once).
EMA_DEST="$HOME/Library/Application Support/OpenWhisper/tts-ema"
if [ -x "$EMA_DEST/.venv/bin/python" ]; then
    cp tts_ema_server/server.py "$EMA_DEST/"
    echo "==> Updated EMA Lightning server in $EMA_DEST"
fi

# Default local voice (Settings › Sesli cevap › Pocket TTS): keep the installed server
# script and the Jarvis reference in sync. The venv and the model come from
# tts_pocket_server/setup.sh (once).
POCKET_DEST="$HOME/Library/Application Support/OpenWhisper/tts-pocket"
if [ -x "$POCKET_DEST/.venv/bin/python" ]; then
    cp tts_pocket_server/server.py tts_server/jarvis_ref.wav "$POCKET_DEST/"
    echo "==> Updated Pocket TTS server in $POCKET_DEST"
else
    echo "NOTE: Default voice (Pocket TTS) not installed; spoken replies stay silent until you run tts_pocket_server/setup.sh"
fi

# English voice (Settings › Sesli cevap › Piper Jarvis): keep the installed server script in
# sync. The venv and the model come from tts_piper_server/setup.sh (once).
PIPER_DEST="$HOME/Library/Application Support/OpenWhisper/tts-piper"
if [ -x "$PIPER_DEST/.venv/bin/python" ]; then
    cp tts_piper_server/server.py "$PIPER_DEST/"
    echo "==> Updated Piper Jarvis server in $PIPER_DEST"
fi

# Alternative speech model (Settings › Konuşma modeli › Qwen3-ASR): keep the installed server
# script in sync. The venv and the model come from asr_server/setup.sh (once).
ASR_DEST="$HOME/Library/Application Support/OpenWhisper/asr"
if [ -x "$ASR_DEST/.venv/bin/python" ]; then
    cp asr_server/server.py "$ASR_DEST/"
    echo "==> Updated Qwen3-ASR server in $ASR_DEST"
fi

# SetFit decision models (Settings › Karar motoru): keep the installed server script in sync.
# The venv and the trained models come from decision_model/install.sh (retrain.sh runs it).
DECIDER_DEST="$HOME/Library/Application Support/OpenWhisper/decider"
if [ -x "$DECIDER_DEST/.venv/bin/python" ]; then
    cp ../decision_model/server.py "$DECIDER_DEST/"
    echo "==> Updated SetFit decision server in $DECIDER_DEST"
else
    echo "NOTE: SetFit decision models not installed; 'Karar motoru: SetFit' needs decision_model/install.sh"
fi

install_app() {
    if [ "${SKIP_INSTALL:-}" != "1" ]; then
        echo "==> Installing to /Applications..."
        # The app was called OpenWhisper before; drop that copy so only one is installed.
        rm -rf /Applications/OpenWhisper.app /Applications/Jarvis.app
        cp -R "$APP_BUNDLE" /Applications/
        echo "  Installed at /Applications/Jarvis.app"

        echo "==> Launching newly installed Jarvis..."
        open /Applications/Jarvis.app
    fi
}

echo "Done! App bundle at: build/Jarvis.app"
install_app
echo ""
