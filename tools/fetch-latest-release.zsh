#!/bin/zsh
set -euo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=C

script_path="${0:A}"
root="${script_path:h:h}"
artifact_dir="$root/artifacts"
update_parent="$artifact_dir/updates"
update_tmp_parent="$artifact_dir/update-tmp"
verify_tmp_parent="$artifact_dir/release-verify-tmp"
accepted_version_file="$update_parent/accepted-version"
fetch_lock_dir="$root/.fetch-latest-release.lock"
fetch_lock_acquired=0
temp_release_dir=""
published_release_dir=""
release_publish_complete=0
preserve_release_metadata=0

release_config_loader="$root/tools/release-config.zsh"
release_conf="$root/tools/release.conf"
verify_script="$root/tools/verify-release.zsh"
version_file="$root/VERSION"
pins_file="$root/pins.conf"
trusted_allowed_signers="$root/trust/allowed_signers"
trusted_revoked_signers="$root/trust/revoked_signers"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: tools/${script_path:t}" >&2
}

cleanup_on_exit() {
  local path

  if [[ -n "$published_release_dir" && "$release_publish_complete" != "1" && -d "$published_release_dir" ]]; then
    /bin/rm -rf -- "$published_release_dir"
  fi
  if [[ -n "$temp_release_dir" && -d "$temp_release_dir" ]]; then
    /bin/rm -rf -- "$temp_release_dir"
  fi
  if [[ -d "$update_tmp_parent" ]]; then
    for path in \
      "$update_tmp_parent"/accepted-version.*(N) \
      "$update_tmp_parent"/github-release.json.*(N) \
      "$update_tmp_parent"/github-tls-head.*(N) \
      "$update_tmp_parent"/*.download.*(N) \
      "$update_tmp_parent"/*.tls.*(N) \
      "$update_tmp_parent"/fetch-token.*(N); do
      /bin/rm -f -- "$path"
    done
    if [[ "$preserve_release_metadata" != "1" ]]; then
      for path in "$update_tmp_parent"/release-metadata.*(N); do
        /bin/rm -f -- "$path"
      done
    fi
    for path in "$update_tmp_parent"/tls-certs.*(N/); do
      /bin/rm -rf -- "$path"
    done
  fi
  /bin/rmdir \
    "$update_tmp_parent/home/fetch" \
    "$update_tmp_parent/home" \
    "$update_tmp_parent" \
    "$verify_tmp_parent/home/verify" \
    "$verify_tmp_parent/home" \
    "$verify_tmp_parent" \
    "$update_parent" \
    "$artifact_dir" 2>/dev/null || true
  if [[ "$fetch_lock_acquired" == "1" && -d "$fetch_lock_dir" ]]; then
    /bin/rm -rf -- "$fetch_lock_dir"
  fi
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

acquire_fetch_lock() {
  local pid_file="$fetch_lock_dir/pid"

  if ! /bin/mkdir "$fetch_lock_dir" 2>/dev/null; then
    die "another release fetch appears to be running; lock exists: $fetch_lock_dir"
  fi

  fetch_lock_acquired=1
  /bin/chmod 700 "$fetch_lock_dir"
  print -r -- "$$" > "$pid_file"
  /bin/chmod 600 "$pid_file"
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
  [[ "$1" =~ '^[1-9][0-9]*$' ]] || die "invalid release version: $1"
}

read_version_file() {
  local file="$1"
  local label="$2"
  local version

  require_safe_existing_file "$file" "$label"
  version="$(< "$file")"
  version="${version%$'\n'}"
  version="${version%$'\r'}"
  validate_version "$version"
  print -r -- "$version"
}

read_accepted_version() {
  local version

  if [[ ! -e "$accepted_version_file" && ! -L "$accepted_version_file" ]]; then
    print -r -- 0
    return
  fi

  version="$(read_version_file "$accepted_version_file" "accepted update version file")"
  print -r -- "$version"
}

write_accepted_version() {
  local version="$1"
  local tmp

  validate_version "$version"
  tmp="$(make_temp_file accepted-version)"
  print -r -- "$version" > "$tmp"
  /bin/chmod 600 "$tmp"
  /bin/mv -f "$tmp" "$accepted_version_file"
}

max_version() {
  local left="$1"
  local right="$2"

  if [[ "$left" -ge "$right" ]]; then
    print -r -- "$left"
  else
    print -r -- "$right"
  fi
}

load_pins() {
  local file="$1"
  local line key value
  typeset -A seen
  typeset -ga required_pins=(
    github_tls_intermediate_sha256
    github_assets_tls_intermediate_sha256
  )

  require_safe_existing_file "$file" "pins file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "invalid pins line: $line"

    key="${line%%=*}"
    value="${line#*=}"

    [[ "$key" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || die "invalid pin key: $key"
    [[ -n "$value" ]] || die "empty pin value for $key"

    case "$key" in
      obsidian_version|obsidian_sha256|obsidian_bundle_id|obsidian_team_id|obsidian_certificate_common_name|electron_version|electron_zip_sha256|electron_shasums_sha256|github_tls_intermediate_sha256|github_assets_tls_intermediate_sha256) ;;
      *) die "unknown pin key: $key" ;;
    esac

    [[ -z "${seen[$key]-}" ]] || die "duplicate pin key: $key"
    seen[$key]=1
    pins[$key]="$value"
  done < "$file"

  for key in "${required_pins[@]}"; do
    [[ -n "${seen[$key]-}" ]] || die "missing pin key: $key"
  done

  [[ "${pins[github_tls_intermediate_sha256]}" =~ '^[0-9a-f]{64}(,[0-9a-f]{64})*$' ]] ||
    die "invalid github_tls_intermediate_sha256 pin"
  [[ "${pins[github_assets_tls_intermediate_sha256]}" =~ '^[0-9a-f]{64}(,[0-9a-f]{64})*$' ]] ||
    die "invalid github_assets_tls_intermediate_sha256 pin"
}

load_release_context() {
  require_safe_existing_file "$release_config_loader" "release config loader"
  require_safe_existing_file "$release_conf" "release config"
  . "$release_config_loader"
  load_release_conf "$release_conf"
}

require_github_tls_pin_support() {
  local version
  version="$(/usr/bin/curl --disable -V | /usr/bin/awk 'NR == 1 { print $2 }')"

  /usr/bin/curl --disable -V | /usr/bin/awk '
    NR == 1 {
      split($2, v, ".")
      exit (v[1] > 7 || (v[1] == 7 && v[2] >= 88)) ? 0 : 1
    }
  ' || die "GitHub TLS pinning requires curl >= 7.88.0 for %{certs}; found curl $version"

  require openssl
}

make_temp_file() {
  local name="$1"
  /usr/bin/mktemp "$update_tmp_parent/${name}.XXXXXX"
}

make_temp_dir() {
  local name="$1"
  /usr/bin/mktemp -d "$update_tmp_parent/${name}.XXXXXX"
}

url_host() {
  local url="$1"
  local rest host

  [[ "$url" == https://* ]] || return 1
  rest="${url#https://}"
  host="${rest%%/*}"
  host="${host%%:*}"
  [[ -n "$host" ]] || return 1

  print -r -- "${host:l}"
}

github_tls_pins_for_host() {
  local host="$1"

  case "$host" in
    github.com|api.github.com)
      print -r -- "${pins[github_tls_intermediate_sha256]}"
      ;;
    release-assets.githubusercontent.com|objects.githubusercontent.com)
      print -r -- "${pins[github_assets_tls_intermediate_sha256]}"
      ;;
    *)
      return 1
      ;;
  esac
}

sha256_list_contains() {
  local list="$1"
  local needle="$2"
  local item

  for item in "${(@s:,:)list}"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

cert_is_ca() {
  local cert="$1"

  /usr/bin/openssl x509 -in "$cert" -noout -text |
    /usr/bin/awk '
      /X509v3 Basic Constraints/ { seen = 1; if (/CA:TRUE/) found = 1; next }
      seen && /CA:TRUE/ { found = 1; exit }
      seen && /^[[:space:]]*X509v3/ { exit }
      END { exit found ? 0 : 1 }
    '
}

cert_sha256_fingerprint() {
  local cert="$1"

  /usr/bin/openssl x509 -in "$cert" -noout -fingerprint -sha256 |
    /usr/bin/awk -F= '/Fingerprint/ { gsub(":", "", $2); print tolower($2); exit }'
}

verify_github_tls_pins() {
  local tls_info="$1"
  local effective_url host expected cert_dir cert count fingerprint
  local matched=0

  effective_url="$(/usr/bin/awk '/^URL_EFFECTIVE=/ { sub(/^URL_EFFECTIVE=/, ""); print; exit }' "$tls_info")"
  [[ -n "$effective_url" ]] || {
    echo "error: missing curl effective URL for TLS pin check" >&2
    return 1
  }

  host="$(url_host "$effective_url")" || {
    echo "error: invalid HTTPS URL for TLS pin check: $effective_url" >&2
    return 1
  }

  expected="$(github_tls_pins_for_host "$host")" || {
    echo "error: unexpected GitHub download host: $host" >&2
    return 1
  }

  cert_dir="$(make_temp_dir tls-certs)"

  /usr/bin/awk -v dir="$cert_dir" '
    /-----BEGIN CERTIFICATE-----/ {
      in_cert = 1
      n++
      file = sprintf("%s/cert-%02d.pem", dir, n)
    }
    in_cert {
      print > file
    }
    /-----END CERTIFICATE-----/ {
      in_cert = 0
      close(file)
    }
  ' "$tls_info"

  count=0
  for cert in "$cert_dir"/cert-*.pem(N); do
    count=$((count + 1))
    if cert_is_ca "$cert"; then
      fingerprint="$(cert_sha256_fingerprint "$cert")"
      if sha256_list_contains "$expected" "$fingerprint"; then
        matched=1
        break
      fi
    fi
  done

  /bin/rm -rf "$cert_dir"

  [[ "$count" -gt 0 ]] || {
    echo "error: missing certificate chain for TLS pin check: $host" >&2
    return 1
  }

  [[ "$matched" == "1" ]] || {
    echo "error: GitHub TLS intermediate pin mismatch for $host" >&2
    return 1
  }
}

check_github_tls_url() {
  local url="$1"
  local tls_info

  tls_info="$(make_temp_file github-tls-head)"

  if ! /usr/bin/curl \
    --disable \
    --fail \
    --silent \
    --show-error \
    --head \
    --proto '=https' \
    --tlsv1.2 \
    --cacert /private/etc/ssl/cert.pem \
    --connect-timeout 20 \
    --max-time 60 \
    --output /dev/null \
    --write-out 'URL_EFFECTIVE=%{url_effective}
CERTS_BEGIN
%{certs}' \
    "$url" > "$tls_info"; then
    /bin/rm -f "$tls_info"
    return 1
  fi

  if ! verify_github_tls_pins "$tls_info"; then
    /bin/rm -f "$tls_info"
    return 1
  fi

  /bin/rm -f "$tls_info"
}

download_file() {
  local url="$1"
  local out="$2"
  local tmp
  local tls_info

  tmp="$(make_temp_file "${out:t}.download")"
  tls_info="$(make_temp_file "${out:t}.tls")"

  if ! check_github_tls_url "$url"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  if ! /usr/bin/curl \
    --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --cacert /private/etc/ssl/cert.pem \
    --retry 3 \
    --connect-timeout 20 \
    --max-time 1800 \
    --max-redirs 5 \
    --speed-limit 1024 \
    --speed-time 60 \
    --output "$tmp" \
    --write-out 'URL_EFFECTIVE=%{url_effective}
CERTS_BEGIN
%{certs}' \
    "$url" > "$tls_info"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  if ! verify_github_tls_pins "$tls_info"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  /bin/chmod 600 "$tmp"
  /bin/mv -f "$tmp" "$out"
  /bin/rm -f "$tls_info"
}

download_json() {
  local url="$1"
  local out="$2"
  local tmp
  local tls_info

  tmp="$(make_temp_file "${out:t}.download")"
  tls_info="$(make_temp_file "${out:t}.tls")"

  if ! /usr/bin/curl \
    --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --cacert /private/etc/ssl/cert.pem \
    --retry 3 \
    --connect-timeout 20 \
    --max-time 60 \
    --max-redirs 3 \
    -H "Accept: application/vnd.github+json" \
    --output "$tmp" \
    --write-out 'URL_EFFECTIVE=%{url_effective}
CERTS_BEGIN
%{certs}' \
    "$url" > "$tls_info"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  if ! verify_github_tls_pins "$tls_info"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  /bin/chmod 600 "$tmp"
  /bin/mv -f "$tmp" "$out"
  /bin/rm -f "$tls_info"
}

json_raw() {
  local file="$1"
  local key="$2"
  local type="$3"

  /usr/bin/plutil -extract "$key" raw -expect "$type" -o - "$file"
}

validate_release_asset_url() {
  local url="$1"
  local name="$2"
  local prefix="https://github.com/$project/releases/download/"

  [[ "$url" == "$prefix"*"/$name" ]] || die "unexpected release asset URL for $name: $url"
}

validate_update_tmp_path() {
  local path="$1"
  local label="$2"

  path="${path:A}"
  case "$path" in
    "${update_tmp_parent:A}"/*) ;;
    *) die "$label must be under $update_tmp_parent" ;;
  esac
  [[ "$path" != *"/../"* && "$path" != */.. && "$path" != */. && "$path" != *"/./"* ]] ||
    die "$label contains unsafe path components"
}

