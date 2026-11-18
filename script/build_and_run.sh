#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-run}
case "$mode" in
    run|--build|--verify|--debug|--logs|--telemetry) ;;
    *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
build_dir="$root/build/ReleaseBuild"
app="$build_dir/Build/Products/Release/Media Utility.app"
xcodebuild -project "$root/YouTubeUtilityApp.xcodeproj" -scheme YouTubeUtilityApp \
    -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO -quiet build
case "$mode" in
    --build) echo "$app" ;;
    --debug) exec lldb -- "$app/Contents/MacOS/YouTubeUtilityApp" ;;
    --logs|--telemetry)
        open "$app"
        exec /usr/bin/log stream --info --style compact --predicate 'process == "YouTubeUtilityApp"' ;;
    --verify) open "$app"; sleep 1; pgrep -x YouTubeUtilityApp >/dev/null ;;
    run) open "$app" ;;
esac
