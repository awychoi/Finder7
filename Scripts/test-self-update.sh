#!/usr/bin/env bash
# Offline integration test for the in-app engine self-update.
#
# It builds 26.05 / 26.06 / 26.07 fixtures from the checked-in universal engine,
# installs a 26.05 engine into a throwaway copy of dist/Finder7.app, and runs
# the headless --self-update paths against local fixtures. No network access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Finder7.app"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/finder7-self-update.XXXXXX")"
export SEVENZIP_SUPPORT_DIR="$WORK/support"
mkdir -p "$SEVENZIP_SUPPORT_DIR"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
die() { echo "error: $*" >&2; exit 1; }

banner() {
    local output
    output="$(mktemp "${TMPDIR:-/tmp}/sevenzip-banner.XXXXXX")"
    "$1" >"$output" 2>&1 || true
    awk 'NF { print; exit }' "$output"
    rm -f "$output"
}

manifest_version() {
    python3 - "$1/Contents/Resources/homelab-app.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)["dependencies"][0]["version"])
PY
}

assert_app() {
    local app="$1" version="$2" previous="${3:-}"
    local bin="$app/Contents/MacOS/Finder7"
    local engine="$app/Contents/Resources/7zz"
    local got_banner got_version archs
    got_banner="$(banner "$engine")"
    [[ "$got_banner" == *"$version"* ]] && pass "engine banner is $version" || fail "engine banner is not $version: $got_banner"
    archs="$(lipo -archs "$engine" 2>/dev/null || true)"
    [[ "$archs" == *"arm64"* && "$archs" == *"x86_64"* ]] && pass "engine is universal ($archs)" || fail "engine is not universal: $archs"
    got_version="$(manifest_version "$app")"
    [[ "$got_version" == "$version" ]] && pass "manifest reports $version" || fail "manifest reports $got_version, expected $version"
    local dep_version
    dep_version="$("$bin" --dependency-versions 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["dependencies"][0]["version"])')"
    [[ "$dep_version" == "$version" ]] && pass "--dependency-versions reports $version" || fail "--dependency-versions reports $dep_version"
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 && pass "app signature validates" || fail "app signature is invalid"
    if [[ -n "$previous" ]]; then
        [[ -x "$app/Contents/Resources/7zz.previous" ]] && pass "7zz.previous exists" || fail "7zz.previous is missing"
        local previous_banner
        previous_banner="$(banner "$app/Contents/Resources/7zz.previous")"
        [[ "$previous_banner" == *"$previous"* ]] && pass "7zz.previous is $previous" || fail "7zz.previous is not $previous: $previous_banner"
    fi
}

# MARK: - Fixtures

FIX="$WORK/fixtures"
mkdir -p "$FIX/fix2605" "$FIX/fix2606" "$FIX/fix2607" "$FIX/badarch" "$WORK/stage"

echo "==> Building offline fixtures from Vendor/7zz"
ENGINE="$ROOT/Vendor/7zz"
LICENSE="$ROOT/Vendor/License.txt"
[[ -x "$ENGINE" ]] || die "Vendor/7zz is missing; run ./Scripts/fetch-engine.sh"

# 26.06 official layout: one thin slice per archive.
lipo -thin arm64 -output "$WORK/arm64-7zz" "$ENGINE"
lipo -thin x86_64 -output "$WORK/x86_64-7zz" "$ENGINE"
mkdir -p "$WORK/stage/arm" "$WORK/stage/x64"
cp "$WORK/arm64-7zz" "$WORK/stage/arm/7zz"
cp "$WORK/x86_64-7zz" "$WORK/stage/x64/7zz"
cp "$LICENSE" "$WORK/stage/arm/License.txt"
cp "$LICENSE" "$WORK/stage/x64/License.txt"
( cd "$WORK/stage/arm" && COPYFILE_DISABLE=1 tar -cJf "$FIX/fix2606/7z2606-mac.tar.xz" 7zz License.txt )
( cd "$WORK/stage/x64" && COPYFILE_DISABLE=1 tar -cJf "$FIX/fix2606/7z2606-mac-x64.tar.xz" 7zz License.txt )

