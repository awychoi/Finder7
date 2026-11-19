#!/usr/bin/env bash
# Builds dist/Finder7.app: universal SwiftUI binary + bundled 7zz engine,
# ad-hoc signed and smoke-tested.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Finder7"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
APP="$ROOT/dist/$APP_NAME.app"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$TMPDIR" "$ROOT/dist"

if [[ ! -x "$ROOT/Vendor/7zz" ]]; then
    echo "error: Vendor/7zz is missing." >&2
    echo "       The 7-Zip engine is not bundled with this repo. Fetch the" >&2
    echo "       official prebuilt universal engine with:" >&2
    echo "         ./Scripts/fetch-engine.sh" >&2
    exit 1
fi

for icon in AppIcon.icns ArchiveDoc.icns; do
    [[ -f "$ROOT/Resources/$icon" ]] || {
        echo "error: Resources/$icon is missing; it is required to build the app." >&2
        exit 1
    }
done

"$ROOT/Scripts/check-engine.sh" --quick

echo "==> Building universal Swift binary ($CONFIG)"
swift build -c "$CONFIG" --arch arm64 --arch x86_64 --disable-sandbox
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path --disable-sandbox)"
BINARY="$BIN_DIR/SevenZipGUI"
[[ -x "$BINARY" ]] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Finder7"
cp "$ROOT/Vendor/7zz" "$APP/Contents/Resources/7zz"
cp "$ROOT/Vendor/License.txt" "$APP/Contents/Resources/7-Zip-License.txt"
cp "$ROOT/Vendor/unRarLicense.txt" "$APP/Contents/Resources/7-Zip-UnRAR-License.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
chmod +x "$APP/Contents/MacOS/Finder7" "$APP/Contents/Resources/7zz"

cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/ArchiveDoc.icns" "$APP/Contents/Resources/ArchiveDoc.icns"

sed "s/@VERSION@/$VERSION/g" "$ROOT/Scripts/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Writing dependency manifest"
python3 - "$ROOT/Vendor/7zip.lock.json" "$APP/Contents/Info.plist" \
    "$APP/Contents/Resources/homelab-app.json" \
    "$APP/Contents/Resources/engine-provenance.txt" <<'PY'
import json, plistlib, sys
lock_path, plist_path, manifest_path, provenance_path = sys.argv[1:]
with open(lock_path) as f:
    lock = json.load(f)
with open(plist_path, "rb") as f:
    plist = plistlib.load(f)
version = lock.get("version") or lock.get("tag")
if not version:
    sys.exit("error: lock file has no version")
app_version = plist.get("CFBundleShortVersionString")
if not app_version:
    sys.exit("error: Info.plist has no CFBundleShortVersionString")
manifest = {
    "schema": 1,
    "app": {"name": plist.get("CFBundleName", "Finder7"), "version": app_version},
    "dependencies": [
        {"repo": "ip7z/7zip", "version": version, "path": "7zz"}
    ],
}
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
with open(provenance_path, "w") as f:
    f.write((lock.get("source") or "source-build") + "\n")
print(f"Wrote {manifest_path} (7-Zip {version}, app {app_version})")
PY

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/7zz" >/dev/null
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "==> Smoke test"
"$APP/Contents/MacOS/Finder7" --smoke-test

ZIP="$ROOT/dist/Finder7-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Built $APP"
echo "Packaged $ZIP"
echo "Launch with: open \"$APP\""
