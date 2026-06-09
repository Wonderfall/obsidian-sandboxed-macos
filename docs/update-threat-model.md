# Update Threat Model

The release manifest authenticates a source archive and minimal provenance
metadata. It is not intended to prove that the archive contents match the
declared source commit; without Git on the release machine, `source_commit` is a
signed operator assertion.

The release signing and verification scripts run their core work under
`sandbox-exec` with dedicated Seatbelt profiles in `sandbox/`. The profiles are
intended to limit filesystem access during release creation and verification;
they are hardening layers, not the primary release trust anchor.

The release trust anchor is the `allowed_signers` policy in the local `trust/`
directory. The updater must:

1. Treat GitHub latest-release metadata as candidate discovery only, not as a
   trust decision.
2. Verify `obsidian-sandboxed-macos-$version-manifest.txt.sig` with the local
   trusted `allowed_signers` and `revoked_signers`, signer identity
   `release@wonderfall.dev`, and namespace
   `obsidian-sandboxed-macos.release@wonderfall.dev`.
3. Parse `obsidian-sandboxed-macos-$version-manifest.txt` as strict key/value
   data with fixed field order.
4. Reject unexpected formats, malformed values, missing files, symlinks where
   regular files are expected, or mismatched archive names.
5. Verify `archive_sha256` against the downloaded archive bytes.
6. Enforce downgrade protection by accepting only versions greater than the last
   trusted version stored locally. The trusted floor is the newer of the
   checkout `VERSION` and the newest verified download recorded in
   `artifacts/updates/accepted-version`.

This protects against archive substitution, unsigned manifest changes, signature
confusion across protocols, and replay of older releases after the fetcher has
verified a newer release.

It does not protect against compromise of the release signing private key,
compromise of the release machine before signing, or a first-run attacker who can
replace the built-in trust anchor before the updater is installed.
