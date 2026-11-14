#!/bin/bash
# Builds dist/LeafJuice Advisor Trial.app: the Advisor page on its own, for trying it on a real server.
# It can't start or change a server (see AdvisorTrial), and its own bundle id keeps its preferences apart from LeafJuice's.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
trial="dist/LeafJuice Advisor Trial.app"
rm -rf "$trial"
cp -R "dist/LeafJuice.app" "$trial"
plist="$trial/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier ${LEAFJUICE_TRIAL_BUNDLE_ID:-io.github.mgilardi.leafjuice.advisortrial}" \
    -c "Set :CFBundleName LeafJuice Advisor Trial" \
    -c "Set :CFBundleDisplayName LeafJuice Advisor Trial" \
    -c "Add :LeafJuiceAdvisorTrial bool true" \
    "$plist"
codesign --force --deep --sign - "$trial"
echo "Built $trial"
