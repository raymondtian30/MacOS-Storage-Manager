#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpaceSense"
VERSION="1.2.0"
BUILD_DIR="${ROOT_DIR}/build"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spacesense-stage.XXXXXX")"
STAGE_APP="${STAGE_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${STAGE_APP}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cleanup() {
    rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

cd "${ROOT_DIR}"
echo "1. Compiling ${APP_NAME} (Release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "2. Generating native macOS AppIcon.icns..."
ICONSET_DIR="${STAGE_DIR}/AppIcon.iconset"
"${BIN_PATH}" --generate-iconset "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SpaceSense</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.spacesense.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SpaceSense</string>
    <key>CFBundleDisplayName</key>
    <string>SpaceSense</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>120</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "3. Signing ${APP_NAME}.app in clean staging directory..."
xattr -cr "${STAGE_APP}"
codesign --force --deep --sign - "${STAGE_APP}"
codesign --verify --deep --strict "${STAGE_APP}"

echo "4. Copying ${APP_NAME}.app to build/ and creating release archives..."
rm -rf "${BUILD_DIR}/${APP_NAME}.app"
ditto "${STAGE_APP}" "${BUILD_DIR}/${APP_NAME}.app"

ZIP_PATH="${BUILD_DIR}/${APP_NAME}-v${VERSION}-macOS-arm64.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${STAGE_APP}" "${ZIP_PATH}"

DMG_STAGE="${STAGE_DIR}/dmg-root"
mkdir -p "${DMG_STAGE}"
ditto "${STAGE_APP}" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

DMG_PATH="${BUILD_DIR}/${APP_NAME}-v${VERSION}.dmg"
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG_PATH}" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
    echo "5. Installing ${APP_NAME}.app to /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "${STAGE_APP}" "/Applications/${APP_NAME}.app"
    echo "Installed /Applications/${APP_NAME}.app"
fi

echo "Done:"
echo "  App Bundle: ${BUILD_DIR}/${APP_NAME}.app"
echo "  ZIP Asset:  ${ZIP_PATH}"
echo "  DMG Asset:  ${DMG_PATH}"
