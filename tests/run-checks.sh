#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp YouTubeUtilityApp/{downloader_runtime.py,yt-dlp-lock.json} "$work/"
swiftc -module-cache-path "$work/cache" YouTubeUtilityApp/{Models,DownloadCoordinator}.swift \
    tests/SaveChecks.swift -o "$work/save-checks"
"$work/save-checks" "$@"
python3 -B -m unittest discover -s tests -p 'test_*.py'
