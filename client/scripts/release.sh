#!/bin/bash
# WE Release Script
# Usage: ./scripts/release.sh <version>
set -euo pipefail

VERSION="${1:?Usage: release.sh <version>}"
echo "=== WE Release v${VERSION} ==="

# Step 1: Run tests
echo "→ Running tests..."
swift test || { echo "✗ Tests failed, aborting release"; exit 1; }

# Step 2: Build release
echo "→ Building release..."
swift build -c release

# Step 3: Create app bundle
echo "→ Creating app bundle..."
BUILD_DIR=".build/release"
APP_NAME="WE"
# TODO: Create proper .app bundle structure

# Step 4: Create DMG
echo "→ Creating DMG..."
# TODO: hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_DIR}" -ov -format UDZO "${APP_NAME}-${VERSION}.dmg"

# Step 5: Notarize (placeholder)
echo "→ Notarization (placeholder)..."
# TODO: xcrun notarytool submit

echo "=== Release v${VERSION} complete ==="
