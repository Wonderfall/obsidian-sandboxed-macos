# Sandboxed Obsidian on macOS

![Cute sandboxed Obsidian banner](docs/assets/readme-banner.jpg)

This project builds an app-sandboxed Obsidian bundle for macOS. It downloads
and verifies upstream Obsidian, replaces the runtime with the sandbox-compatible
Electron build, applies focused entitlements, and signs the result with
hardened runtime enabled.

It uses macOS-provided command line tools only. There are no Xcode, Homebrew, Node,
or Python dependencies, and the script does not patch Obsidian's ASAR archive.

*The cute illustration above does not accurately reflect all the properties and the
true purpose of sandboxing. For a better understanding, read the section below.*

*This project is independent and is not affiliated with, endorsed by, or sponsored
by Obsidian or Dynalist Inc. It is intended to help users build a local app bundle
for their own personal use; this project does not distribute Obsidian, Electron, or
generated app bundles.*

## Contents

- [Context](#context)
- [Build](#build)
- [How to use signed releases](#how-to-use-signed-releases-recommended)
- [Usage](#usage)
- [Settings](#settings)
- [Signing](#signing)
- [Pipeline hardening and threat model](#pipeline-hardening-and-threat-model)
- [Entitlements](#entitlements)
- [Uninstall](#uninstall)
- [Notes on further hardening](#notes-on-further-hardening)

## Context

### Sandboxing on macOS

Many applications distributed outside of the Mac App Store are not sandboxed. This
poses several concerns:

- **Privacy**: Unsandboxed applications have arbitrary access to user data, where
the main security boundary is Apple's TCC which is quite weak and known for bypasses.
They may also store data and preferences in unprotected directories that other
unsandboxed processes may spy on or exfiltrate.
- **Security**: Unsandboxed applications have by default access to a lot of
system capabilities which can turn out to be attack surface. Either the app is
malicious (e.g., through supply chain issues), or it is vulnerable to
adversary-controlled data (e.g., parsing vulnerabilities).

A good security posture is to promote the adoption of sandboxing, which restricts
applications by default as much as possible. This is the case on modern operating
systems such as Android and iOS. On macOS, applications published on the Mac App
Store are required to run in the [App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).
In the App Sandbox, apps are contained to their own data directory, and only
have a restricted set of capabilities by default. Developers choose entitlements
to adapt the sandbox to the features needed by their app. Also, if an app needs
access to a directory outside of its sandbox, the user should be able to grant
a scoped access to the desired folder/file. Sandboxing is not necessarily something
that should impact productivity negatively.

An alternative is to use a Seatbelt profile, much like [what Chromium does](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/README.md).
Seatbelt is used by macOS, even for the App Sandbox, but has some limitations.
It is a private API accessible through the deprecated `sandbox-exec`. While usable,
it is clear that the intended way is for applications to use the App Sandbox whenever possible.
Furthermore, it is very difficult to write a robust Seatbelt profile. Ideally, a sandboxing profile
should start from a policy that denies all resources, and adds only what's needed. The list
becomes long especially for GUI apps, and while AI agents can help, this can cause a lot of
unexpected breakage. There is a risk of adding more than what's required, and by using
Seatbelt only, it is possible to unintentionally add back broker launch escapes that Apple
patched for the App Sandbox. It is also not quite user-friendly, compared to granting
filesystem exceptions through the Finder picker.

### The case of Obsidian

Obsidian on macOS is not sandboxed, nor is distributed on the Mac App Store (MAS). That is partly because
Electron itself is not designed to run in the App Sandbox. But Electron provides builds known
as [MAS builds](https://www.electronjs.org/docs/latest/tutorial/mac-app-store-submission-guide), which
happen to be able to run in the App Sandbox. Essentially, an Electron-based app like Obsidian is composed
of web files plus Electron. The idea of this project is to surgically replace Electron with the MAS build
of Electron and enable the App Sandbox.

### Project goals

The immediate goal is to provide a solution for people to run a sandboxed build of Obsidian on
their macOS system, so they can start to use sandboxed apps as much as possible. Ideally,
they would not run unsandboxed apps at all, and use virtual machines for complex workflows
that can't be easily sandboxed by the OS sandbox like App Sandbox.

Additionally, the structure of this project can be reused for many other currently unsandboxed
applications.

In the long term, the goal of this project is to **raise awareness for developers and users**:
sandboxing is desirable, can be easily achievable with a bit of work from the developer, and should
not hinder your workflow as a user. Proving that point would be a real win.

### Challenges

The main challenge is project-specific more than anything: making sure the build is obtained as
securely as possible, mainly by mitigating supply chain weaknesses. The build script is
also hardened in many ways, with extra guarantees that it can run on a vanilla macOS
environment with no dependencies installed, and that it won't interfere with your system
(ironically by using a sandbox of its own, using Seatbelt profiles) in any case.

The update process can be delicate. While the sandboxed build should support ASAR updates (Obsidian
itself), it does not support updating Electron (nor does the original Obsidian for some reason,
but unsandboxed Electron apps can totally do that). The ideal workflow would be to distribute
updates through MAS, which is of course not possible; sharing resigned builds is less than ideal,
involves additional parties to trust arbitrarily, and would probably break ToS.

For project source updates, use the signed release assets described below rather
than GitHub's auto-generated source archives.


## Build

```sh
./build-sandboxed-obsidian.zsh
```

The output app is written to:

```text
artifacts/out/Obsidian Sandboxed.app
```

The script currently targets Apple Silicon (`arm64`). The default command
builds the app; inputs come from `pins.conf` and the environment variables
below.

To remove build artifacts and downloaded caches:

```sh
./build-sandboxed-obsidian.zsh clean
```

This removes `artifacts/`.

## How to use signed releases (recommended)

Use the project-owned release assets from [GitHub Releases](https://github.com/Wonderfall/obsidian-sandboxed-macos/releases),
not GitHub's auto-generated "Source code" archives. For version `$version`,
download:

```text
obsidian-sandboxed-macos-$version-manifest.txt
obsidian-sandboxed-macos-$version-manifest.txt.sig
obsidian-sandboxed-macos-$version.tar.gz
```

Signed releases offer extra security compared to just downloading the
archive or using `git` (which would require at least Xcode CLI tools).
They provide release intent and authenticity, especially for upgrade
paths, guaranteed by the cryptography provided by `openssh` (which is
a built-in macOS tool).

*A malicious source tree could weaken sandboxing, steal secrets or cause
harm do your device. That's why extra care was put into preventing
source/distribution compromission as much as possible.*

### First install (TOFU mitigations)

For a first install, the release signing policy is a trust-on-first-use (TOFU)
decision. It is suggested you mitigate TOFU as much as possible to bootstrap
trust. Generally, this can be done by verifying cryptographic assets through
independent paths, such as:

- A maintainer-controlled channel
- A previously saved copy
- Another trusted machine/network

While keeping this in mind, you can follow the suggested workflow below.

Download `allowed_signers` through an independent path, such as:

```sh
curl -O https://codeberg.org/Wonderfall/pubkeys/raw/branch/main/obsidian-sandboxed-macos/allowed_signers
```

Further mitigate by checking `allowed_signers` before relying on it:

```sh
shasum -a 256 allowed_signers
```

Expected SHA-256:

```text
f02c78685f09c1d695a6459f2f401da12e80e3fc35a34004df74cfb26adf4f08
```

*Note: verification is stronger the more independent paths you check.*

Proceed to verify the manifest signature:

```sh
ssh-keygen -Y verify \
  -f allowed_signers \
  -I release@wonderfall.dev \
  -n obsidian-sandboxed-macos.release@wonderfall.dev \
  -s obsidian-sandboxed-macos-$version-manifest.txt.sig \
  < obsidian-sandboxed-macos-$version-manifest.txt
```

Inspect the signed manifest and compare the archive hash:

```sh
cat obsidian-sandboxed-macos-$version-manifest.txt
shasum -a 256 obsidian-sandboxed-macos-$version.tar.gz
```

The manifest should match the expected release metadata, especially:

- `format=obsidian-sandboxed-macos-release-v1`
- `project=Wonderfall/obsidian-sandboxed-macos`
- `archive=obsidian-sandboxed-macos-$version.tar.gz`
- `signing_key_fingerprint=SHA256:SpvTWBpxkzomnK4fsymKTeyU1d5s6FjOcASZN189p2E`
- `archive_sha256` must equal the hash printed by `shasum`

You can now unpack, preferably using Archive Utility over `tar -xzf`
because the former is sandboxed.

### Update from an existing release

After first install, the current checkout becomes a trusted anchor for future updates.

#### Using the built-in tool (recommended)

You can have the existing trusted checkout fetch and verify a newer release
without extracting it or replacing anything:

```sh
./tools/fetch-latest-release.zsh
```

The fetcher uses GitHub release metadata only to discover candidate asset URLs.
The trusted decision still comes from the signed manifest, the local trust files,
the archive hash, and local downgrade protection. Verified release assets are
written under `artifacts/updates/$version/`; feel free to extract them to whatever
location you prefer (e.g. the parent folder of the current release).

#### Manually updating files

If you downloaded the release files yourself, put them in one directory, then
verify them from an existing trusted checkout:

```sh
./tools/verify-release.zsh /path/to/release-directory
```

*Note: unlike the built-in downloader, the verify script alone does not enforce
downgrade protection. As a rule, only accept a manually verified update when the
manifest `version` is greater than the current trusted `VERSION`.*

After verification succeeds, extract the archive and build from the extracted
source tree. You can use the latter as your new trust anchor for future
updates.

## Usage

After a successful build, copy or move the app bundle from `artifacts/out/` to `/Applications`
or `~/Applications` using Finder (recommended) or Terminal.

First-time launch (or launches after an update that didn't persist identity) may show a
Gatekeeper warning: that is expected because the app is not notarized, unless you used
Developer ID and notarized the app bundle. To run the app, you may need to select Open
anyway in System Settings → Privacy & Security (only once).

If you had Obsidian installed before, or any other previous Obsidian build with a different
identity, you may see an attempt to access `obsidian Safe Storage` in Keychain. Ideally,
this would not happen if we were able to change the ASAR's `package.json`, but since it's out
of scope for the project, the app will attempt to use and share the same Keychain Safe Storage.
You can choose Always Allow, or Deny, depending on your use of the Keychain features in Obsidian.
Deny shouldn't break other unrelated features. Alternatively, you can remove `obsidian Safe Storage`
in Keychain Access before reinstalling Obsidian with another identity.

Generally, Obsidian Sandboxed does not share the same storage and preferences
as the original Obsidian app. As with any sandboxed app, app data mostly lives in
`~/Library/Containers/dev.local.sandboxed.obsidian` (default). A nice property of this is that
you can use different Obsidian installations isolated from each other if you so desire.

At this moment, there is no known breakage caused by sandboxing Obsidian.

## Settings

Settings are provided as environment variables.

| Setting | Default | Purpose |
| --- | --- | --- |
| `OBSIDIAN_OUTPUT_APP_NAME` | `Obsidian Sandboxed` | Sets the `.app` directory name and `CFBundleDisplayName`. |
| `OBSIDIAN_OUTPUT_BUNDLE_NAME` | `Obsidian Sandboxed` | Sets `CFBundleName`; helper bundle and executable names are derived from it. |
| `OBSIDIAN_OUTPUT_BUNDLE_ID` | `dev.local.sandboxed.obsidian` | Sets the main app bundle id; helper bundle ids are derived from it. |
| `OBSIDIAN_APP_GROUP_TEAM_ID` | `LOCALOBSDN` | Sets the prefix used for `ElectronTeamID` and the application group. |
| `SIGN_IDENTITY` | `-` | Code signing identity. `-` means ad hoc signing. |
| `SIGN_TIMESTAMP` | `auto` | Timestamp signing when set to `1`; disable with `0`. `auto` enables timestamping for `Developer ID Application:` identities. Rejected with ad hoc signing. |

Examples:

```sh
OBSIDIAN_OUTPUT_BUNDLE_ID="dev.local.my-obsidian" ./build-sandboxed-obsidian.zsh

OBSIDIAN_OUTPUT_APP_NAME="Obsidian Magic" \
OBSIDIAN_OUTPUT_BUNDLE_NAME="Obsidian Magic" \
./build-sandboxed-obsidian.zsh

SIGN_IDENTITY="Your Code Signing Identity" ./build-sandboxed-obsidian.zsh
```

## Signing

### Ad hoc signing (default)

By default, builds are ad hoc signed because they have less friction and do not
require prior setup. However, they do not persist indentity, and cryptographic
trust therefore can be broken across updates. In practice, this means access to
the keychain-backed safe storage will require you to allow access after an update,
and you may lose filesystem grants (you will need to manually open vaults again).

For explicit ad hod signing, `SIGN_IDENTITY` should be set to `-`.

### Self-signing (recommended)

To make identity persistent, you can use self-signing for free. The suggested 
approach is to generate a code signing certificate in the Keychain Access app.

For example, you can follow these steps:

1. Open Keychain Access (`/System/Library/CoreServices/Applications/Keychain Access.app`).
2. Choose Keychain Access → Certificate Assistant → Create a Certificate.
3. Name it Local Code Signing: Obsidian Sandboxed (LOCALOBSDN).
4. Set Identity Type to Self Signed Root.
5. Set Certificate Type to Code Signing.
6. Enable Let me override defaults.
7. Set a longer validity period (in days) if you want (optional).
8. Enter personal information if you want (optional).
8. Use either RSA 4096 bits or ECC 384/512 bits.
9. Keep other options by default, continue until generation is finished.
10. Still from Keychain Access, open your new certificate.
11. Unfold the "Trust" settings.
12. Set When using this certificate to Never Trust.
13. In the list below, set Code Signing to Always Trust.

Keep the private key in your login keychain and do not share it. The recommended
approach for hygiene is to generate one local certificate per app identity, e.g.
keep a local certificate for the Obsidian builder script, but do not use it
elsewhere.

You may want to first verify that the new identity is usable:

```
security find-identity -v -p codesigning
```

When building, set `SIGN_IDENTITY` to the name you set in step 3. For example:

```sh
SIGN_IDENTITY="Local Code Signing: Obsidian Sandboxed (LOCALOBSDN)" \
./build-sandboxed-obsidian.zsh
```

When signing with a local keychain identity, macOS may ask whether
`codesign` may use the private key. Choose `Always Allow` once so later
rebuilds can reuse the same signing identity without repeated prompts.


### Developer ID (paid)

*This approach is untested and not supported, but should work in theory. If you
encounter any trouble, please provide logs.*

You must first enroll in the [Apple Developer Program](https://developer.apple.com/programs/),
which costs approximately $100 a year.

For a Developer ID identity, set the app-group team prefix to the same Apple
team id and use a bundle id you intend to own for that signed build:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
OBSIDIAN_APP_GROUP_TEAM_ID="TEAMID" \
OBSIDIAN_OUTPUT_BUNDLE_ID="com.example.obsidian-sandboxed" \
./build-sandboxed-obsidian.zsh
```

The script timestamps normal `Developer ID Application: ... (TEAMID)` identities
automatically. If you pass a Developer ID identity by SHA-1 hash instead of by
name, also set `SIGN_TIMESTAMP=1`. The app-group team prefix must match the
Developer ID team id.

For now, notarization and stapling are separate release steps. Example:

```sh
ditto -c -k --keepParent --sequesterRsrc \
  "artifacts/out/Obsidian Sandboxed.app" \
  "artifacts/out/Obsidian-Sandboxed-notary.zip"

xcrun notarytool submit \
  "artifacts/out/Obsidian-Sandboxed-notary.zip" \
  --keychain-profile "notary-profile" \
  --wait

xcrun stapler staple "artifacts/out/Obsidian Sandboxed.app"
xcrun stapler validate "artifacts/out/Obsidian Sandboxed.app"
spctl --assess --type execute --verbose=4 "artifacts/out/Obsidian Sandboxed.app"
```

Note that tools such as `xcrun` may require installing command line tools from
Xcode.

*Publicly sharing your signed app is not recommended as it may break Apple's or Obsidian's ToS.*

## Pipeline hardening and threat model

This scripts aims to implement several hardening measures against supply-chain
compromission. Machine state can't be completely untrusted as any malicious program
running as the user can already do enough harm, but user configuration is untrusted
as much as possible.

The script (non-exhaustively):

- parses `pins.conf` as data, rejecting unknown, duplicate, missing, or
  malformed pin values;
- pins the expected GitHub and GitHub asset TLS intermediate certificates by
  SHA-256 digest;
- invokes `curl` with `--disable` so user curl config files are ignored;
- downloads the pinned Obsidian DMG itself and verifies its SHA-256;
- checks the upstream Obsidian bundle id, Developer ID team, certificate common
  name, and Gatekeeper assessment before replacing the runtime;
- verifies Electron's checksum file against a pinned SHA-256, verifies the ZIP
  hash listed inside it, and verifies that hash against the downloaded ZIP;
- runs each build phase under `sandbox-exec` using the least-privilege profiles
  in `sandbox/`;
- removes standalone Mach-O executables outside the known app/helper executable
  set before signing;
- sets `umask 077`, keeps private build directories at mode `700`, and keeps
  generated entitlements and downloaded pinned artifacts at mode `600`;
- verifies the final app signature and compares signed parent/helper
  entitlements against the generated entitlement files.

Everything should be auditable/readable either by humans or AI agents. As a
consequence of some hardening measures, the script has grown quite a bit longer
than originally hoped. It is suggested that you try to read and understand it
so that you can build trust before using it.

Note that Electron version is intentionally not mirrored from the one shipped
with the original Obsidian installer. That way, Electron updates can be faster,
so Electron gets patched quicker for security vulnerabilities.

## Entitlements

The entitlement set is intentionally small. Some entitlements provide sandbox
functionality directly; others are compatibility requirements for Electron.

| Entitlement | Scope | Purpose |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | Parent, helpers | Enables the macOS App Sandbox. |
| `com.apple.security.application-groups` | Parent | Provides the generated app group used with Electron's `ElectronTeamID`. |
| `com.apple.security.files.user-selected.read-write` | Parent | Allows the user to grant read/write access to vaults outside the container. |
| `com.apple.security.files.bookmarks.app-scope` | Parent | Allows persisted security-scoped bookmarks for user-selected vaults. |
| `com.apple.security.network.client` | Parent | Allows outbound network access for Obsidian features such as sync, plugins, and web requests. |
| `com.apple.security.cs.allow-jit` | Parent, helpers | Allows V8/Chromium JIT code generation required by Electron. |
| `com.apple.security.cs.disable-library-validation` | Parent, helpers | Allows Electron/Obsidian native modules and libraries needed at runtime. |
| `com.apple.security.inherit` | Helpers | Makes helper apps inherit the parent sandbox context. |

The source entitlement plists live in `entitlements/`. The parent plist contains
an `__APP_GROUP__` placeholder, which the script replaces in the generated
`artifacts/build/entitlements/parent.entitlements` file before signing.

Feel free to tweak the entitlements **if and only if** you know what you're doing.
Some things may break. For instance, you could make an Obsidian build with no
network at all, by removing the relevant entitlements. In any case, you should
refer to the [Apple documentation](https://developer.apple.com/documentation/Security/app-sandbox).

## Uninstall

To cleanly uninstall sandboxed Obsidian, remove every:

- Installed `<OBSIDIAN_OUTPUT_APP_NAME>.app` from the locations you used (e.g., `/Applications`)
- Application data at `~/Library/Containers/<OBSIDIAN_OUTPUT_BUNDLE_ID>`
- Self-signing certificates you created for this purpose (if any)

Vaults are usually external locations, so they're preserved. Remove them
separately if you want to.

## Notes on further hardening

This build does not enable Electron's renderer sandbox or V8 jitless mode. Such
hardening is possible but requires ASAR file patching, which is currently not
in the scope of this project due to maintenance pressure.
