#!/bin/bash
set -euo pipefail
project="$(dirname "$(dirname "$SRCROOT")")"
art="$project/design/assets/弦外屋 Logo/弦外屋 · 木吉他精细版.png"
icon_document="$DERIVED_FILE_DIR/AppIcon.icon"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$icon_document/Assets" "$resources"
cp -X "$art" "$icon_document/Assets/art.png"
cat > "$icon_document/icon.json" <<'JSON'
{"fill":{"solid":"extended-srgb:0.11765,0.05882,0.03529,1.00000"},"groups":[{"layers":[{"name":"Artwork","image-name":"art.png","glass":false,"position":{"scale":0.81,"translation-in-points":[0,0]}}],"specular":false,"translucency":{"enabled":false,"value":0}}],"supported-platforms":{"squares":["macOS"]}}
JSON
xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$DERIVED_FILE_DIR/icon-info.plist" --output-format human-readable-text --errors --warnings "$icon_document"
/usr/bin/sips -z 128 128 "$art" --out "$resources/BrandMark.png" >/dev/null
