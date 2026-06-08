#!/bin/zsh
set -euo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=C

unset TAR_READER_OPTIONS TAR_WRITER_OPTIONS GZIP BZIP ZIPOPT
export COPYFILE_DISABLE=1

script_path="${0:A}"
root="${script_path:h:h}"
artifact_dir="$root/artifacts"
release_parent="$artifact_dir/releases"
release_tmp_parent="$artifact_dir/release-tmp"
release_lock_dir="$root/.release-sandboxed-obsidian.lock"
release_lock_acquired=0
sandbox_token_dir=""
temp_release_dir=""
temp_content_dir=""
temp_work_dir=""
internal_sandbox=0

release_config_loader="$root/tools/release-config.zsh"
release_conf="$root/tools/release.conf"
version_file="$root/VERSION"
release_public_key="$root/trust/release_signing_key.pub"
allowed_signers_source="$root/trust/allowed_signers"
revoked_signers_source="$root/trust/revoked_signers"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<EOF
usage: tools/${script_path:t}

Environment:
  SOURCE_COMMIT       40-character lowercase source commit id
  RELEASE_SIGNING_KEY OpenSSH ed25519 private key path

Optional:
  NEXT_SIGNING_KEY_FINGERPRINT Future OpenSSH SHA256 fingerprint for key rotation
EOF
}

