#!/bin/bash
# Install only the downloader reviewed for this build of Media Utility.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
lock="$root/YouTubeUtilityApp/yt-dlp-lock.json"
version=$(/usr/bin/plutil -extract version raw -o - "$lock")
digest=$(/usr/bin/plutil -extract sha256 raw -o - "$lock")
target="$HOME/Library/Application Support/Media Utility/tools/$version"
/bin/mkdir -p "$target"
if [[ -f "$target/yt-dlp" && "$(/usr/bin/shasum -a 256 < "$target/yt-dlp")" == "$digest  -" ]]; then
    echo "yt-dlp $version is verified and ready."
    exit 0
fi
stage=$(/usr/bin/mktemp "$target/.download.XXXXXXXX")
trap '/bin/rm -f "$stage"' EXIT
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    "https://github.com/yt-dlp/yt-dlp/releases/download/$version/yt-dlp" -o "$stage"
actual=$(/usr/bin/shasum -a 256 < "$stage")
[[ "$actual" == "$digest  -" ]] || { echo "Downloader checksum mismatch." >&2; exit 1; }
/bin/mv -f "$stage" "$target/yt-dlp"
echo "Installed verified yt-dlp $version for Media Utility."
