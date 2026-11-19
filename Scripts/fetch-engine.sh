#!/usr/bin/env bash
# Fetches the official prebuilt macOS 7-Zip binaries, verifies them, lipos the
# arm64 + x86_64 slices, and refreshes Vendor/7zz plus Vendor/7zip.lock.json.
#
# The engine binary is not committed to the repository. Run this once after
# cloning, then build the app with ./Scripts/build-app.sh.
#
# Usage:
#   ./Scripts/fetch-engine.sh [version]
#   ./Scripts/fetch-engine.sh [version] --from-dir <dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
LOCK="$VENDOR/7zip.lock.json"
OUT="$VENDOR/7zz"
FROM_DIR=""
TARGET=""
API_LATEST="https://api.github.com/repos/ip7z/7zip/releases/latest"

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-dir)
            [[ $# -ge 2 ]] || die "--from-dir requires a directory"
            FROM_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [[ -z "$TARGET" ]] || die "only one version may be specified"
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -n "$FROM_DIR" ]]; then
    FROM_DIR="$(cd "$FROM_DIR" 2>/dev/null && pwd)" || die "no such fixture directory: $FROM_DIR"
fi

TARGET_FROM_LATEST=0
if [[ -z "$TARGET" ]]; then
    if [[ -n "$FROM_DIR" ]]; then
        TARGET="$(python3 - "$FROM_DIR" <<'PY'
import json, os, re, sys
directory = sys.argv[1]
tags = set()
for name in os.listdir(directory):
    m = re.match(r"^7z(\d{2})(\d{2})-mac(?:-x64)?\.tar\.xz$", name)
    if m:
        tags.add(f"{m.group(1)}.{m.group(2)}")
release = os.path.join(directory, "release.json")
if os.path.exists(release):
    with open(release) as f:
        tag = json.load(f).get("tag_name")
    if tag:
        tags.add(tag)
if not tags:
    sys.exit(1)
print(max(tags, key=lambda v: tuple(int(x) for x in v.split("."))))
PY
        )" || die "could not infer a version from $FROM_DIR; pass a version explicitly"
    else
        TARGET="$("$ROOT/Scripts/check-upstream.sh" --print-latest)" \
            || die "could not determine the latest 7-Zip release"
        TARGET_FROM_LATEST=1
    fi
fi

