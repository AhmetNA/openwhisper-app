#!/bin/bash
# Build Jarvis (OpenWhisper target) and package into .app bundle cleanly
set -e

cd "$(dirname "$0")"

echo "==> Cleaning old build artifacts..."
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

# Updates must retain the installed app's designated requirement (macOS code identity).
# Never silently replace a certificate-signed installation with an ad-hoc build.
INSTALLED_APP="/Applications/Jarvis.app"
PREVIOUS_REQUIREMENT=""
if [ -d "$INSTALLED_APP" ]; then
    PREVIOUS_REQUIREMENT="$(codesign -d -r- "$INSTALLED_APP" 2>&1 | sed -n 's/^designated => //p')"
    if [ -z "$PREVIOUS_REQUIREMENT" ]; then
        echo "ERROR: Cannot read the installed Jarvis code identity; leaving it untouched."
        exit 1
    fi
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    # Prefer the existing signer even when several development certificates are available.
    INSTALLED_SIGNER="$(codesign -dv "$INSTALLED_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
    SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' -v signer="$INSTALLED_SIGNER" '$2 == signer && signer != "" {print $2; exit}')"
    if [ -z "$SIGNING_IDENTITY" ]; then
        SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Apple Development:|Developer ID Application:/{print $2; exit}')"
    fi
fi
if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "ERROR: A stable signing certificate is required. Unlock the login keychain or set SIGNING_IDENTITY."
    echo "The installed app has not been changed; ad-hoc signing would not preserve its permission identity."
    exit 1
fi

echo "==> Signing with '$SIGNING_IDENTITY'..."
codesign --force --deep --options runtime \
    --entitlements OpenWhisper/OpenWhisper.entitlements \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [ -n "$PREVIOUS_REQUIREMENT" ]; then
    if ! codesign --verify --strict -R="$PREVIOUS_REQUIREMENT" "$APP_BUNDLE"; then
        echo "ERROR: New build does not match the installed Jarvis identity; installation stopped."
        exit 1
    fi
    echo "==> Verified compatibility with the installed permission identity"
fi

if [ "${SKIP_RUNTIME_SYNC:-}" != "1" ]; then

# Local voice for spoken replies (OmniVoice): keep the installed server script and reference
# voice in sync with the repo. The Python venv itself comes from servers/tts_server/setup.sh (once).
TTS_DEST="$HOME/Library/Application Support/OpenWhisper/tts"
if [ -x "$TTS_DEST/.venv/bin/python" ]; then
    cp servers/tts_server/server.py servers/tts_server/jarvis_ref.wav "$TTS_DEST/"
    echo "==> Updated local voice server in $TTS_DEST"
else
    echo "NOTE: Local voice not installed; Jarvis's spoken replies stay silent until you run servers/tts_server/setup.sh"
fi

# Experimental local voice (Settings › Sesli cevap › EMA Lightning): keep the installed server
# script in sync. The venv and the model come from servers/tts_ema_server/setup.sh (once).
EMA_DEST="$HOME/Library/Application Support/OpenWhisper/tts-ema"
if [ -x "$EMA_DEST/.venv/bin/python" ]; then
    cp servers/tts_ema_server/server.py "$EMA_DEST/"
    echo "==> Updated EMA Lightning server in $EMA_DEST"
fi

# Default local voice (Settings › Sesli cevap › Pocket TTS): keep the installed server
# script and the Jarvis reference in sync. The venv and the model come from
# servers/tts_pocket_server/setup.sh (once).
POCKET_DEST="$HOME/Library/Application Support/OpenWhisper/tts-pocket"
if [ -x "$POCKET_DEST/.venv/bin/python" ]; then
    cp servers/tts_pocket_server/server.py servers/tts_server/jarvis_ref.wav "$POCKET_DEST/"
    echo "==> Updated Pocket TTS server in $POCKET_DEST"