parse_release_json() {
  local json="$1"
  local assets_count draft prerelease tag_name
  local index name url version_part discovered_version=""
  local expected_manifest expected_signature expected_archive
  typeset -A asset_urls

  draft="$(json_raw "$json" draft bool)"
  prerelease="$(json_raw "$json" prerelease bool)"
  [[ "$draft" == "false" ]] || die "GitHub release is a draft"
  [[ "$prerelease" == "false" ]] || die "GitHub release is a prerelease"

  tag_name="$(json_raw "$json" tag_name string)"
  [[ "$tag_name" =~ '^[A-Za-z0-9._+-]+$' ]] || die "invalid GitHub release tag name"

  assets_count="$(json_raw "$json" assets array)"
  [[ "$assets_count" =~ '^[0-9]+$' && "$assets_count" -gt 0 ]] ||
    die "GitHub release has no assets"

  for (( index = 0; index < assets_count; index++ )); do
    name="$(json_raw "$json" "assets.$index.name" string)"
    url="$(json_raw "$json" "assets.$index.browser_download_url" string)"
    [[ "$name" =~ '^[A-Za-z0-9._+-]+$' ]] || die "invalid GitHub release asset name: $name"
    [[ -z "${asset_urls[$name]-}" ]] || die "duplicate GitHub release asset: $name"
    asset_urls[$name]="$url"

    if [[ "$name" == "$archive_project"-*-manifest.txt ]]; then
      version_part="${name#$archive_project-}"
      version_part="${version_part%-manifest.txt}"
      validate_version "$version_part"
      [[ -z "$discovered_version" ]] || die "multiple release manifests found in GitHub release assets"
      discovered_version="$version_part"
    fi
  done

  [[ -n "$discovered_version" ]] || die "latest GitHub release does not contain a project manifest asset"
  candidate_version="$discovered_version"

  expected_manifest="$archive_project-$candidate_version-manifest.txt"
  expected_signature="$expected_manifest.sig"
  expected_archive="$archive_project-$candidate_version.tar.gz"

  [[ -n "${asset_urls[$expected_manifest]-}" ]] || die "missing GitHub release asset: $expected_manifest"
  [[ -n "${asset_urls[$expected_signature]-}" ]] || die "missing GitHub release asset: $expected_signature"
  [[ -n "${asset_urls[$expected_archive]-}" ]] || die "missing GitHub release asset: $expected_archive"

  validate_release_asset_url "${asset_urls[$expected_manifest]}" "$expected_manifest"
  validate_release_asset_url "${asset_urls[$expected_signature]}" "$expected_signature"
  validate_release_asset_url "${asset_urls[$expected_archive]}" "$expected_archive"

  candidate_manifest="$expected_manifest"
  candidate_signature="$expected_signature"
  candidate_archive="$expected_archive"
  candidate_manifest_url="${asset_urls[$expected_manifest]}"
  candidate_signature_url="${asset_urls[$expected_signature]}"
  candidate_archive_url="${asset_urls[$expected_archive]}"
}

