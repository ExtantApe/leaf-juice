#!/bin/bash
# Builds dist/Leaf Juice Advisor Trial.app: the Advisor page on its own, for trying it on a real server.
# It can't start or change a server (see AdvisorTrial), and its own bundle id keeps its preferences apart from Leaf Juice's.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
trial="dist/Leaf Juice Advisor Trial.app"
rm -rf "$trial"
cp -R "dist/Leaf Juice.app" "$trial"
plist="$trial/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier ${LEAFJUICE_TRIAL_BUNDLE_ID:-io.github.mgilardi.leafjuice.advisortrial}" \
    -c "Set :CFBundleName Leaf Juice Advisor Trial" \
    -c "Set :CFBundleDisplayName Leaf Juice Advisor Trial" \
    -c "Add :LeafJuiceAdvisorTrial bool true" \
    "$plist"
codesign --force --deep --sign - "$trial"
echo "Built $trial"
