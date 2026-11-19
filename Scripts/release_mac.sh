#!/bin/zsh
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: Scripts/release_mac.sh vX.Y.Z" >&2
  exit 1
fi

TAG="$1"
VERSION="${TAG#v}"
WAVE_PROJECT_DIR="${0:A:h:h}"
cd "$WAVE_PROJECT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> Running Swift & MCP test suites"
swift test --scratch-path .build/Tests
python3 Scripts/test_mcp.py .build/Tests/debug/WaveMCP

echo "==> Building Wave $VERSION (Release, Apple Silicon)"
xcodebuild -quiet \
  -project Wave.xcodeproj \
  -scheme Wave \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Release \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  build

echo "==> Building WaveMCP helper"
swift build -c release --product WaveMCP --scratch-path .build/MCPRelease

echo "==> Packaging, signing, and verifying dist/Wave.zip"
mkdir -p dist
rm -rf -- dist/Wave.app dist/Wave.zip dist/Wave.zip.sha256 dist/RELEASE_NOTES.md
ditto .build/Release/Build/Products/Release/Wave.app dist/Wave.app
mkdir -p dist/Wave.app/Contents/Helpers
cp .build/MCPRelease/release/WaveMCP dist/Wave.app/Contents/Helpers/WaveMCP
chmod +x dist/Wave.app/Contents/Helpers/WaveMCP
codesign --force --deep --sign - dist/Wave.app
codesign --verify --deep --strict dist/Wave.app

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Wave.app/Contents/Info.plist)
test "$APP_VERSION" = "$VERSION"
test -x dist/Wave.app/Contents/Helpers/WaveMCP

ditto -c -k --sequesterRsrc --keepParent dist/Wave.app dist/Wave.zip
(cd dist && shasum -a 256 Wave.zip > Wave.zip.sha256)

RELEASE_VERSION="$VERSION" python3 - <<'PY'
import os, re
from pathlib import Path

version = os.environ["RELEASE_VERSION"]
changelog = Path("CHANGELOG.md").read_text(encoding="utf-8") if Path("CHANGELOG.md").exists() else ""
pattern = re.compile(rf"^## {re.escape(version)}(?:\s+—[^\n]*)?\n(.*?)(?=^## |\Z)", re.M | re.S)
match = pattern.search(changelog)
sha_line = Path("dist/Wave.zip.sha256").read_text(encoding="utf-8").strip()

sections = []
if match:
    sections.append(match.group(1).strip())
else:
    sections.append(f"Release **Wave {version}** pour macOS (Apple Silicon).")

sections.append("\n".join([
    "---",
    "",
    "### Téléchargement & installation (macOS Apple Silicon · macOS 13+)",
    "",
    "1. Téléchargez **`Wave.zip`** ci-dessous et décompressez-le.",
    "2. Déplacez **`Wave.app`** dans votre dossier **`/Applications`**.",
    "3. **Première ouverture** : cette version étant signée localement (non notariée Apple Developer), autorisez l’application dans **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**, ou exécutez :",
    "   ```sh",
    "   xattr -dr com.apple.quarantine /Applications/Wave.app",
    "   ```",
    "",
    "> **Serveur MCP inclus** : `WaveMCP` est intégré dans `Wave.app/Contents/Helpers/WaveMCP` (prêt à l’emploi depuis **IA & appareils**).",
    "",
    "#### Vérification SHA-256",
    "```text",
    sha_line,
    "```",
]))

Path("dist/RELEASE_NOTES.md").write_text("\n\n".join(sections) + "\n", encoding="utf-8")
PY

echo "==> Publishing GitHub Release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/Wave.zip dist/Wave.zip.sha256 --clobber
  gh release edit "$TAG" --title "Wave $TAG" --notes-file dist/RELEASE_NOTES.md
else
  gh release create "$TAG" dist/Wave.zip dist/Wave.zip.sha256 \
    --title "Wave $TAG" \
    --notes-file dist/RELEASE_NOTES.md
fi
