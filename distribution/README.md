# Сборка DMG

Сборка выполняется на Mac с Xcode, Python 3 и pkg-config. Папка кэша и каталоги сборки должны находиться вне дерева исходников. Для сборки FFmpeg используйте короткий путь без пробелов.

1. Проверьте версии и SHA-256 в `assets.json`. Функция `assets_at` в `package.py` загружает отсутствующие официальные архивы и проверяет содержимое кэша.
2. Выполните команды ниже из корня проекта. Они собирают приложение для двух архитектур и создают отдельный образ для каждой.
3. К образам приложите исходные архивы FFmpeg и x264, `build-media-tools.sh` и контрольные суммы. Образы с локальной подписью не имеют нотариального заверения Apple.

```sh
work=$(mktemp -d /private/tmp/media-utility.XXXXXXXX)
python3 -c 'import sys; from pathlib import Path; sys.path.insert(0, "distribution"); from package import assets_at; assets_at(Path(sys.argv[1]))' "$work/assets"
xcodebuild -project YouTubeUtilityApp.xcodeproj -scheme YouTubeUtilityApp -configuration Release \
  -derivedDataPath "$work/xcode" -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO CODE_SIGNING_ALLOWED=NO build
for arch in arm64 x86_64; do
  ./distribution/build-media-tools.sh "$arch" "$work/assets" "$work/$arch"
  python3 distribution/package.py "$arch" "$work/assets" "$work/$arch" \
    "$work/xcode/Build/Products/Release/Media Utility.app" "$work/dist"
done
```
