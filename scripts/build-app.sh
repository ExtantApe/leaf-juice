#!/bin/bash
# Builds dist/Leaf Juice.app, ad-hoc signed. Needs only the Command Line Tools.
#   scripts/build-app.sh              this Mac's architecture
#   scripts/build-app.sh --universal  Apple silicon and Intel
#   scripts/build-app.sh --dmg        also makes a .zip and .dmg for a GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

universal=false; dmg=false
for arg in "$@"; do
    case "$arg" in
        --universal) universal=true ;;
        --dmg) dmg=true; universal=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

version=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/LeafJuiceCore/Support.swift)
app="dist/Leaf Juice.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if $universal; then
    swift build -c release --product LeafJuice --arch arm64
    swift build -c release --product LeafJuice --arch x86_64
    lipo -create -output "$app/Contents/MacOS/LeafJuice" \
        .build/arm64-apple-macosx/release/LeafJuice \
        .build/x86_64-apple-macosx/release/LeafJuice
else
    swift build -c release --product LeafJuice
    cp .build/release/LeafJuice "$app/Contents/MacOS/LeafJuice"
fi
strip -x "$app/Contents/MacOS/LeafJuice" 2>/dev/null || true

[ -f brand/AppIcon.icns ] || swift scripts/make-icon.swift brand
cp brand/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Leaf Juice</string>
    <key>CFBundleDisplayName</key><string>Leaf Juice</string>
    <key>CFBundleIdentifier</key><string>io.github.mgilardi.leafjuice</string>
    <key>CFBundleExecutable</key><string>LeafJuice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Mojang or Microsoft.</string>
</dict>
</plist>
PLIST

# Ad-hoc: required to run on Apple silicon. It isn't an Apple Developer signature, so macOS still
# asks people to approve the first launch. The README explains how.
codesign --force --deep --sign - "$app"

if $dmg; then
    ( cd dist && rm -f LeafJuice-*.zip LeafJuice-*.dmg && ditto -c -k --keepParent "Leaf Juice.app" "LeafJuice-$version.zip" )
    staging=$(mktemp -d)
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "Leaf Juice" -srcfolder "$staging" -ov -format UDZO "dist/LeafJuice-$version.dmg"
    rm -rf "$staging"
fi

echo "Built $app ($(du -sh "$app" | cut -f1))"
