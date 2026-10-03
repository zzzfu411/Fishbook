#!/bin/zsh
set -euo pipefail
STUDY_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
STUDY_BUILD="$STUDY_ROOT/build"
STUDY_PUBLIC=0
case "${1:-}" in
  --public) STUDY_PUBLIC=1; STUDY_BUILD="$STUDY_BUILD/public" ;;
  "") [[ -f "$STUDY_ROOT/content/library.json" ]] || STUDY_PUBLIC=1 ;;
  *) print -u2 'Usage: zsh build.sh [--public]'; exit 2 ;;
esac
STUDY_APP="$STUDY_BUILD/Fishbook.app"
mkdir -p "$STUDY_BUILD/ModuleCache"
STUDY_STAGING="$(mktemp -d "$STUDY_BUILD/.bundle-XXXXXX")"
STUDY_NEXT="$STUDY_STAGING/Fishbook.app"
trap 'rm -rf -- "$STUDY_STAGING"' EXIT
mkdir -p "$STUDY_NEXT/Contents/MacOS" "$STUDY_NEXT/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O -parse-as-library \
  -module-cache-path "$STUDY_BUILD/ModuleCache" \
  -target arm64-apple-macos14.0 \
  "$STUDY_ROOT"/Sources/*.swift \
  -o "$STUDY_NEXT/Contents/MacOS/PaperStudy"
cp "$STUDY_ROOT/Info.plist" "$STUDY_NEXT/Contents/Info.plist"
if [[ "$STUDY_PUBLIC" == 1 ]]; then
  ditto "$STUDY_ROOT/content/public" "$STUDY_NEXT/Contents/Resources/content"
  ditto "$STUDY_ROOT/content/reader-vendor" "$STUDY_NEXT/Contents/Resources/content/reader-vendor"
else
  ditto "$STUDY_ROOT/content" "$STUDY_NEXT/Contents/Resources/content"
fi
cp "$STUDY_ROOT/Assets/Brand/Logo.png" "$STUDY_NEXT/Contents/Resources/Logo.png"
cp "$STUDY_ROOT/Assets/Brand/AppIcon.icns" "$STUDY_NEXT/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$STUDY_NEXT/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$STUDY_NEXT"
/usr/bin/codesign --verify --deep --strict "$STUDY_NEXT"
# Only replace a complete, verified bundle. The user's sibling data is never touched.
STUDY_INSTALLED="$STUDY_APP"
if [[ ! -d "$STUDY_INSTALLED" && -d "$STUDY_BUILD/知页.app" ]]; then
  STUDY_INSTALLED="$STUDY_BUILD/知页.app"
fi
STUDY_PREVIOUS="$STUDY_BUILD/previous/$(basename -- "$STUDY_INSTALLED")"
mkdir -p "$STUDY_BUILD/previous"
STUDY_MOVED_PREVIOUS=0
if [[ -d "$STUDY_INSTALLED" ]]; then
  rm -rf -- "$STUDY_PREVIOUS"
  mv -- "$STUDY_INSTALLED" "$STUDY_PREVIOUS"
  STUDY_MOVED_PREVIOUS=1
fi
if ! mv -- "$STUDY_NEXT" "$STUDY_APP"; then
  if [[ "$STUDY_MOVED_PREVIOUS" == 1 ]]; then mv -- "$STUDY_PREVIOUS" "$STUDY_INSTALLED"; fi
  exit 1
fi
print "应用已生成：$STUDY_APP"
