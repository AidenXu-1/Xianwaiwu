#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/xianwaiwu-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
shared=("$project_root/app/macos/源码/Lyrics.swift" "$project_root/app/macos/源码/LibraryStore.swift" "$project_root/app/macos/源码/Score.swift" "$project_root/app/macos/源码/AudioFormatting.swift")
for suite in LibraryStoreRegression LyricsRegression ScoreRegression; do
    xcrun swiftc -module-cache-path "$check_dir/modules" "${shared[@]}" "$project_root/app/macos/测试/$suite.swift" -o "$check_dir/$suite"
    if [[ "$suite" == LyricsRegression ]]; then XIANWAIWU_SKIP_REFERENCE_LYRICS=1 "$check_dir/$suite"; else "$check_dir/$suite"; fi
done
xcrun swiftc -module-cache-path "$check_dir/modules" "$project_root/app/macos/源码/BeatGuide.swift" "$project_root/app/macos/测试/BeatGuideRegression.swift" -o "$check_dir/BeatGuideRegression"
"$check_dir/BeatGuideRegression"
