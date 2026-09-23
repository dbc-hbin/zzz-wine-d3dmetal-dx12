#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

RUNTIME_ARCHIVE="Wine 11.17 ZZZ DX12 (GPTK4.0b2 macOS26).tar.xz"
RUNTIME_ARCHIVE_SOURCE="${RUNTIME_ARCHIVE_SOURCE:-$DIR/../build/release-v1.1.1/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz}"
if [ ! -f "$RUNTIME_ARCHIVE_SOURCE" ]; then
    echo "Missing macOS 26 runtime archive: $RUNTIME_ARCHIVE_SOURCE" >&2
    exit 1
fi

echo "==> Compiling Swift installer..."
ARCH="$(uname -m)"
OUTPUT_BIN="zzz-wine-installer"
APP_NAME="ZZZ Wine DX12 Installer.app"

swiftc -O \
    -target "${ARCH}-apple-macos26.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CryptoKit \
    -framework JavaScriptCore \
    -o "$OUTPUT_BIN" \
    RuntimePackage.swift \
    AsarPatcher.swift \
    ResourceRegistration.swift \
    InstallerEngine.swift \
    ContentView.swift \
    main.swift

echo "==> Compiling update registration helper..."
swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos26.0" \
    -framework CryptoKit -framework JavaScriptCore \
    -o zzz-wine-register \
    RuntimePackage.swift AsarPatcher.swift ResourceRegistration.swift RegistrationMain.swift
codesign --force --sign - zzz-wine-register

echo "==> Packaging into ${APP_NAME}..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$OUTPUT_BIN" "$APP_NAME/Contents/MacOS/$OUTPUT_BIN"
cp zzz-wine-register "$APP_NAME/Contents/Resources/zzz-wine-register"

for resource in typescript.js AsarTransform.js TypeScript-LICENSE.txt TypeScript-ThirdPartyNotice.txt; do
    source="$DIR/resources/$resource"
    if [ ! -f "$source" ]; then
        echo "Missing bundled installer resource: $source" >&2
        exit 1
    fi
    cp "$source" "$APP_NAME/Contents/Resources/$resource"
done

echo "==> Bundling macOS 26 runtime archive into App Resources..."
cp "$RUNTIME_ARCHIVE_SOURCE" "$APP_NAME/Contents/Resources/$RUNTIME_ARCHIVE"


cat << 'PLIST' > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>zzz-wine-installer</string>
    <key>CFBundleIdentifier</key>
    <string>com.hanbinnoh.zzz-wine-installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ZZZ Wine DX12 Installer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.3</string>
    <key>CFBundleVersion</key>
    <string>1.1.3</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_NAME"

echo "==> Build complete: $APP_NAME and $OUTPUT_BIN"