# 26.05 / 26.07: the old universal layout. Patching the banner is enough for
# the updater contract; the resulting binary is re-signed by the updater/test.
for version in 26.05 26.07; do
    code="${version//./}"
    dir="$FIX/fix${code}"
    cp "$ENGINE" "$WORK/${code}-7zz"
    perl -0pi -e "s/26\\.06/${version}/g" "$WORK/${code}-7zz"
    chmod +x "$WORK/${code}-7zz"
    mkdir -p "$WORK/stage/${code}"
    cp "$WORK/${code}-7zz" "$WORK/stage/${code}/7zz"
    cp "$LICENSE" "$WORK/stage/${code}/License.txt"
    ( cd "$WORK/stage/${code}" && COPYFILE_DISABLE=1 tar -cJf "$dir/7z${code}-mac.tar.xz" 7zz License.txt )
done

# Wrong architecture: an arm64-named asset containing the x86_64 slice.
mkdir -p "$WORK/stage/badarch"
cp "$WORK/x86_64-7zz" "$WORK/stage/badarch/7zz"
cp "$LICENSE" "$WORK/stage/badarch/License.txt"
( cd "$WORK/stage/badarch" && COPYFILE_DISABLE=1 tar -cJf "$FIX/badarch/7z2608-mac.tar.xz" 7zz License.txt )

python3 - "$FIX" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
releases = {
    "fix2605": ("26.05", ["7z2605-mac.tar.xz"]),
    "fix2606": ("26.06", ["7z2606-mac.tar.xz", "7z2606-mac-x64.tar.xz"]),
    "fix2607": ("26.07", ["7z2607-mac.tar.xz"]),
    "badarch": ("26.08", ["7z2608-mac.tar.xz"]),
}
for directory, (tag, names) in releases.items():
    folder = os.path.join(root, directory)
    assets = []
    sums = []
    for name in names:
        path = os.path.join(folder, name)
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        size = os.path.getsize(path)
        assets.append({
            "name": name,
            "browser_download_url": f"https://github.com/ip7z/7zip/releases/download/{tag}/{name}",
            "size": size,
            "digest": f"sha256:{digest}",
            "content_type": "application/octet-stream",
        })
        sums.append(f"{digest}  {name}\n")
    release = {
        "tag_name": tag,
        "published_at": "2026-11-07T11:45:33Z",
        "html_url": f"https://github.com/ip7z/7zip/releases/tag/{tag}",
        "assets": assets,
    }
    with open(os.path.join(folder, "release.json"), "w") as f:
        json.dump(release, f, indent=2)
    with open(os.path.join(folder, "SHA256SUMS"), "w") as f:
        f.writelines(sums)
PY

# Truncated archive fixture (release.json and SHA256SUMS keep the original
# digest, so the updater must reject it).
cp -R "$FIX/fix2606" "$FIX/truncated"
head -c 50000 "$FIX/fix2606/7z2606-mac.tar.xz" > "$FIX/truncated/7z2606-mac.tar.xz"

# MARK: - Installed 26.05 app

if [[ ! -d "$APP" ]]; then
    echo "==> dist/Finder7.app is missing; building it"
    "$ROOT/Scripts/build-app.sh"
fi

TEST_APP="$WORK/Finder7Test.app"
ditto "$APP" "$TEST_APP"
rm -f "$TEST_APP/Contents/Resources/7zz.previous" "$TEST_APP/Contents/Resources/7zz.new"
cp "$WORK/2605-7zz" "$TEST_APP/Contents/Resources/7zz"
chmod +x "$TEST_APP/Contents/Resources/7zz"
python3 - "$TEST_APP/Contents/Resources/homelab-app.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    manifest = json.load(f)
manifest["dependencies"][0]["version"] = "26.05"
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
printf 'official-binary\n' > "$TEST_APP/Contents/Resources/engine-provenance.txt"
codesign --force --sign - --timestamp=none "$TEST_APP/Contents/Resources/7zz" >/dev/null
codesign --force --deep --sign - --timestamp=none "$TEST_APP" >/dev/null
assert_app "$TEST_APP" "26.05"

BIN="$TEST_APP/Contents/MacOS/Finder7"

# MARK: - Check and apply 26.06