[[ "$TARGET" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "invalid version/tag: $TARGET"
CODE="${TARGET//./}"
ARM_NAME="7z${CODE}-mac.tar.xz"
X64_NAME="7z${CODE}-mac-x64.tar.xz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sevenzip-fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/arm" "$WORK/x64"

info "7-Zip $TARGET"
if [[ -n "$FROM_DIR" ]]; then
    info "Fixture directory: $FROM_DIR"
    python3 - "$FROM_DIR" "$TARGET" "$ARM_NAME" "$X64_NAME" > "$WORK/meta.tsv" <<'PY'
import hashlib, json, os, re, sys
directory, tag, arm_name, x64_name = sys.argv[1:]
expected = [arm_name, x64_name]
recorded = {}

release_path = os.path.join(directory, "release.json")
if os.path.exists(release_path):
    with open(release_path) as f:
        release = json.load(f)
    release_tag = release.get("tag_name")
    if release_tag and release_tag != tag:
        print(f"ERROR\trelease.json is {release_tag}, not {tag}")
        sys.exit(0)
    for asset in release.get("assets", []):
        digest = (asset.get("digest") or "").lower()
        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]
        if len(digest) == 64:
            recorded[asset["name"]] = digest

for sums_name in ("SHA256SUMS", "sha256sums.txt", "SHA256SUMS.txt"):
    sums_path = os.path.join(directory, sums_name)
    if not os.path.exists(sums_path):
        continue
    with open(sums_path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and len(parts[0]) == 64:
                recorded.setdefault(parts[1].lstrip("*"), parts[0].lower())

lock_path = os.path.join(directory, "7zip.lock.json")
if os.path.exists(lock_path):
    with open(lock_path) as f:
        lock = json.load(f)
    if lock.get("version") == tag:
        assets = lock.get("assets")
        if isinstance(assets, dict):
            for value in assets.values():
                if value.get("name") and value.get("sha256"):
                    recorded.setdefault(value["name"], value["sha256"].lower())
        elif isinstance(assets, list):
            for value in assets:
                if value.get("name") and value.get("sha256"):
                    recorded.setdefault(value["name"], value["sha256"].lower())
        for name, value in (lock.get("tarballSha256") or {}).items():
            recorded.setdefault(name, value.lower())

found = 0
for name in expected:
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        continue
    found += 1
    size = os.path.getsize(path)
    recorded_sha = recorded.get(name)
    if recorded_sha:
        sha = recorded_sha
        source = path
        flag = "1"
    else:
        with open(path, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        source = path
        flag = "0"
    print(f"ASSET\t{name}\t{source}\t{sha}\t{size}\t{flag}")
if not found:
    print("ERROR\tno official macOS tarballs for this version")
PY
else
    info "Downloading release metadata from GitHub"
    API="$API_LATEST"
    if [[ "$TARGET_FROM_LATEST" != "1" ]]; then
        API="https://api.github.com/repos/ip7z/7zip/releases/tags/$TARGET"
    fi
    STATUS="$(curl -sSL --retry 2 --max-time 60 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: sevenzip-gui-fetch-engine' \
        -w '%{http_code}' -o "$WORK/release.json" "$API" || true)"
    if [[ "$STATUS" != "200" ]]; then
        echo "error: GitHub release API returned HTTP ${STATUS:-?}" >&2
        [[ -s "$WORK/release.json" ]] && head -c 800 "$WORK/release.json" >&2 && echo >&2
        exit 1
    fi
    python3 - "$WORK/release.json" "$TARGET" "$ARM_NAME" "$X64_NAME" > "$WORK/meta.tsv" <<'PY'
import json, sys
path, tag, arm_name, x64_name = sys.argv[1:]
with open(path) as f:
    release = json.load(f)
release_tag = release.get("tag_name")
if release_tag != tag:
    print(f"ERROR\tGitHub returned {release_tag}, not {tag}")
    sys.exit(0)
expected = [arm_name, x64_name]
found = 0
for asset in release.get("assets", []):
    name = asset.get("name")
    if name not in expected:
        continue
    url = asset.get("browser_download_url", "")
    if not url.startswith("https://github.com/ip7z/7zip/releases/download/"):
        print(f"ERROR\t{name} has an unexpected download URL: {url}")
        sys.exit(0)
    digest = (asset.get("digest") or "").lower()
    if digest.startswith("sha256:"):
        digest = digest[len("sha256:"):]
    if len(digest) != 64:
        print(f"ERROR\t{name} has no SHA-256 digest in the release metadata")
        sys.exit(0)
    found += 1
    print(f"ASSET\t{name}\t{url}\t{digest}\t{asset.get('size', 0)}\t1")
if not found:
    print("ERROR\tthe release has no macOS assets")
PY
fi

ARM_SRC=""; ARM_SHA=""; ARM_SIZE=""; ARM_RECORDED=""
X64_SRC=""; X64_SHA=""; X64_SIZE=""; X64_RECORDED=""
while IFS=$'\t' read -r kind name source sha size recorded; do
    case "$kind" in
        ERROR) die "$name" ;;
        ASSET)
            case "$name" in
                "$ARM_NAME") ARM_SRC="$source"; ARM_SHA="$sha"; ARM_SIZE="$size"; ARM_RECORDED="$recorded" ;;
                "$X64_NAME") X64_SRC="$source"; X64_SHA="$sha"; X64_SIZE="$size"; X64_RECORDED="$recorded" ;;
            esac
            ;;
    esac
done < "$WORK/meta.tsv"

[[ -n "$ARM_SRC" ]] || die "release $TARGET has no macOS asset ($ARM_NAME)"
if [[ -z "$X64_SRC" ]]; then
    warn "release $TARGET has no $X64_NAME; the arm64 asset must be universal"
fi
[[ "$ARM_RECORDED" == "1" ]] || warn "no recorded SHA-256 for $ARM_NAME; verifying the downloaded file against its own hash"
if [[ -n "$X64_SRC" && "$X64_RECORDED" != "1" ]]; then
    warn "no recorded SHA-256 for $X64_NAME; verifying the downloaded file against its own hash"
fi

