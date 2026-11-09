#!/bin/bash
# Publishes a release: sets the version, builds, zips the app and creates the GitHub release
# that the in-app updater reads: OpenBoard.zip, plus the same zip as AISwitchboard.zip for
# installs up to 1.1.0, whose updater only knows that name.
# Usage: Scripts/release.sh 1.2.0 "Release notes"
set -euo pipefail

VERSION="${1:?Usage: Scripts/release.sh <version> [notes]}"
NOTES="${2:-OpenBoard $VERSION}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

Scripts/build_app.sh
rm -f .build/OpenBoard.zip .build/AISwitchboard.zip
ditto -c -k --keepParent .build/OpenBoard.app .build/OpenBoard.zip
cp .build/OpenBoard.zip .build/AISwitchboard.zip

git add Resources/Info.plist
git commit -m "Release $VERSION" || true
git tag "v$VERSION"
git push
git push origin "v$VERSION"
gh release create "v$VERSION" .build/OpenBoard.zip .build/AISwitchboard.zip --title "OpenBoard $VERSION" --notes "$NOTES"
echo "==> Released v$VERSION"
