#!/usr/bin/env bash
# Verifies that the pinned engine provenance, licenses, app bundle and the
# CLI behaviours the GUI depends on all line up.
#
# The engine is fetched from the official prebuilt 7-Zip release.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/Vendor/7zz"
LOCK="$ROOT/Vendor/7zip.lock.json"
APP="$ROOT/dist/Finder7.app"
QUICK=0
ONLINE=0
FAILURES=0
WARNINGS=0

for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --online) ONLINE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

banner_for() {
    local binary="$1" output
    output="$(mktemp "${TMPDIR:-/tmp}/sevenzip-banner.XXXXXX")"
    "$binary" >"$output" 2>&1 || true
    awk 'NF { print; exit }' "$output"
    rm -f "$output"
}

LOCK_VERSION=""; LOCK_TAG=""; LOCK_SOURCE=""; LOCK_ENGINE_SHA=""
LOCK_LICENSE_SHA=""; LOCK_UNRAR_SHA=""

echo "== Lock and provenance =="
if [[ -f "$LOCK" ]]; then
    read -r LOCK_VERSION LOCK_TAG LOCK_SOURCE LOCK_ENGINE_SHA LOCK_LICENSE_SHA LOCK_UNRAR_SHA < <(python3 - "$LOCK" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(
    d.get("version", ""),
    d.get("tag", d.get("version", "")),
    d.get("source", "source-build"),
    d.get("engineSha256", ""),
    d.get("licenseSha256", ""),
    d.get("unrarLicenseSha256", ""),
)
PY
) || { fail "could not parse $LOCK"; }
    if [[ -n "$LOCK_VERSION" ]]; then
        pass "lock records 7-Zip $LOCK_VERSION ($LOCK_SOURCE)"
    fi
    if [[ "$LOCK_VERSION" != "$LOCK_TAG" ]]; then
        fail "lock version $LOCK_VERSION != tag $LOCK_TAG"
    fi
    if python3 - "$LOCK" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get("version"), "missing version"
assert d.get("engineSha256"), "missing engineSha256"
assert d.get("licenseSha256"), "missing licenseSha256"
assert d.get("unrarLicenseSha256"), "missing unrarLicenseSha256"
source = d.get("source", "source-build")
assert source in ("official-binary", "source-build"), f"unknown source {source}"
if source == "official-binary":
    assets = d.get("assets")
    assert isinstance(assets, dict) and "arm64" in assets, "missing arm64 asset"
    for arch, asset in assets.items():
        assert asset.get("name"), f"{arch} asset has no name"
        assert len(asset.get("sha256", "")) == 64, f"{arch} asset has no sha256"
PY
    then
        pass "lock schema, asset names and checksums are valid"
    else
        fail "lock schema, asset names or checksums are invalid"
    fi
else
    fail "Vendor/7zip.lock.json is missing"
fi

echo
echo "== Source provenance =="
if [[ "$LOCK_SOURCE" == "official-binary" ]]; then
    pass "provenance is official-binary; the app does not compile 7-Zip"
else
    warn "lock provenance is '${LOCK_SOURCE:-unknown}'; expected official-binary"
fi