else
    echo "NOTE: Default voice (Pocket TTS) not installed; spoken replies stay silent until you run servers/tts_pocket_server/setup.sh"
fi

# English voice (Settings › Sesli cevap › Piper Jarvis): keep the installed server script in
# sync. The venv and the model come from servers/tts_piper_server/setup.sh (once).
PIPER_DEST="$HOME/Library/Application Support/OpenWhisper/tts-piper"
if [ -x "$PIPER_DEST/.venv/bin/python" ]; then
    cp servers/tts_piper_server/server.py "$PIPER_DEST/"
    echo "==> Updated Piper Jarvis server in $PIPER_DEST"
fi

# Optional offline English Phonon voice.
PHONON_DEST="$HOME/Library/Application Support/OpenWhisper/tts-phonon"
if [ -x "$PHONON_DEST/.venv/bin/python" ]; then
    cp servers/tts_phonon_server/server.py "$PHONON_DEST/"
    echo "==> Updated Phonon server in $PHONON_DEST"
fi

# Alternative speech model (Settings › Konuşma modeli › Qwen3-ASR): keep the installed server
# script in sync. The venv and the model come from servers/asr_server/setup.sh (once).
ASR_DEST="$HOME/Library/Application Support/OpenWhisper/asr"
if [ -x "$ASR_DEST/.venv/bin/python" ]; then
    cp servers/asr_server/server.py "$ASR_DEST/"
    echo "==> Updated Qwen3-ASR server in $ASR_DEST"
fi

# Optional final-output Turkish ITN. setup.sh installs the pinned native runtime once.
DAMGA_DEST="$HOME/Library/Application Support/OpenWhisper/damga"
if [ -x "$DAMGA_DEST/.venv/bin/python" ]; then
    cp servers/damga_server/server.py "$DAMGA_DEST/"
    echo "==> Updated Damga server in $DAMGA_DEST"
fi

# SetFit decision models (Settings › Karar motoru): keep the installed server script in sync.
# The venv and the trained models come from decision_model/install.sh (retrain.sh runs it).
DECIDER_DEST="$HOME/Library/Application Support/OpenWhisper/decider"
if [ -x "$DECIDER_DEST/.venv/bin/python" ]; then
    cp ../decision_model/server.py "$DECIDER_DEST/"
    if [ -d "$DECIDER_DEST/shared/current" ]; then
        mkdir -p "$DECIDER_DEST/all_decisions_cloud"
        for runtime_file in runtime.py common.py specs.py; do
            cp "../decision_model/all_decisions_cloud/$runtime_file" "$DECIDER_DEST/all_decisions_cloud/"
        done
    fi
    echo "==> Updated SetFit decision server in $DECIDER_DEST"
else
    echo "NOTE: SetFit decision models not installed; 'Karar motoru: SetFit' needs decision_model/install.sh"
fi

fi # SKIP_RUNTIME_SYNC

install_app() {
    if [ "${SKIP_INSTALL:-}" != "1" ]; then
        echo "==> Installing to /Applications..."
        # Keep the registered bundle directory in place; deleting it can be observed as
        # an uninstall. Stop the running binary only after the replacement is validated.
        pkill -x OpenWhisper 2>/dev/null || true
        for attempt in {1..30}; do
            pgrep -x OpenWhisper >/dev/null || break
            sleep 0.1
        done
        if pgrep -x OpenWhisper >/dev/null; then
            echo "ERROR: Jarvis did not quit; installation stopped."
            exit 1
        fi
        mkdir -p "$INSTALLED_APP"
        /usr/bin/rsync -a --delete "$APP_BUNDLE/" "$INSTALLED_APP/"
        codesign --verify --deep --strict "$INSTALLED_APP"
        echo "  Installed at /Applications/Jarvis.app"

        echo "==> Launching newly installed Jarvis..."
        open /Applications/Jarvis.app
    fi
}

echo "Done! App bundle at: build/Jarvis.app"
install_app
echo ""
