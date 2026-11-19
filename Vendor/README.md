# 7-Zip engine

`Vendor/7zz` is the official prebuilt **universal** macOS 7-Zip engine. The
binary is **not committed** to this repository; `fetch-engine.sh` downloads,
verifies and installs it.

- Version: **26.06**
- Tag: `26.06`
- Provenance: `official-binary` (official GitHub release assets, not compiled here)
- Upstream: <https://github.com/ip7z/7zip>
- Release: <https://github.com/ip7z/7zip/releases/tag/26.06>
- Lock file: `Vendor/7zip.lock.json`
- License: `License.txt` from the official tarball; `unRarLicense.txt` from the 7-Zip source distribution

## Assets

| Architecture | Asset | SHA-256 | Minimum macOS |
| --- | --- | --- | --- |
| arm64 | `7z2606-mac.tar.xz` | `b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd` | 11.0 |
| x86_64 | `7z2606-mac-x64.tar.xz` | `3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586` | 10.15 |

Both slices are combined with `lipo -create`; the resulting `Vendor/7zz` is:

- Architectures: `x86_64 arm64`
- SHA-256: `b190ccc5220ac0f77fd739bde72639ef6dcd0a4644e56729d70b850a017aa74d`
- Banner: `7-Zip (z) 26.06 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-11-06`

Refresh it with:

```bash
./Scripts/fetch-engine.sh            # current latest release
./Scripts/fetch-engine.sh 26.06    # a specific release
./Scripts/fetch-engine.sh --from-dir /path/to/fixtures
```

Do not edit `Vendor/7zz` by hand. Normal product updates and the in-app
self-update path both install official binary releases, verify their SHA-256,
check the architecture and banner, and re-sign `Contents/Resources`.