echo
echo "== Engine binary =="
if [[ -x "$BIN" ]]; then
    BIN_BANNER="$(banner_for "$BIN")"
    BIN_VERSION="$(printf '%s\n' "$BIN_BANNER" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
    pass "Vendor/7zz version ${BIN_VERSION:-unknown}"
    if [[ -n "$LOCK_VERSION" && "$BIN_VERSION" != "$LOCK_VERSION" ]]; then
        fail "engine version $BIN_VERSION != lock $LOCK_VERSION"
    fi

    ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
    if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
        pass "universal binary ($ARCHS)"
    else
        fail "expected arm64 + x86_64, got: ${ARCHS:-unknown}"
    fi

    if [[ -n "$LOCK_ENGINE_SHA" ]]; then
        [[ "$(sha "$BIN")" == "$LOCK_ENGINE_SHA" ]] && pass "engine checksum matches lock" || fail "engine checksum does not match lock"
    fi

    ARM_MINOS="$(otool -arch arm64 -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    X64_MINOS="$(otool -arch x86_64 -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    pass "deployment targets: arm64 ${ARM_MINOS:-unknown}, x86_64 ${X64_MINOS:-unknown}"
else
    fail "Vendor/7zz is missing; run ./Scripts/fetch-engine.sh"
fi

echo
echo "== Licenses =="
for vendor_name in License.txt unRarLicense.txt; do
    if [[ ! -f "$ROOT/Vendor/$vendor_name" ]]; then
        fail "missing Vendor/$vendor_name"
        continue
    fi
    pass "Vendor/$vendor_name is present (official binary provenance)"
done
[[ -n "$LOCK_LICENSE_SHA" && -f "$ROOT/Vendor/License.txt" && "$(sha "$ROOT/Vendor/License.txt")" == "$LOCK_LICENSE_SHA" ]] \
    && pass "license checksum matches lock" || fail "license checksum does not match lock"
[[ -n "$LOCK_UNRAR_SHA" && -f "$ROOT/Vendor/unRarLicense.txt" && "$(sha "$ROOT/Vendor/unRarLicense.txt")" == "$LOCK_UNRAR_SHA" ]] \
    && pass "unRAR license checksum matches lock" || fail "unRAR license checksum does not match lock"
if grep -q "GNU LGPL" "$ROOT/Vendor/License.txt" 2>/dev/null; then
    pass "License.txt contains the GNU LGPL text"
else
    fail "License.txt does not look like 7-Zip's license"
fi
if grep -qi "unRAR" "$ROOT/Vendor/unRarLicense.txt" 2>/dev/null; then
    pass "unRarLicense.txt contains the unRAR restriction"
else
    fail "unRarLicense.txt is missing the unRAR restriction"
fi

if [[ $QUICK -eq 0 ]]; then
    echo
    echo "== CLI contract =="
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/sevenzip-check.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/src"
    printf 'alpha\n' > "$TMP/src/a.txt"
    printf 'beta\n' > "$TMP/src/b.txt"
    # ~200 KB of compressible data
    yes 'seven zip contract test line' | head -6000 > "$TMP/src/big.txt"

    if "$BIN" a "$TMP/out.7z" "$TMP/src" -mx=5 -bsp1 -y >"$TMP/create.log" 2>&1; then
        pass "created 7z with -mx/-bsp1"
        grep -q '%' "$TMP/create.log" && pass "progress output contains percentages" || warn "no percent found in -bsp1 output"
    else
        fail "7z creation failed"
        tail -10 "$TMP/create.log"
    fi

    if "$BIN" x "$TMP/out.7z" -o"$TMP/out7z" -y >"$TMP/extract.log" 2>&1; then
        cmp -s "$TMP/src/a.txt" "$TMP/out7z/src/a.txt" && pass "7z extraction round-trip" || fail "7z extraction content mismatch"
    else
        fail "7z extraction failed"
    fi

    if "$BIN" a "$TMP/locked.7z" "$TMP/src/a.txt" -p'correct horse' -mhe=on -y >/dev/null 2>&1; then
        if "$BIN" x "$TMP/locked.7z" -o"$TMP/outlocked" -p'correct horse' -y >/dev/null 2>&1; then
            pass "encrypted 7z (AES-256 + encrypted names) round-trip"
        else
            fail "encrypted 7z could not be extracted"
        fi
        if "$BIN" t "$TMP/locked.7z" -pwrong >/dev/null 2>&1; then
            fail "encrypted 7z accepted the wrong password"
        else
            pass "encrypted 7z rejects a wrong password"
        fi
    else
        fail "encrypted 7z creation failed"
    fi

    if "$BIN" a "$TMP/out.zip" "$TMP/src" -tzip -mem=AES256 -p'zip secret' -y >/dev/null 2>&1; then
        if "$BIN" x "$TMP/out.zip" -o"$TMP/outzip" -p'zip secret' -y >/dev/null 2>&1; then
            cmp -s "$TMP/src/big.txt" "$TMP/outzip/src/big.txt" && pass "ZIP AES-256 round-trip" || fail "ZIP extraction mismatch"
        else
            fail "ZIP extraction failed"
        fi
    else
        fail "ZIP AES-256 creation failed"
    fi

    if "$BIN" a "$TMP/out.tar" "$TMP/src" -ttar -y >/dev/null 2>&1; then
        pass "TAR creation"
    else
        fail "TAR creation failed"
    fi

    if [[ $ONLINE -eq 1 ]]; then
        echo
        echo "== Upstream =="
        "$ROOT/Scripts/check-upstream.sh" --quiet
        status=$?
        if [[ $status -eq 0 ]]; then
            pass "no newer 7-Zip release"
        elif [[ $status -eq 2 ]]; then
            warn "a newer 7-Zip release is available; run ./Scripts/fetch-engine.sh and rebuild"
        else
            fail "could not check upstream releases"
        fi
    fi

    echo
    echo "== App bundle =="
    if [[ -d "$APP" ]]; then
        APP_BIN="$APP/Contents/Resources/7zz"
        APP_BANNER="$(banner_for "$APP_BIN")"
        APP_VERSION="$(printf '%s\n' "$APP_BANNER" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
        APP_ARCHS="$(lipo -archs "$APP_BIN" 2>/dev/null || true)"
        if [[ -n "$LOCK_VERSION" && "$APP_VERSION" == "$LOCK_VERSION" && "$APP_ARCHS" == *"arm64"* && "$APP_ARCHS" == *"x86_64"* ]]; then
            pass "app bundles 7zz $APP_VERSION ($APP_ARCHS)"
        else
            fail "app engine is stale or wrong architecture (version ${APP_VERSION:-?}, archs ${APP_ARCHS:-?}); rebuild the app"
        fi

        if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
            pass "app signature validates"
        else
            fail "app signature is invalid"
        fi

        if python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
docs = d.get("CFBundleDocumentTypes", [])
assert d.get("CFBundleDisplayName") == "Finder7", "display name is not Finder7"
assert d.get("CFBundleExecutable") == "Finder7", "executable is not Finder7"
assert any(t.get("CFBundleTypeIconFile") == "ArchiveDoc" for t in docs), "document icon missing"
services = [s.get("NSMessage") for s in d.get("NSServices", [])]
assert "compressWithSevenZip" in services, "compress service missing"
assert "extractWithSevenZip" in services, "extract service missing"
PY
        then
            pass "app metadata includes the Finder7 name, document icon and Finder services"
        else
            fail "app metadata is missing the Finder7 name, document icon or services"
        fi

        if [[ -f "$APP/Contents/Resources/AppIcon.icns" && -f "$APP/Contents/Resources/ArchiveDoc.icns" ]]; then
            pass "app bundles the Finder7 app and document icons"
        else
            fail "app is missing the Finder7 app or document icons"
        fi

        if [[ -f "$APP/Contents/Resources/LICENSE" ]]; then
            pass "app bundles the Finder7 license"
        else
            fail "app is missing the Finder7 license"
        fi

        if python3 - "$APP/Contents/Info.plist" "$APP/Contents/Resources/homelab-app.json" \
            "$APP/Contents/Resources/engine-provenance.txt" "$LOCK" <<'PY'
import json, plistlib, sys
plist_path, manifest_path, provenance_path, lock_path = sys.argv[1:]
with open(plist_path, "rb") as f:
    plist = plistlib.load(f)
with open(manifest_path) as f:
    manifest = json.load(f)
with open(lock_path) as f:
    lock = json.load(f)
assert manifest["schema"] == 1
assert manifest["app"]["name"] == plist.get("CFBundleName", "Finder7")
assert manifest["app"]["version"] == plist["CFBundleShortVersionString"]
dep = next(d for d in manifest["dependencies"] if d["repo"] == "ip7z/7zip")
assert dep["version"] == lock["version"], (dep["version"], lock["version"])
assert dep["path"] == "7zz"
with open(provenance_path) as f:
    provenance = f.read().strip()
assert provenance == (lock.get("source") or "source-build"), provenance
PY
        then
            pass "homelab-app.json matches the lock and Info.plist"
        else
            fail "homelab-app.json does not match the lock/Info.plist"
        fi

        DEP_OUTPUT="$("$APP/Contents/MacOS/Finder7" --dependency-versions 2>/dev/null)"
        if python3 - "$LOCK_VERSION" "$DEP_OUTPUT" <<'PY'
import json, sys
expected, output = sys.argv[1], sys.argv[2]
try:
    data = json.loads(output)
except Exception as exc:
    sys.exit(f"not JSON: {exc}")
dep = next(d for d in data["dependencies"] if d["repo"] == "ip7z/7zip")
assert dep["version"] == expected
PY
        then
            pass "--dependency-versions reports 7-Zip $LOCK_VERSION for ip7z/7zip"
        else
            fail "--dependency-versions did not report 7-Zip $LOCK_VERSION"
        fi

        for pair in "7-Zip-License.txt:License.txt" "7-Zip-UnRAR-License.txt:unRarLicense.txt"; do
            bundled="${pair%%:*}"
            vendor="${pair##*:}"
            if cmp -s "$APP/Contents/Resources/$bundled" "$ROOT/Vendor/$vendor"; then
                pass "app bundles $bundled"
            else
                fail "app's $bundled differs from Vendor/$vendor"
            fi
        done

        if "$APP/Contents/MacOS/Finder7" --smoke-test >"$TMP/app-smoke.log" 2>&1; then
            pass "app smoke test"
        else
            fail "app smoke test failed"
            tail -20 "$TMP/app-smoke.log"
        fi
    else
        warn "dist/Finder7.app not built; run ./Scripts/build-app.sh"
    fi
fi

echo
if [[ $FAILURES -gt 0 ]]; then
    echo "RESULT: $FAILURES failure(s), $WARNINGS warning(s)"
    exit 1
fi
echo "RESULT: checks passed${WARNINGS:+, $WARNINGS warning(s)}"
