#!/bin/zsh
set -euo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=C

script_path="${0:A}"
root="${script_path:h:h}"
artifact_dir="$root/artifacts"
verify_tmp_parent="$artifact_dir/release-verify-tmp"
release_config_loader="$root/tools/release-config.zsh"
release_conf="$root/tools/release.conf"
trusted_allowed_signers="$root/trust/allowed_signers"
trusted_revoked_signers="$root/trust/revoked_signers"
verify_tmp_dir=""
sandbox_token_dir=""

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: tools/${script_path:t} RELEASE_DIR" >&2
}

cleanup_on_exit() {
  if [[ -n "$sandbox_token_dir" && -d "$sandbox_token_dir" ]]; then
    /bin/rm -rf -- "$sandbox_token_dir"
  fi
  if [[ -n "$verify_tmp_dir" && -d "$verify_tmp_dir" ]]; then
    /bin/rm -rf -- "$verify_tmp_dir"
  fi
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_safe_existing_dir() {
  local dir="$1"
  local label="$2"
  local owner mode ls_line

  [[ -e "$dir" || -L "$dir" ]] || die "missing $label: $dir"
  [[ ! -L "$dir" ]] || die "$label is a symlink: $dir"
  [[ -d "$dir" ]] || die "$label is not a directory: $dir"

  read -r owner mode < <(/usr/bin/stat -f '%u %Lp' "$dir")
  [[ "$owner" == "$EUID" ]] || die "$label is not owned by the current user: $dir"
  (( (8#$mode & 8#022) == 0 )) || die "$label is group/world writable: $dir"

  ls_line="$(/bin/ls -lde "$dir")"
  ls_line="${ls_line%%$'\n'*}"
  [[ "${ls_line[11]}" != "+" ]] || die "$label has an ACL: $dir"
}

require_safe_existing_file() {
  local file="$1"
  local label="$2"
  local owner mode ls_line

  [[ -e "$file" || -L "$file" ]] || die "missing $label: $file"
  [[ ! -L "$file" ]] || die "$label is a symlink: $file"
  [[ -f "$file" ]] || die "$label is not a regular file: $file"

  read -r owner mode < <(/usr/bin/stat -f '%u %Lp' "$file")
  [[ "$owner" == "$EUID" ]] || die "$label is not owned by the current user: $file"
  (( (8#$mode & 8#022) == 0 )) || die "$label is group/world writable: $file"

  ls_line="$(/bin/ls -le "$file")"
  ls_line="${ls_line%%$'\n'*}"
  [[ "${ls_line[11]}" != "+" ]] || die "$label has an ACL: $file"
}

ensure_private_dir() {
  local dir="$1"
  local label="$2"
  local parent

  parent="${dir:h}"
  require_safe_existing_dir "$parent" "parent of $label"

  if [[ -e "$dir" || -L "$dir" ]]; then
    require_safe_existing_dir "$dir" "$label"
  else
    /bin/mkdir "$dir"
  fi

  /bin/chmod 700 "$dir"
  require_safe_existing_dir "$dir" "$label"
}

validate_version() {
  [[ "$1" =~ '^[1-9][0-9]*$' ]] || die "invalid manifest version"
}

validate_source_commit() {
  [[ "$1" =~ '^[0-9a-f]{40}$' ]] || die "invalid source_commit"
}

validate_sha256() {
  [[ "$1" =~ '^[0-9a-f]{64}$' ]] || die "invalid SHA-256 value"
}

validate_created_utc() {
  [[ "$1" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] ||
    die "invalid created_utc"
}

validate_fingerprint_or_empty() {
  local fingerprint="$1"
  local label="$2"

  [[ -z "$fingerprint" || "$fingerprint" =~ '^SHA256:[A-Za-z0-9+/]{43}$' ]] ||
    die "invalid $label"
}

sha256_file() {
  local file="$1"
  local line

  line="$(/usr/bin/shasum -a 256 "$file")"
  print -r -- "${line%% *}"
}

fingerprint_for_public_key() {
  local public_key="$1"
  local line

  line="$(/usr/bin/ssh-keygen -l -E sha256 -f "$public_key")"
  print -r -- "${${(z)line}[2]}"
}

fingerprint_for_allowed_signers() {
  local allowed_signers="$1"
  local tmp_public_key="$2"
  local principal options key_type key_blob extra

  read -r principal options key_type key_blob extra < "$allowed_signers"
  [[ "$principal" == "$signer_identity" ]] || die "unexpected allowed_signers principal"
  [[ "$options" == "namespaces=\"$signing_namespace\"" ]] || die "unexpected allowed_signers namespace"
  [[ "$key_type" == "ssh-ed25519" ]] || die "unexpected allowed_signers key type"
  [[ "$key_blob" =~ '^[A-Za-z0-9+/=]+$' ]] || die "invalid allowed_signers key blob"
  [[ -z "$extra" ]] || die "unexpected trailing data in allowed_signers"

  print -r -- "$key_type $key_blob" > "$tmp_public_key"
  /bin/chmod 600 "$tmp_public_key"
  fingerprint_for_public_key "$tmp_public_key"
}

verify_manifest_signature() {
  local manifest="$1"
  local signature="$2"
  local allowed_signers="$3"
  local revoked_signers="$4"
  typeset -a revoked_args

  if [[ -s "$revoked_signers" ]]; then
    revoked_args=(-r "$revoked_signers")
  fi

  /usr/bin/ssh-keygen -Y verify \
    -f "$allowed_signers" \
    -I "$signer_identity" \
    -n "$signing_namespace" \
    -s "$signature" \
    "${revoked_args[@]}" \
    < "$manifest" >/dev/null
}

parse_manifest() {
  local manifest="$1"
  local line key value expected
  local index=1
  typeset -ga manifest_keys=(
    format
    project
    version
    source_commit
    archive
    archive_sha256
    created_utc
    signing_key_fingerprint
    next_signing_key_fingerprint
  )
  typeset -gA manifest_values

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || die "empty manifest line"
    [[ "$line" == *=* ]] || die "invalid manifest line: $line"

    expected="${manifest_keys[$index]-}"
    [[ -n "$expected" ]] || die "unexpected extra manifest line: $line"

    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" == "$expected" ]] || die "unexpected manifest field: $key"
    manifest_values[$key]="$value"
    index=$((index + 1))
  done < "$manifest"

  [[ "$index" -eq $(( ${#manifest_keys[@]} + 1 )) ]] || die "manifest is missing fields"
}

verify_manifest_values() {
  local archive_name expected_archive signing_fingerprint actual_archive_sha256
  local archive="$1"
  local public_key_tmp="$2"

  [[ "${manifest_values[format]}" == "$manifest_format" ]] || die "unexpected manifest format"
  [[ "${manifest_values[project]}" == "$project" ]] || die "unexpected manifest project"
  validate_version "${manifest_values[version]}"
  validate_source_commit "${manifest_values[source_commit]}"
  validate_sha256 "${manifest_values[archive_sha256]}"
  validate_created_utc "${manifest_values[created_utc]}"
  validate_fingerprint_or_empty "${manifest_values[signing_key_fingerprint]}" "signing_key_fingerprint"
  validate_fingerprint_or_empty "${manifest_values[next_signing_key_fingerprint]}" "next_signing_key_fingerprint"

  expected_archive="$archive_project-${manifest_values[version]}.tar.gz"
  archive_name="${archive:t}"
  [[ "${manifest_values[archive]}" == "$expected_archive" ]] || die "unexpected manifest archive name"
  [[ "$archive_name" == "$expected_archive" ]] || die "archive path does not match manifest"

  signing_fingerprint="$(fingerprint_for_allowed_signers "$trusted_allowed_signers" "$public_key_tmp")"
  [[ "${manifest_values[signing_key_fingerprint]}" == "$signing_fingerprint" ]] ||
    die "manifest signing_key_fingerprint does not match trusted allowed_signers"

  actual_archive_sha256="$(sha256_file "$archive")"
  [[ "$actual_archive_sha256" == "${manifest_values[archive_sha256]}" ]] ||
    die "archive SHA-256 mismatch"
}

verify_archive_listing() {
  local archive="$1"

  /usr/bin/tar -tf "$archive" >/dev/null
  if /usr/bin/tar -tf "$archive" |
    /usr/bin/awk '/(^|\/)\._/ { found = 1 } END { exit found ? 0 : 1 }'; then
    die "archive contains AppleDouble metadata"
  fi
}

find_release_manifest() {
  local release_dir="$1"
  local -a manifests

  manifests=("$release_dir"/"$archive_project"-*-manifest.txt(N.))
  case "${#manifests[@]}" in
    1) print -r -- "${manifests[1]}" ;;
    0) die "missing release manifest in $release_dir" ;;
    *) die "multiple release manifests found in $release_dir" ;;
  esac
}

main() {
  local release_dir manifest signature archive
  local archive_name expected_archive expected_manifest tmp_public_key

  case "$#" in
    1) ;;
    *) usage; exit 1 ;;
  esac

  require stat
  require ls
  require rm
  require chmod
  require tar
  require shasum
  require ssh-keygen
  require awk

  require_safe_existing_file "$release_config_loader" "release config loader"
  . "$release_config_loader"
  load_release_conf "$release_conf"

  release_dir="${1:A}"
  require_safe_existing_dir "$root" "project root"
  require_safe_existing_dir "$release_dir" "release directory"
  require_safe_existing_file "$trusted_allowed_signers" "trusted allowed signers file"
  require_safe_existing_file "$trusted_revoked_signers" "trusted revoked signers file"

  manifest="$(find_release_manifest "$release_dir")"
  signature="$manifest.sig"

  require_safe_existing_file "$manifest" "release manifest"
  require_safe_existing_file "$signature" "release manifest signature"

  [[ -n "${OBSIDIAN_RELEASE_VERIFY_TMP_DIR:-}" ]] ||
    die "missing release verification temp directory"
  verify_tmp_dir="${OBSIDIAN_RELEASE_VERIFY_TMP_DIR:A}"
  case "$verify_tmp_dir" in
    "${verify_tmp_parent:A}"/*) ;;
    *) die "release verification temp directory must be under $verify_tmp_parent" ;;
  esac
  require_safe_existing_dir "$verify_tmp_dir" "release verification temp directory"
  tmp_public_key="$verify_tmp_dir/release-signing-key.pub"

  verify_manifest_signature "$manifest" "$signature" "$trusted_allowed_signers" "$trusted_revoked_signers"
  parse_manifest "$manifest"

  validate_version "${manifest_values[version]}"
  expected_archive="$archive_project-${manifest_values[version]}.tar.gz"
  expected_manifest="$archive_project-${manifest_values[version]}-manifest.txt"
  [[ "${manifest:t}" == "$expected_manifest" ]] || die "manifest path does not match manifest version"
  [[ "${signature:t}" == "$expected_manifest.sig" ]] || die "signature path does not match manifest version"
  archive_name="${manifest_values[archive]}"
  [[ "$archive_name" == "$expected_archive" ]] || die "unexpected manifest archive name"

  archive="$release_dir/$expected_archive"
  require_safe_existing_file "$archive" "release archive"
  verify_manifest_values "$archive" "$tmp_public_key"
  verify_archive_listing "$archive"

  echo "Release verified: $release_dir"
  echo "Version: ${manifest_values[version]}"
  echo "Archive SHA-256: ${manifest_values[archive_sha256]}"
}

verify_internal_sandbox_invocation() {
  local expected_token

  [[ "${OBSIDIAN_RELEASE_INTERNAL:-}" == "verify" ]] ||
    die "invalid internal release verification environment"
  [[ -n "${OBSIDIAN_RELEASE_TOKEN:-}" ]] || die "missing internal release verification token"
  [[ -n "${OBSIDIAN_RELEASE_TOKEN_FILE:-}" ]] || die "missing internal release verification token file"
  [[ -f "$OBSIDIAN_RELEASE_TOKEN_FILE" ]] || die "missing internal release verification token file"

  expected_token="$(< "$OBSIDIAN_RELEASE_TOKEN_FILE")"
  [[ "$expected_token" == "$OBSIDIAN_RELEASE_TOKEN" ]] ||
    die "invalid internal release verification token"
}

require_internal_sandbox() {
  local probe="/private/tmp/obsidian-release-verify-sandbox-probe.$$.$RANDOM"

  [[ ! -e "$probe" && ! -L "$probe" ]] ||
    die "sandbox probe path already exists: $probe"

  if ( print -r -- "probe" > "$probe" ) 2>/dev/null; then
    /bin/rm -f -- "$probe"
    die "internal release verification must run under sandbox-exec"
  fi
}

run_internal_sandboxed_verify() {
  local release_dir="$1"

  verify_internal_sandbox_invocation
  require_internal_sandbox
  main "$release_dir"
}

run_sandboxed_verify() {
  local release_dir="$1"
  local profile sandbox_home token token_file rc

  require sandbox-exec
  require uuidgen
  require mktemp

  release_dir="${release_dir:A}"
  require_safe_existing_dir "$root" "project root"
  require_safe_existing_dir "$release_dir" "release directory"
  require_safe_existing_file "$trusted_allowed_signers" "trusted allowed signers file"
  require_safe_existing_file "$trusted_revoked_signers" "trusted revoked signers file"

  profile="$root/sandbox/release-verify.sb"
  [[ -f "$profile" ]] || die "missing sandbox profile: $profile"

  ensure_private_dir "$artifact_dir" "artifacts directory"
  ensure_private_dir "$verify_tmp_parent" "release verification temp directory"
  ensure_private_dir "$verify_tmp_parent/home" "release verification sandbox home"

  sandbox_home="$verify_tmp_parent/home/verify"
  ensure_private_dir "$sandbox_home" "release verification sandbox phase home"

  sandbox_token_dir="$(/usr/bin/mktemp -d "$verify_tmp_parent/tokens.XXXXXX")"
  /bin/chmod 700 "$sandbox_token_dir"
  verify_tmp_dir="$(/usr/bin/mktemp -d "$verify_tmp_parent/work.XXXXXX")"
  /bin/chmod 700 "$verify_tmp_dir"
  token="verify.$$.$(/usr/bin/uuidgen)"
  token_file="$sandbox_token_dir/verify.token"
  print -r -- "$token" > "$token_file"
  /bin/chmod 600 "$token_file"

  set +e
  /usr/bin/env -i \
    HOME="$sandbox_home" \
    TMPDIR="$verify_tmp_parent" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LC_ALL=C \
    OBSIDIAN_RELEASE_INTERNAL="verify" \
    OBSIDIAN_RELEASE_TOKEN="$token" \
    OBSIDIAN_RELEASE_TOKEN_FILE="$token_file" \
    OBSIDIAN_RELEASE_VERIFY_TMP_DIR="$verify_tmp_dir" \
    /usr/bin/sandbox-exec \
      -f "$profile" \
      -D ROOT="$root" \
      -D RELEASE_DIR="$release_dir" \
      -D TMP="$verify_tmp_parent" \
      -D HOME="$sandbox_home" \
      /bin/zsh "$script_path" --internal-sandbox "$release_dir"
  rc="$?"
  set -e

  cleanup_on_exit
  return "$rc"
}

case "$#" in
  1)
    trap cleanup_on_exit EXIT
    run_sandboxed_verify "$1"
    ;;
  2)
    [[ "$1" == "--internal-sandbox" ]] || { usage; exit 1; }
    trap cleanup_on_exit EXIT
    run_internal_sandboxed_verify "$2"
    ;;
  *)
    usage
    exit 1
    ;;
esac