cleanup_on_exit() {
  local pid

  if [[ -n "$sandbox_token_dir" && -d "$sandbox_token_dir" ]]; then
    /bin/rm -rf -- "$sandbox_token_dir"
  fi
  if [[ -n "$temp_release_dir" && -d "$temp_release_dir" ]]; then
    /bin/rm -rf -- "$temp_release_dir"
  fi
  if [[ -n "$temp_content_dir" && -d "$temp_content_dir" ]]; then
    /bin/rm -rf -- "$temp_content_dir"
  fi
  if [[ -n "$temp_work_dir" && -d "$temp_work_dir" ]]; then
    /bin/rm -rf -- "$temp_work_dir"
  fi

  if [[ "$release_lock_acquired" == "1" && -d "$release_lock_dir" ]]; then
    pid="$(< "$release_lock_dir/pid" 2>/dev/null || true)"
    if [[ "$pid" == "$$" ]]; then
      /bin/rm -rf -- "$release_lock_dir"
    fi
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

require_private_existing_file() {
  local file="$1"
  local label="$2"
  local owner mode

  require_safe_existing_file "$file" "$label"
  read -r owner mode < <(/usr/bin/stat -f '%u %Lp' "$file")
  (( (8#$mode & 8#077) == 0 )) ||
    die "$label must not be readable, writable, or executable by group or others: $file"
}

acquire_release_lock() {
  local pid_file="$release_lock_dir/pid"

  if ! /bin/mkdir "$release_lock_dir" 2>/dev/null; then
    die "another release appears to be running; lock exists: $release_lock_dir"
  fi

  release_lock_acquired=1
  /bin/chmod 700 "$release_lock_dir"
  print -r -- "$$" > "$pid_file"
  /bin/chmod 600 "$pid_file"
}

validate_version() {
  local version="$1"

  [[ "$version" =~ '^[1-9][0-9]*$' ]] || die "VERSION must be a monotonically increasing positive integer"
}

read_version() {
  local version

  require_safe_existing_file "$version_file" "version file"
  version="$(< "$version_file")"
  version="${version%$'\n'}"
  version="${version%$'\r'}"
  validate_version "$version"
  print -r -- "$version"
}

validate_source_commit() {
  local source_commit="$1"

  [[ "$source_commit" =~ '^[0-9a-f]{40}$' ]] || die "SOURCE_COMMIT must be 40 lowercase hexadecimal characters"
}

validate_fingerprint_or_empty() {
  local fingerprint="$1"
  local label="$2"

  [[ -z "$fingerprint" || "$fingerprint" =~ '^SHA256:[A-Za-z0-9+/]{43}$' ]] ||
    die "$label must be empty or an OpenSSH SHA256 fingerprint"
}

validate_release_path() {
  local path="$1"
  local segment

  [[ "$path" =~ '^[A-Za-z0-9._/+()-]+$' ]] || die "invalid release path: $path"
  [[ "$path" != /* ]] || die "release path must be relative: $path"
  [[ "$path" != */ ]] || die "release path must name a file: $path"
  [[ "$path" != *'//'* ]] || die "release path contains empty segment: $path"

  for segment in "${(@s:/:)path}"; do
    [[ -n "$segment" ]] || die "release path contains empty segment: $path"
    [[ "$segment" != "." && "$segment" != ".." ]] || die "release path contains unsafe segment: $path"
  done
}

validate_release_mode() {
  local mode="$1"

  case "$mode" in
    0644|0755) ;;
    *) die "invalid release file mode: $mode" ;;
  esac
}

sha256_file() {
  local file="$1"
  local line

  line="$(/usr/bin/shasum -a 256 "$file")"
  print -r -- "${line%% *}"
}

mtree_escape_value() {
  local value="$1"

  value="${value//\\/\\134}"
  value="${value//$'\t'/\\011}"
  value="${value// /\\040}"
  print -r -- "$value"
}

public_key_for_private_key() {
  local private_key="$1"
  local public_key="$2"
  local paired_public_key="${private_key}.pub"

  if [[ -f "$paired_public_key" && ! -L "$paired_public_key" ]]; then
    /bin/cp "$paired_public_key" "$public_key"
  else
    /usr/bin/ssh-keygen -y -f "$private_key" > "$public_key"
  fi

  /bin/chmod 600 "$public_key"
}

fingerprint_for_public_key() {
  local public_key="$1"
  local line

  line="$(/usr/bin/ssh-keygen -l -E sha256 -f "$public_key")"
  print -r -- "${${(z)line}[2]}"
}

prepare_output_dirs() {
  ensure_private_dir "$artifact_dir" "artifacts directory"
  ensure_private_dir "$release_parent" "release directory"
  ensure_private_dir "$release_tmp_parent" "release temp directory"
}

max_existing_version() {
  local dir base max=0

  for dir in "$release_parent"/*(N/); do
    base="${dir:t}"
    if [[ "$base" =~ '^[1-9][0-9]*$' && "$base" -gt "$max" ]]; then
      max="$base"
    fi
  done

  print -r -- "$max"
}

prepare_release_files() {
  local list_file="$root/tools/source-archive-files.txt"
  local line mode path extra source_file staged_file previous_path=""
  local -a fields
  typeset -gA release_file_modes
  typeset -ga release_file_paths

  require_safe_existing_file "$list_file" "release file list"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    fields=(${(z)line})
    [[ "${#fields[@]}" -eq 2 ]] || die "invalid release file list line: $line"
    mode="${fields[1]}"
    path="${fields[2]}"
    validate_release_mode "$mode"
    validate_release_path "$path"

    [[ -z "${release_file_modes[$path]-}" ]] || die "duplicate release file path: $path"
    [[ -z "$previous_path" || "$path" > "$previous_path" ]] ||
      die "release file list is not sorted: $path"
    previous_path="$path"

    source_file="$root/$path"
    require_safe_existing_file "$source_file" "release source file"

    release_file_modes[$path]="$mode"
    release_file_paths+=("$path")

    staged_file="$temp_content_dir/$path"
    /bin/mkdir -p "${staged_file:h}"
    /bin/cp "$source_file" "$staged_file"
    /bin/chmod "$mode" "$staged_file"
  done < "$list_file"

  (( ${#release_file_paths[@]} > 0 )) || die "release file list is empty"
}

write_mtree_spec() {
  local mtree_file="$1"
  local archive_root="$2"
  local path dir parent file content_path escaped_content_path mode
  typeset -A dirs

  dirs[$archive_root]=1
  for file in "${release_file_paths[@]}"; do
    dir="${file:h}"
    while [[ "$dir" != "." && -n "$dir" ]]; do
      dirs[$archive_root/$dir]=1
      parent="${dir:h}"
      [[ "$parent" == "$dir" ]] && break
      dir="$parent"
    done
  done

  {
    print -r -- "#mtree"
    for path in ${(ok)dirs}; do
      print -r -- "./$path type=dir uid=0 gid=0 uname=root gname=wheel mode=0755 time=$fixed_archive_time"
    done
    for file in "${release_file_paths[@]}"; do
      mode="${release_file_modes[$file]}"
      content_path="$temp_content_dir/$file"
      escaped_content_path="$(mtree_escape_value "$content_path")"
      print -r -- "./$archive_root/$file type=file uid=0 gid=0 uname=root gname=wheel mode=$mode time=$fixed_archive_time content=$escaped_content_path"
    done
  } > "$mtree_file"

  /bin/chmod 600 "$mtree_file"
}

create_archive() {
  local version="$1"
  local archive="$2"
  local archive_root="$archive_project-$version"
  local mtree_file="$temp_work_dir/release.mtree"
  local tar_file="$temp_work_dir/${archive:t:r}"

  write_mtree_spec "$mtree_file" "$archive_root"
  /usr/bin/tar --format=ustar -cf "$tar_file" @"$mtree_file"
  /usr/bin/gzip -n -c "$tar_file" > "$archive"
  /bin/chmod 600 "$archive"
  /bin/rm -f "$tar_file"
}

verify_archive_listing() {
  local archive="$1"

  /usr/bin/tar -tf "$archive" >/dev/null
  if /usr/bin/tar -tf "$archive" |
    /usr/bin/awk '/(^|\/)\._/ { found = 1 } END { exit found ? 0 : 1 }'; then
    die "archive contains AppleDouble metadata"
  fi
}

write_manifest() {
  local manifest="$1"
  local version="$2"
  local source_commit="$3"
  local archive_name="$4"
  local archive_sha256="$5"
  local created_utc="$6"
  local signing_key_fingerprint="$7"
  local next_signing_key_fingerprint="$8"

  {
    print -r -- "format=$manifest_format"
    print -r -- "project=$project"
    print -r -- "version=$version"
    print -r -- "source_commit=$source_commit"
    print -r -- "archive=$archive_name"
    print -r -- "archive_sha256=$archive_sha256"
    print -r -- "created_utc=$created_utc"
    print -r -- "signing_key_fingerprint=$signing_key_fingerprint"
    print -r -- "next_signing_key_fingerprint=$next_signing_key_fingerprint"
  } > "$manifest"

  /bin/chmod 600 "$manifest"
}

sign_and_verify_manifest() {
  local signing_key="$1"
  local manifest="$2"
  local allowed_signers="$3"
  local revoked_signers="$4"
  typeset -a revoked_args

  /bin/rm -f "$manifest.sig"
  /usr/bin/ssh-keygen -Y sign \
    -f "$signing_key" \
    -n "$signing_namespace" \
    "$manifest" >/dev/null

  [[ -f "$manifest.sig" ]] || die "ssh-keygen did not create manifest signature"
  /bin/chmod 600 "$manifest.sig"

  if [[ -s "$revoked_signers" ]]; then
    revoked_args=(-r "$revoked_signers")
  fi

  /usr/bin/ssh-keygen -Y verify \
    -f "$allowed_signers" \
    -I "$signer_identity" \
    -n "$signing_namespace" \
    -s "$manifest.sig" \
    "${revoked_args[@]}" \
    < "$manifest" >/dev/null
}

main() {
  local version source_commit signing_key next_signing_key_fingerprint
  local release_dir archive_name archive manifest public_key
  local signing_key_fingerprint expected_signing_key_fingerprint created_utc archive_sha256 existing_max

  case "$#" in
    0) ;;
    *) usage; exit 1 ;;
  esac

  require zsh
  require stat
  require ls
  require mkdir
  require rm
  require cp
  require chmod
  require date
  require mktemp
  require mv
  require tar
  require gzip
  require shasum
  require ssh-keygen
  require awk

  require_safe_existing_file "$release_config_loader" "release config loader"
  . "$release_config_loader"
  load_release_conf "$release_conf"

  version="$(read_version)"
  source_commit="${SOURCE_COMMIT:-}"
  signing_key="${RELEASE_SIGNING_KEY:-}"
  next_signing_key_fingerprint="${NEXT_SIGNING_KEY_FINGERPRINT:-}"

  validate_source_commit "$source_commit"
  validate_fingerprint_or_empty "$next_signing_key_fingerprint" "NEXT_SIGNING_KEY_FINGERPRINT"
  [[ -n "$signing_key" ]] || die "missing RELEASE_SIGNING_KEY"
  signing_key="${signing_key:A}"
  require_private_existing_file "$signing_key" "release signing key"
  require_safe_existing_file "$release_public_key" "release public key"
  require_safe_existing_file "$allowed_signers_source" "allowed signers file"
  require_safe_existing_file "$revoked_signers_source" "revoked signers file"

  require_safe_existing_dir "$root" "project root"
  if [[ "$internal_sandbox" != "1" ]]; then
    acquire_release_lock
  fi
  prepare_output_dirs

  release_dir="$release_parent/$version"
  [[ ! -e "$release_dir" && ! -L "$release_dir" ]] || die "release already exists: $release_dir"

  existing_max="$(max_existing_version)"
  if [[ "$existing_max" -gt 0 && "$version" -le "$existing_max" ]]; then
    die "VERSION must be greater than existing release version $existing_max"
  fi

  temp_release_dir="$(/usr/bin/mktemp -d "$release_parent/.tmp.$version.XXXXXX")"
  temp_content_dir="$(/usr/bin/mktemp -d "$release_tmp_parent/content.XXXXXX")"
  temp_work_dir="$(/usr/bin/mktemp -d "$release_tmp_parent/work.XXXXXX")"
  /bin/chmod 700 "$temp_release_dir" "$temp_content_dir" "$temp_work_dir"

  public_key="$temp_work_dir/release-signing-key.pub"
  public_key_for_private_key "$signing_key" "$public_key"
  signing_key_fingerprint="$(fingerprint_for_public_key "$public_key")"
  expected_signing_key_fingerprint="$(fingerprint_for_public_key "$release_public_key")"
  [[ "$signing_key_fingerprint" == "$expected_signing_key_fingerprint" ]] ||
    die "release signing key fingerprint mismatch
expected: $expected_signing_key_fingerprint
actual:   $signing_key_fingerprint"

  prepare_release_files

  archive_name="$archive_project-$version.tar.gz"
  archive="$temp_release_dir/$archive_name"
  create_archive "$version" "$archive"
  verify_archive_listing "$archive"
  archive_sha256="$(sha256_file "$archive")"
  created_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

  manifest="$temp_release_dir/$archive_project-$version-manifest.txt"
  write_manifest \
    "$manifest" \
    "$version" \
    "$source_commit" \
    "$archive_name" \
    "$archive_sha256" \
    "$created_utc" \
    "$signing_key_fingerprint" \
    "$next_signing_key_fingerprint"

  sign_and_verify_manifest "$signing_key" "$manifest" "$allowed_signers_source" "$revoked_signers_source"
  /bin/mv "$temp_release_dir" "$release_dir"
  temp_release_dir=""

  echo "Release written to: $release_dir"
  echo "Archive SHA-256: $archive_sha256"
}

verify_internal_sandbox_invocation() {
  local expected_token

  [[ "${OBSIDIAN_RELEASE_INTERNAL:-}" == "sign" ]] ||
    die "invalid internal release signing environment"
  [[ -n "${OBSIDIAN_RELEASE_TOKEN:-}" ]] || die "missing internal release signing token"
  [[ -n "${OBSIDIAN_RELEASE_TOKEN_FILE:-}" ]] || die "missing internal release signing token file"
  [[ -f "$OBSIDIAN_RELEASE_TOKEN_FILE" ]] || die "missing internal release signing token file"

  expected_token="$(< "$OBSIDIAN_RELEASE_TOKEN_FILE")"
  [[ "$expected_token" == "$OBSIDIAN_RELEASE_TOKEN" ]] ||
    die "invalid internal release signing token"
}

require_internal_sandbox() {
  local probe="/private/tmp/obsidian-release-sign-sandbox-probe.$$.$RANDOM"

  [[ ! -e "$probe" && ! -L "$probe" ]] ||
    die "sandbox probe path already exists: $probe"

  if ( print -r -- "probe" > "$probe" ) 2>/dev/null; then
    /bin/rm -f -- "$probe"
    die "internal release signing must run under sandbox-exec"
  fi
}

run_internal_sandboxed_sign() {
  internal_sandbox=1
  verify_internal_sandbox_invocation
  require_internal_sandbox
  main
}

run_sandboxed_sign() {
  local version source_commit signing_key next_signing_key_fingerprint
  local profile sandbox_home token token_file signing_key_pub rc

  require sandbox-exec
  require uuidgen

  version="$(read_version)"
  source_commit="${SOURCE_COMMIT:-}"
  signing_key="${RELEASE_SIGNING_KEY:-}"
  next_signing_key_fingerprint="${NEXT_SIGNING_KEY_FINGERPRINT:-}"

  validate_version "$version"
  validate_source_commit "$source_commit"
  validate_fingerprint_or_empty "$next_signing_key_fingerprint" "NEXT_SIGNING_KEY_FINGERPRINT"
  [[ -n "$signing_key" ]] || die "missing RELEASE_SIGNING_KEY"
  signing_key="${signing_key:A}"
  signing_key_pub="${signing_key}.pub"

  require_private_existing_file "$signing_key" "release signing key"
  require_safe_existing_file "$release_public_key" "release public key"
  require_safe_existing_file "$allowed_signers_source" "allowed signers file"
  require_safe_existing_file "$revoked_signers_source" "revoked signers file"

  profile="$root/sandbox/release-sign.sb"
  [[ -f "$profile" ]] || die "missing sandbox profile: $profile"

  require_safe_existing_dir "$root" "project root"
  prepare_output_dirs
  ensure_private_dir "$release_tmp_parent/home" "release signing sandbox home"
  acquire_release_lock

  sandbox_home="$release_tmp_parent/home/sign"
  ensure_private_dir "$sandbox_home" "release signing sandbox phase home"

  sandbox_token_dir="$(/usr/bin/mktemp -d "$release_tmp_parent/tokens.XXXXXX")"
  /bin/chmod 700 "$sandbox_token_dir"
  token="sign.$$.$(/usr/bin/uuidgen)"
  token_file="$sandbox_token_dir/sign.token"
  print -r -- "$token" > "$token_file"
  /bin/chmod 600 "$token_file"

  set +e
  /usr/bin/sandbox-exec \
    -f "$profile" \
    -D ROOT="$root" \
    -D TMP="$release_tmp_parent" \
    -D HOME="$sandbox_home" \
    -D SIGNING_KEY="$signing_key" \
    -D SIGNING_KEY_PUB="$signing_key_pub" \
    /usr/bin/env -i \
      HOME="$sandbox_home" \
      TMPDIR="$release_tmp_parent" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LC_ALL=C \
      SOURCE_COMMIT="$source_commit" \
      RELEASE_SIGNING_KEY="$signing_key" \
      NEXT_SIGNING_KEY_FINGERPRINT="$next_signing_key_fingerprint" \
      OBSIDIAN_RELEASE_INTERNAL="sign" \
      OBSIDIAN_RELEASE_TOKEN="$token" \
      OBSIDIAN_RELEASE_TOKEN_FILE="$token_file" \
      /bin/zsh "$script_path" --internal-sandbox
  rc="$?"
  set -e

  cleanup_on_exit
  return "$rc"
}

case "$#" in
  0)
    trap cleanup_on_exit EXIT
    run_sandboxed_sign
    ;;
  1)
    [[ "$1" == "--internal-sandbox" ]] || { usage; exit 1; }
    trap cleanup_on_exit EXIT
    run_internal_sandboxed_sign
    ;;
  *)
    usage
    exit 1
    ;;
esac
