#!/bin/zsh
set -euo pipefail
WAVE_PROJECT_DIR="${0:A:h:h}"
cd "$WAVE_PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -quiet -project Wave.xcodeproj -scheme Wave -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Release CODE_SIGNING_ALLOWED=NO build
swift build -c release --product WaveMCP --scratch-path .build/MCPRelease
mkdir -p dist
rm -rf -- dist/Wave.app
ditto .build/Release/Build/Products/Release/Wave.app dist/Wave.app
mkdir -p dist/Wave.app/Contents/Helpers
cp .build/MCPRelease/release/WaveMCP dist/Wave.app/Contents/Helpers/WaveMCP
chmod +x dist/Wave.app/Contents/Helpers/WaveMCP
codesign --force --deep --sign - dist/Wave.app
codesign --verify --deep --strict dist/Wave.app
rm -f -- dist/Wave.zip dist/Wave.zip.sha256
ditto -c -k --sequesterRsrc --keepParent dist/Wave.app dist/Wave.zip
(cd dist && shasum -a 256 Wave.zip > Wave.zip.sha256)
