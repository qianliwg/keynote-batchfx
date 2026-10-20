#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
staging_root="$(mktemp -d /private/tmp/kmotion-package.XXXXXX)"
app_path="$staging_root/Keynote动效工坊 P1.app"
mkdir -p "$project_root/build" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$project_root/build/module-cache"
export SWIFT_MODULECACHE_PATH="$project_root/build/module-cache"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 \
  "$project_root"/MotionCore/*.swift "$project_root"/App/*.swift \
  -o "$app_path/Contents/MacOS/MotionWorkshop"
if [[ ! -f "$project_root/build/runtime/bin/python3" || "${1:-}" == "--runtime" ]]; then
  python3 "$project_root/Packaging/bundle_runtime.py" "$project_root/build/runtime"
fi
rm -rf "$project_root/build/runtime/lib 2"
find "$project_root/build/runtime" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$project_root/build/runtime" -type f -name '*.pyc' -delete
mkdir -p "$app_path/Contents/Resources/runtime"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$project_root/build/runtime/bin" "$project_root/build/runtime/lib" \
  "$project_root/build/runtime/LICENSE-CPython.txt" "$app_path/Contents/Resources/runtime/"
rsync -a --delete --exclude __pycache__ "$project_root/KeynoteAdapter/" "$app_path/Contents/Resources/KeynoteAdapter/"
rsync -a --delete "$project_root/Fixtures/" "$app_path/Contents/Resources/Fixtures/"
rsync -a --delete "$project_root/Docs/" "$app_path/Contents/Resources/Docs/"
rsync -a --delete "$project_root/ProjectFormat/" "$app_path/Contents/Resources/ProjectFormat/"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.kmotion.workshop.p1</string>
<key>CFBundleName</key><string>Keynote动效工坊 P1</string>
<key>CFBundleDisplayName</key><string>Keynote动效工坊 P1</string>
<key>CFBundleExecutable</key><string>MotionWorkshop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -rc "$app_path" 2>/dev/null || true
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
"$app_path/Contents/MacOS/MotionWorkshop" --self-test
mkdir -p "$project_root/dist"
rm -rf "$project_root/dist/Keynote动效工坊 P1.app" "$project_root/dist/Keynote动效工坊-P1.zip"
python3 "$project_root/Packaging/make_zip.py" "$app_path" "$project_root/dist/Keynote动效工坊-P1.zip"
unzip -q "$project_root/dist/Keynote动效工坊-P1.zip" -d "$project_root/dist"
# Some synced workspaces add FinderInfo to the app root after extraction.
# Verify the deliverable independently in a local temporary directory.
verify_root="$staging_root/verify"
mkdir -p "$verify_root"
unzip -q "$project_root/dist/Keynote动效工坊-P1.zip" -d "$verify_root"
codesign --verify --deep --strict "$verify_root/Keynote动效工坊 P1.app"
xattr -d com.apple.FinderInfo "$project_root/dist/Keynote动效工坊 P1.app" 2>/dev/null || true
if ! codesign --verify --deep --strict "$project_root/dist/Keynote动效工坊 P1.app"; then
  print -u2 -- "ZIP 解包校验通过；工作区 app 目录的附加属性可能被同步服务重新写入。"
fi
print -r -- "$project_root/dist/Keynote动效工坊-P1.zip"
