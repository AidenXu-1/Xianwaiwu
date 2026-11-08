#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
project="$(dirname "$(dirname "$base")")"
python3 "$base/工程/generate_project.py"
xcodebuild -project "$base/弦外屋.xcodeproj" -scheme Xianwaiwu -configuration Release \
  -derivedDataPath "$base/构建缓存/NativeBuild" CODE_SIGNING_ALLOWED=NO build
built="$base/构建缓存/NativeBuild/Build/Products/Release/弦外屋.app"
output="$project/releases/弦外屋.app"
stage="$(mktemp -d "$project/releases/.native-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$built" "$stage/弦外屋.app"
if [[ -e "$output" ]]; then mv "$output" "$stage/previous.app"; fi
if ! mv "$stage/弦外屋.app" "$output"; then
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$output"; fi
  exit 1
fi
printf '\n%s\n' "$output"