echo
echo "==> 26.05 -> 26.06"
set +e
"$BIN" --self-update --check --from-dir "$FIX/fix2606" >"$WORK/check2606.json" 2>"$WORK/check2606.err"
check_code=$?
set -e
[[ $check_code -eq 2 ]] && pass "check exits 2 when an update is available" || fail "check exit was $check_code (expected 2)"
python3 - "$WORK/check2606.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    check = json.load(f)
assert check["installedVersion"] == "26.05"
assert check["latestVersion"] == "26.06"
assert check["updateAvailable"] is True
PY
[[ $? -eq 0 ]] && pass "check reports 26.05 -> 26.06" || fail "check JSON is wrong"

"$BIN" --self-update --apply --from-dir "$FIX/fix2606" >"$WORK/apply2606.json" 2>"$WORK/apply2606.err"
pass "apply exited 0"
assert_app "$TEST_APP" "26.06" "26.05"
[[ -f "$TEST_APP/Contents/Resources/7zz.previous" ]] && pass "previous engine kept after update" || fail "previous engine not kept"

# MARK: - Simulated newer release flashes the badge, applying clears it

echo
echo "==> simulated 26.07 release"
set +e
"$BIN" --self-update --check --from-dir "$FIX/fix2607" >"$WORK/check2607.json" 2>"$WORK/check2607.err"
check_code=$?
set -e
[[ $check_code -eq 2 ]] && pass "simulated newer release raises the update badge" || fail "simulated check exit was $check_code"
"$BIN" --self-update --apply --from-dir "$FIX/fix2607" >"$WORK/apply2607.json" 2>"$WORK/apply2607.err"
pass "simulated update applied"
assert_app "$TEST_APP" "26.07" "26.06"
set +e
"$BIN" --self-update --check --from-dir "$FIX/fix2607" >"$WORK/check2607b.json" 2>"$WORK/check2607b.err"
check_code=$?
set -e
[[ $check_code -eq 0 ]] && pass "applying the update clears the badge" || fail "post-update check exit was $check_code"
python3 - "$WORK/check2607b.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    check = json.load(f)
assert check["updateAvailable"] is False
assert check["installedVersion"] == "26.07"
PY
[[ $? -eq 0 ]] && pass "post-update check reports up to date" || fail "post-update check JSON is wrong"

# MARK: - Failure modes leave the installed engine and signature intact

echo
echo "==> failure modes"
assert_failure() {
    local name="$1" fixture="$2" expected="$3"
    local out="$WORK/$name.out" err="$WORK/$name.err"
    set +e
    "$BIN" --self-update --apply --from-dir "$fixture" >"$out" 2>"$err"
    local code=$?
    set -e
    if [[ $code -eq 0 ]]; then
        fail "$name: apply unexpectedly succeeded"
        return
    fi
    pass "$name: apply failed"
    grep -Eqi "$expected" "$err" && pass "$name: error mentions $expected" || fail "$name: unexpected error: $(cat "$err")"
    assert_app "$TEST_APP" "26.07"
    [[ ! -e "$TEST_APP/Contents/Resources/7zz.new" ]] && pass "$name: no 7zz.new left behind" || fail "$name: 7zz.new left behind"
}

assert_failure "truncated" "$FIX/truncated" "SHA-256|bytes|truncated"
assert_failure "wrong-arch" "$FIX/badarch" "arm64|architecture"

chmod -R a-w "$TEST_APP"
set +e
"$BIN" --self-update --apply --from-dir "$FIX/fix2606" >"$WORK/readonly.out" 2>"$WORK/readonly.err"
ro_code=$?
set -e
chmod -R u+w "$TEST_APP"
[[ $ro_code -ne 0 ]] && pass "read-only bundle: apply refused" || fail "read-only bundle: apply succeeded"
grep -qi "not writable" "$WORK/readonly.err" && pass "read-only bundle: clear message" || fail "read-only bundle: unexpected error $(cat "$WORK/readonly.err")"
assert_app "$TEST_APP" "26.07"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: $FAIL failure(s), $PASS check(s) passed"
    exit 1
fi
echo "RESULT: self-update integration passed ($PASS checks)"
