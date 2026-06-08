# Release Manifest v1

Releases are source archives produced locally with macOS-provided tools. The
project does not rely on GitHub auto-generated source archives for release
integrity.

Shared release constants are stored in `tools/release.conf`, which is parsed as
strict key/value data by the release scripts.

Each release directory contains:

```text
obsidian-sandboxed-macos-$version-manifest.txt
obsidian-sandboxed-macos-$version-manifest.txt.sig
obsidian-sandboxed-macos-$version.tar.gz
```

Release verification uses local trusted files from `trust/` as the trust root.
The release directory does not include signer policy files.

The manifest is ASCII text with LF line endings, fixed field order, and one
final newline:

```text
format=obsidian-sandboxed-macos-release-v1
project=Wonderfall/obsidian-sandboxed-macos
version=1
source_commit=0123456789abcdef0123456789abcdef01234567
archive=obsidian-sandboxed-macos-1.tar.gz
archive_sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
created_utc=2026-06-06T00:00:00Z
signing_key_fingerprint=SHA256:SpvTWBpxkzomnK4fsymKTeyU1d5s6FjOcASZN189p2E
next_signing_key_fingerprint=
```

Field rules:

- `format` identifies this schema.
- `project` is fixed to `Wonderfall/obsidian-sandboxed-macos`.
- `version` is a positive monotonically increasing integer. Update clients must
  reject releases whose version is not greater than the last accepted version.
- `source_commit` is signed provenance supplied by the release operator.
- `archive` is exactly `obsidian-sandboxed-macos-$version.tar.gz`.
- `archive_sha256` is the SHA-256 digest of the archive bytes.
- `created_utc` is an audit timestamp in UTC.
- `signing_key_fingerprint` is the OpenSSH SHA256 fingerprint of the key that
  signed the manifest.
- `next_signing_key_fingerprint` is empty unless a future signing key is being
  announced.

The manifest filename is exactly
`obsidian-sandboxed-macos-$version-manifest.txt`. The signature filename is that
manifest filename with `.sig` appended.

The OpenSSH signature namespace is:

```text
obsidian-sandboxed-macos.release@wonderfall.dev
```

The release signer identity is:

```text
release@obsidian-sandboxed-macos
```