download_or_copy() {
    local name="$1" source="$2" expected_sha="$3" expected_size="$4"
    local destination="$WORK/$name"
    if [[ -n "$FROM_DIR" ]]; then
        cp "$source" "$destination"
    else
        info "Downloading $name"
        if ! curl -fL --retry 3 --retry-delay 2 --max-time 300 \
                -H 'User-Agent: sevenzip-gui-fetch-engine' \
                -o "$destination" "$source"; then
            die "could not download $name"
        fi
    fi
    [[ -f "$destination" ]] || die "missing downloaded file $name"
    local actual_size actual_sha
    actual_size="$(stat -f%z "$destination")"
    if [[ -n "$expected_size" && "$expected_size" != "0" && "$actual_size" != "$expected_size" ]]; then
        die "$name is $actual_size bytes; metadata says $expected_size"
    fi
    actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        die "$name failed SHA-256 verification (expected $expected_sha, got $actual_sha)"
    fi
    info "$name  sha256 $actual_sha  ($actual_size bytes)"
}

download_or_copy "$ARM_NAME" "$ARM_SRC" "$ARM_SHA" "$ARM_SIZE"
if [[ -n "$X64_SRC" ]]; then
    download_or_copy "$X64_NAME" "$X64_SRC" "$X64_SHA" "$X64_SIZE"
fi

info "Extracting and verifying"
tar -xJf "$WORK/$ARM_NAME" -C "$WORK/arm"
ARM_BIN="$(find "$WORK/arm" -type f -name 7zz | head -1)"
[[ -n "$ARM_BIN" && -x "$ARM_BIN" ]] || die "$ARM_NAME does not contain an executable 7zz"
LICENSE="$(find "$WORK/arm" -type f -name License.txt | head -1)"
[[ -n "$LICENSE" ]] || die "$ARM_NAME does not contain License.txt"
[[ -s "$LICENSE" ]] || die "$ARM_NAME has an empty License.txt"

ARM_ARCHS="$(lipo -archs "$ARM_BIN")"
[[ "$ARM_ARCHS" == *"arm64"* ]] || die "$ARM_NAME has no arm64 slice (found: $ARM_ARCHS)"

X64_BIN=""
if [[ -n "$X64_SRC" ]]; then
    tar -xJf "$WORK/$X64_NAME" -C "$WORK/x64"
    X64_BIN="$(find "$WORK/x64" -type f -name 7zz | head -1)"
    [[ -n "$X64_BIN" && -x "$X64_BIN" ]] || die "$X64_NAME does not contain an executable 7zz"
    X64_ARCHS="$(lipo -archs "$X64_BIN")"
    [[ "$X64_ARCHS" == *"x86_64"* ]] || die "$X64_NAME has no x86_64 slice (found: $X64_ARCHS)"
fi

UNIVERSAL="$WORK/7zz.universal"
if [[ "$ARM_ARCHS" == *"x86_64"* ]]; then
    if [[ -n "$X64_BIN" ]]; then
        warn "$ARM_NAME is itself universal; ignoring $X64_NAME for lipo"
    fi
    cp "$ARM_BIN" "$UNIVERSAL"
elif [[ -n "$X64_BIN" ]]; then
    lipo -create -output "$UNIVERSAL" "$ARM_BIN" "$X64_BIN"
else
    die "the arm64 asset is not universal and $X64_NAME is missing; cannot ship a universal engine"
fi
chmod +x "$UNIVERSAL"

FINAL_ARCHS="$(lipo -archs "$UNIVERSAL")"
[[ "$FINAL_ARCHS" == *"arm64"* && "$FINAL_ARCHS" == *"x86_64"* ]] \
    || die "final engine is not universal (found: $FINAL_ARCHS)"

BANNER_FILE="$WORK/banner.txt"
"$UNIVERSAL" >"$BANNER_FILE" 2>&1 || true
BANNER="$(awk 'NF { print; exit }' "$BANNER_FILE")"
[[ "$BANNER" == *"$TARGET"* ]] || die "7zz banner does not contain $TARGET: ${BANNER:-<no output>}"

minos() {
    local binary="$1" arch="$2"
    otool -arch "$arch" -l "$binary" 2>/dev/null | awk '
        /LC_BUILD_VERSION/ { in_build = 1 }
        in_build && /minos/ { print $2; exit }
        /LC_VERSION_MIN_MACOSX/ { in_min = 1 }
        in_min && /version/ { print $2; exit }
    '
}
ARM_MINOS="$(minos "$UNIVERSAL" arm64)"
X64_MINOS="$(minos "$UNIVERSAL" x86_64)"
ARM_MINOS="${ARM_MINOS:-11.0}"
X64_MINOS="${X64_MINOS:-10.15}"

# Everything below this line mutates Vendor/. All verification is complete.
[[ -f "$VENDOR/unRarLicense.txt" ]] \
    || die "Vendor/unRarLicense.txt is missing; restore it from git before fetching"