discover_release() {
  local api_url json

  api_url="https://api.github.com/repos/$project/releases/latest"
  json="$(make_temp_file github-release.json)"
  download_json "$api_url" "$json"
  parse_release_json "$json"
  /bin/rm -f "$json"
}

write_candidate_metadata() {
  local file="$1"

  validate_update_tmp_path "$file" "release metadata file"
  {
    print -r -- "version=$candidate_version"
    print -r -- "manifest=$candidate_manifest"
    print -r -- "manifest_url=$candidate_manifest_url"
    print -r -- "signature=$candidate_signature"
    print -r -- "signature_url=$candidate_signature_url"
    print -r -- "archive=$candidate_archive"
    print -r -- "archive_url=$candidate_archive_url"
  } > "$file"
  /bin/chmod 600 "$file"
}

parse_candidate_metadata() {
  local file="$1"
  local line key value expected
  local index=1
  typeset -a keys=(
    version
    manifest
    manifest_url
    signature
    signature_url
    archive
    archive_url
  )
  typeset -A values

  require_safe_existing_file "$file" "release metadata file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || die "empty release metadata line"
    [[ "$line" == *=* ]] || die "invalid release metadata line: $line"

    expected="${keys[$index]-}"
    [[ -n "$expected" ]] || die "unexpected extra release metadata line: $line"

    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" == "$expected" ]] || die "unexpected release metadata field: $key"
    [[ -z "${values[$key]-}" ]] || die "duplicate release metadata field: $key"
    values[$key]="$value"
    index=$((index + 1))
  done < "$file"

  [[ "$index" -eq $(( ${#keys[@]} + 1 )) ]] || die "release metadata is missing fields"

  validate_version "${values[version]}"
  candidate_version="${values[version]}"
  candidate_manifest="$archive_project-$candidate_version-manifest.txt"
  candidate_signature="$candidate_manifest.sig"
  candidate_archive="$archive_project-$candidate_version.tar.gz"

  [[ "${values[manifest]}" == "$candidate_manifest" ]] || die "unexpected release metadata manifest"
  [[ "${values[signature]}" == "$candidate_signature" ]] || die "unexpected release metadata signature"
  [[ "${values[archive]}" == "$candidate_archive" ]] || die "unexpected release metadata archive"

  validate_release_asset_url "${values[manifest_url]}" "$candidate_manifest"
  validate_release_asset_url "${values[signature_url]}" "$candidate_signature"
  validate_release_asset_url "${values[archive_url]}" "$candidate_archive"

  candidate_manifest_url="${values[manifest_url]}"
  candidate_signature_url="${values[signature_url]}"
  candidate_archive_url="${values[archive_url]}"
}

run_release_verify() {
  local release_dir="$1"
  local output rc

  set +e
  output="$(/bin/zsh "$verify_script" "$release_dir" 2>&1)"
  rc="$?"
  set -e

  if [[ "$rc" != "0" ]]; then
    print -r -- "$output" >&2
    return "$rc"
  fi
}

require_candidate_release_contents() {
  local release_dir="$1"
  local entry name count=0

  require_safe_existing_dir "$release_dir" "release directory"
  require_safe_existing_file "$release_dir/$candidate_manifest" "release manifest"
  require_safe_existing_file "$release_dir/$candidate_signature" "release manifest signature"
  require_safe_existing_file "$release_dir/$candidate_archive" "release archive"

  for entry in "$release_dir"/*(ND); do
    count=$((count + 1))
    name="${entry:t}"
    case "$name" in
      "$candidate_manifest"|"$candidate_signature"|"$candidate_archive") ;;
      *) die "unexpected file in release directory: $entry" ;;
    esac
  done

  [[ "$count" == "3" ]] || die "release directory does not contain exactly the expected release files: $release_dir"
}

verify_candidate_release() {
  local release_dir="$1"

  require_candidate_release_contents "$release_dir"
  run_release_verify "$release_dir"
  require_candidate_release_contents "$release_dir"
}

publish_candidate_release() {
  local source_dir="$1"
  local release_dir="$2"
  local file

  require_candidate_release_contents "$source_dir"
  [[ ! -e "$release_dir" && ! -L "$release_dir" ]] ||
    die "release directory appeared before publish: $release_dir"

  /bin/mkdir "$release_dir"
  published_release_dir="$release_dir"
  release_publish_complete=0
  /bin/chmod 700 "$release_dir"
  require_safe_existing_dir "$release_dir" "release directory"

  for file in "$candidate_manifest" "$candidate_signature" "$candidate_archive"; do
    /bin/mv "$source_dir/$file" "$release_dir/$file"
  done

  /bin/rmdir "$source_dir"
  temp_release_dir=""
  require_candidate_release_contents "$release_dir"
}

prepare_output_dirs() {
  ensure_private_dir "$artifact_dir" "artifacts directory"
  ensure_private_dir "$update_parent" "release update directory"
  ensure_private_dir "$update_tmp_parent" "release update temp directory"
}

fetch_release_assets() {
  local out_dir="$1"

  echo "Downloading $candidate_manifest"
  download_file "$candidate_manifest_url" "$out_dir/$candidate_manifest"
  echo "Downloading $candidate_signature"
  download_file "$candidate_signature_url" "$out_dir/$candidate_signature"
  echo "Downloading $candidate_archive"
  download_file "$candidate_archive_url" "$out_dir/$candidate_archive"
}

run_coordinator() {
  local current_version accepted_version floor_version release_dir metadata_file

  require stat
  require ls
  require mkdir
  require rm
  require chmod
  require mv
  require rmdir
  require mktemp
  require sandbox-exec
  require uuidgen

  require_safe_existing_dir "$root" "project root"
  require_safe_existing_file "$verify_script" "release verifier"
  require_safe_existing_file "$trusted_allowed_signers" "trusted allowed signers file"
  require_safe_existing_file "$trusted_revoked_signers" "trusted revoked signers file"
  require_safe_existing_file "$version_file" "version file"

  load_release_context
  prepare_output_dirs

  current_version="$(read_version_file "$version_file" "version file")"
  accepted_version="$(read_accepted_version)"
  floor_version="$(max_version "$current_version" "$accepted_version")"

  metadata_file="$(make_temp_file release-metadata)"
  echo "Checking latest release"
  run_fetch_sandbox discover "$metadata_file"
  parse_candidate_metadata "$metadata_file"
  /bin/rm -f "$metadata_file"
  echo "Latest release: $candidate_version"

  release_dir="$update_parent/$candidate_version"

  if [[ "$candidate_version" -lt "$floor_version" ]]; then
    die "latest release $candidate_version is older than trusted version $floor_version; refusing downgrade"
  fi

  if [[ "$candidate_version" -eq "$floor_version" ]]; then
    if [[ "$candidate_version" == "$current_version" ]]; then
      echo "Already up to date: trusted version $floor_version is the latest release"
      return
    fi
    if [[ "$candidate_version" == "$accepted_version" ]]; then
      [[ -e "$release_dir" || -L "$release_dir" ]] ||
        die "latest release $candidate_version was previously accepted, but $release_dir is missing"
      echo "Verifying previously fetched release"
      verify_candidate_release "$release_dir"
      echo "Release already fetched and verified: $release_dir"
      return
    fi
    die "latest release $candidate_version matches trusted floor, but no trusted source state matches it"
  fi

  if [[ -e "$release_dir" || -L "$release_dir" ]]; then
    echo "Verifying previously fetched release"
    verify_candidate_release "$release_dir"
    write_accepted_version "$candidate_version"
    echo "Release already fetched and verified: $release_dir"
    return
  fi

  temp_release_dir="$(/usr/bin/mktemp -d "$update_tmp_parent/release.$candidate_version.XXXXXX")"
  /bin/chmod 700 "$temp_release_dir"

  metadata_file="$(make_temp_file release-metadata)"
  write_candidate_metadata "$metadata_file"
  run_fetch_sandbox download "$metadata_file" "$temp_release_dir"
  /bin/rm -f "$metadata_file"

  publish_candidate_release "$temp_release_dir" "$release_dir"

  echo "Verifying release"
  verify_candidate_release "$release_dir"
  release_publish_complete=1
  write_accepted_version "$candidate_version"

  echo "Release ready: $release_dir"
}

verify_internal_sandbox_invocation() {
  local expected_mode="$1"
  local expected_token

  [[ "${OBSIDIAN_FETCH_INTERNAL:-}" == "$expected_mode" ]] ||
    die "invalid internal release fetch environment"
  [[ -n "${OBSIDIAN_FETCH_TOKEN:-}" ]] || die "missing internal release fetch token"
  [[ -n "${OBSIDIAN_FETCH_TOKEN_FILE:-}" ]] || die "missing internal release fetch token file"
  [[ -f "$OBSIDIAN_FETCH_TOKEN_FILE" ]] || die "missing internal release fetch token file"

  expected_token="$(< "$OBSIDIAN_FETCH_TOKEN_FILE")"
  [[ "$expected_token" == "$OBSIDIAN_FETCH_TOKEN" ]] ||
    die "invalid internal release fetch token"
}

require_internal_sandbox() {
  local probe="/private/tmp/obsidian-release-fetch-sandbox-probe.$$.$RANDOM"

  [[ ! -e "$probe" && ! -L "$probe" ]] ||
    die "sandbox probe path already exists: $probe"

  if ( print -r -- "probe" > "$probe" ) 2>/dev/null; then
    /bin/rm -f -- "$probe"
    die "internal release fetch must run under sandbox-exec"
  fi
}

run_internal_sandboxed_discover() {
  local metadata_file="$1"

  preserve_release_metadata=1
  verify_internal_sandbox_invocation discover
  require_internal_sandbox
  validate_update_tmp_path "$metadata_file" "release metadata file"

  load_release_context
  typeset -gA pins
  load_pins "$pins_file"
  require_github_tls_pin_support

  discover_release
  write_candidate_metadata "$metadata_file"
}

run_internal_sandboxed_download() {
  local metadata_file="$1"
  local release_dir="$2"

  preserve_release_metadata=1
  verify_internal_sandbox_invocation download
  require_internal_sandbox
  validate_update_tmp_path "$metadata_file" "release metadata file"
  validate_update_tmp_path "$release_dir" "temporary release directory"
  require_safe_existing_dir "$release_dir" "temporary release directory"

  load_release_context
  typeset -gA pins
  load_pins "$pins_file"
  require_github_tls_pin_support

  parse_candidate_metadata "$metadata_file"
  fetch_release_assets "$release_dir"
}

run_fetch_sandbox() {
  local mode="$1"
  shift
  local profile sandbox_home token token_file token_dir rc
  typeset -a internal_args

  require sandbox-exec
  require uuidgen

  require_safe_existing_dir "$root" "project root"
  require_safe_existing_file "$pins_file" "pins file"

  profile="$root/sandbox/release-fetch.sb"
  require_safe_existing_file "$profile" "release fetch sandbox profile"

  ensure_private_dir "$update_tmp_parent/home" "release fetch sandbox home"

  sandbox_home="$update_tmp_parent/home/fetch"
  ensure_private_dir "$sandbox_home" "release fetch sandbox phase home"

  token_dir="$(/usr/bin/mktemp -d "$update_tmp_parent/tokens.XXXXXX")"
  /bin/chmod 700 "$token_dir"
  token="fetch.$mode.$$.$(/usr/bin/uuidgen)"
  token_file="$token_dir/fetch.token"
  print -r -- "$token" > "$token_file"
  /bin/chmod 600 "$token_file"

  case "$mode" in
    discover)
      [[ "$#" == "1" ]] || die "internal discover requires metadata path"
      internal_args=(--internal-discover "$1")
      ;;
    download)
      [[ "$#" == "2" ]] || die "internal download requires metadata path and release directory"
      internal_args=(--internal-download "$1" "$2")
      ;;
    *)
      die "invalid fetch sandbox mode: $mode"
      ;;
  esac

  set +e
  /usr/bin/env -i \
    HOME="$sandbox_home" \
    TMPDIR="$update_tmp_parent" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LC_ALL=C \
    OBSIDIAN_FETCH_INTERNAL="$mode" \
    OBSIDIAN_FETCH_TOKEN="$token" \
    OBSIDIAN_FETCH_TOKEN_FILE="$token_file" \
    /usr/bin/sandbox-exec \
      -f "$profile" \
      -D FETCH_SCRIPT="$script_path" \
      -D PINS="$pins_file" \
      -D RELEASE_CONFIG_LOADER="$release_config_loader" \
      -D RELEASE_CONF="$release_conf" \
      -D UPDATE_TMP="$update_tmp_parent" \
      -D HOME="$sandbox_home" \
      /bin/zsh "$script_path" "${internal_args[@]}"
  rc="$?"
  set -e

  /bin/rm -rf -- "$token_dir"
  return "$rc"
}

case "$#" in
  0)
    trap cleanup_on_exit EXIT
    acquire_fetch_lock
    run_coordinator
    ;;
  2)
    [[ "$1" == "--internal-discover" ]] || { usage; exit 1; }
    trap cleanup_on_exit EXIT
    run_internal_sandboxed_discover "$2"
    ;;
  3)
    [[ "$1" == "--internal-download" ]] || { usage; exit 1; }
    trap cleanup_on_exit EXIT
    run_internal_sandboxed_download "$2" "$3"
    ;;
  *)
    usage
    exit 1
    ;;
esac