info "Installing Vendor/7zz"
cp "$UNIVERSAL" "$VENDOR/7zz.new"
chmod +x "$VENDOR/7zz.new"
mv "$VENDOR/7zz.new" "$OUT"

cp "$LICENSE" "$VENDOR/License.txt"

ENGINE_SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
LICENSE_SHA="$(shasum -a 256 "$VENDOR/License.txt" | awk '{print $1}')"
UNRAR_SHA="$(shasum -a 256 "$VENDOR/unRarLicense.txt" | awk '{print $1}')"
ARM_URL="https://github.com/ip7z/7zip/releases/download/$TARGET/$ARM_NAME"
X64_URL="https://github.com/ip7z/7zip/releases/download/$TARGET/$X64_NAME"

python3 - "$LOCK" "$TARGET" "$ARM_NAME" "$ARM_URL" "$ARM_SHA" "$ARM_MINOS" \
    "$X64_NAME" "$X64_URL" "$X64_SHA" "$X64_MINOS" "$ENGINE_SHA" \
    "$LICENSE_SHA" "$UNRAR_SHA" "$OUT" <<'PY'
import datetime, json, os, sys
(
    path, version, arm_name, arm_url, arm_sha, arm_minos,
    x64_name, x64_url, x64_sha, x64_minos, engine_sha,
    license_sha, unrar_sha, out,
) = sys.argv[1:]
assets = {
    "arm64": {
        "name": arm_name,
        "url": arm_url,
        "sha256": arm_sha,
        "minimumMacOS": arm_minos,
    }
}
if x64_sha:
    assets["x86_64"] = {
        "name": x64_name,
        "url": x64_url,
        "sha256": x64_sha,
        "minimumMacOS": x64_minos,
    }
data = {
    "version": version,
    "tag": version,
    "repo": "https://github.com/ip7z/7zip",
    "source": "official-binary",
    "assets": assets,
    "tarballSha256": {a["name"]: a["sha256"] for a in assets.values()},
    "engine": "Vendor/7zz",
    "engineSha256": engine_sha,
    "licenseSha256": license_sha,
    "unrarLicenseSha256": unrar_sha,
    "licenseSource": "official-tarball",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("Wrote", path)
PY

cat > "$VENDOR/README.md" <<EOF
# Vendored 7-Zip engine

\`Vendor/7zz\` is the official prebuilt **universal** macOS 7-Zip engine.

- Version: **$TARGET**
- Tag: \`$TARGET\`
- Provenance: \`official-binary\` (official GitHub release assets, not compiled here)
- Upstream: <https://github.com/ip7z/7zip>
- Release: <https://github.com/ip7z/7zip/releases/tag/$TARGET>
- Lock file: \`Vendor/7zip.lock.json\`
- License: \`License.txt\` from the official tarball; \`unRarLicense.txt\` retained from the source tree

## Assets

| Architecture | Asset | SHA-256 | Minimum macOS |
| --- | --- | --- | --- |
| arm64 | \`$ARM_NAME\` | \`$ARM_SHA\` | $ARM_MINOS |
EOF
if [[ -n "$X64_SRC" ]]; then
    cat >> "$VENDOR/README.md" <<EOF
| x86_64 | \`$X64_NAME\` | \`$X64_SHA\` | $X64_MINOS |
EOF
fi
cat >> "$VENDOR/README.md" <<EOF

Both slices are combined with \`lipo -create\`; the resulting \`Vendor/7zz\` is:

- Architectures: \`$FINAL_ARCHS\`
- SHA-256: \`$ENGINE_SHA\`
- Banner: \`$BANNER\`

Refresh it with:

\`\`\`bash
./Scripts/fetch-engine.sh            # current latest release
./Scripts/fetch-engine.sh $TARGET    # a specific release
./Scripts/fetch-engine.sh --from-dir /path/to/fixtures
\`\`\`

Do not edit \`Vendor/7zz\` by hand. Normal product updates and the in-app
self-update path both install official binary releases, verify their SHA-256,
check the architecture and banner, and re-sign \`Contents/Resources\`.
EOF

echo
echo "Installed 7-Zip $TARGET"
echo "  $OUT"
echo "  archs: $FINAL_ARCHS"
echo "  $BANNER"
echo "  sha256: $ENGINE_SHA"
echo
echo "Next: ./Scripts/build-app.sh (writes the bundle manifest and re-signs the app)"
