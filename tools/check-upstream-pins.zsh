#!/bin/zsh
set -euo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=C

script_path="${0:A}"
root="${script_path:h:h}"
artifact_dir="$root/artifacts"
tmp_parent="$artifact_dir/upstream-pin-check-tmp"
pins_file="$root/pins.conf"
floor_pins_file=""
tmp_dir=""
sandbox_token_dir=""
internal_sandbox=0
write_pins=0
summary_file=""
manual_review_required=0
release_age_hold=0
pins_changed=0
pins_written=0
local_write_warning="pins.conf was updated locally. This is not a trusted release. Build and test before relying on it."
next_obsidian_version=""
next_obsidian_sha256=""
next_electron_version=""
next_electron_zip_sha256=""
next_electron_shasums_sha256=""

typeset -gA pins
typeset -gA floor_pins
typeset -ga required_pins=(
  obsidian_version
  obsidian_sha256
  obsidian_bundle_id
  obsidian_team_id
  obsidian_certificate_common_name
  electron_version
  electron_zip_sha256
  electron_shasums_sha256
  github_tls_intermediate_sha256
  github_assets_tls_intermediate_sha256
)
typeset -ga change_lines=()
typeset -ga warning_lines=()
typeset -ga tls_lines=()
typeset -ga hold_lines=()
min_release_age_days="${UPSTREAM_PIN_MIN_RELEASE_AGE_DAYS:-4}"
release_scan_count="${UPSTREAM_PIN_RELEASE_SCAN_COUNT:-10}"

die() {
  print -r -- "error: $*" >&2
  exit 1
}

warn() {
  warning_lines+=("- $*")
  print -r -- "warning: $*" >&2
}

info() {
  print -r -- "$*" >&2
}

usage() {
  cat >&2 <<EOF
usage: tools/${script_path:t} [--write] [--summary PATH] [--floor-pins PATH] [--min-release-age-days DAYS] [--release-scan-count COUNT]

Checks current upstream Obsidian, Electron, and GitHub TLS pin candidates.
By default this reports only. With --write, pins.conf is updated only for
strictly newer upstream versions whose hashes and current TLS pins verify.
When --floor-pins is provided, candidate updates must not downgrade versions
from that existing advisory pins file.
By default, releases must be at least 4 days old before they are eligible.
The checker scans the 10 most recent releases by default.
EOF
}

cleanup_on_exit() {
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    /bin/rm -rf -- "$tmp_dir"
  fi
  if [[ -n "$sandbox_token_dir" && -d "$sandbox_token_dir" ]]; then
    /bin/rm -rf -- "$sandbox_token_dir"
  fi
  /bin/rmdir "$tmp_parent" "$artifact_dir" 2>/dev/null || true
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

prepare_tmp() {
  require_safe_existing_dir "$root" "project root"
  if [[ -e "$artifact_dir" || -L "$artifact_dir" ]]; then
    require_safe_existing_dir "$artifact_dir" "artifacts directory"
  else
    /bin/mkdir "$artifact_dir"
  fi
  /bin/chmod 700 "$artifact_dir"
  ensure_private_dir "$tmp_parent" "upstream pin check temp directory"
  tmp_dir="$(/usr/bin/mktemp -d "$tmp_parent/check.XXXXXX")"
  /bin/chmod 700 "$tmp_dir"
}

prepare_sandbox_parent_dirs() {
  require_safe_existing_dir "$root" "project root"
  if [[ -e "$artifact_dir" || -L "$artifact_dir" ]]; then
    require_safe_existing_dir "$artifact_dir" "artifacts directory"
  else
    /bin/mkdir "$artifact_dir"
  fi
  /bin/chmod 700 "$artifact_dir"
  ensure_private_dir "$tmp_parent" "upstream pin check temp directory"
}

make_temp_file() {
  local label="$1"

  /usr/bin/mktemp "$tmp_dir/$label.XXXXXX"
}

make_temp_dir() {
  local label="$1"

  /usr/bin/mktemp -d "$tmp_dir/$label.XXXXXX"
}

validate_version() {
  [[ "$1" =~ '^[0-9]+([.][0-9]+)*$' ]] || die "invalid version: $1"
}

validate_sha256() {
  [[ "$1" =~ '^[0-9a-f]{64}$' ]] || die "invalid SHA-256 value: $1"
}

validate_nonnegative_integer() {
  [[ "$1" =~ '^[0-9]+$' ]] || die "invalid non-negative integer: $1"
}

validate_release_scan_count() {
  [[ "$1" =~ '^[1-9][0-9]*$' ]] || die "invalid release scan count: $1"
  (( "$1" <= 100 )) || die "release scan count must be at most 100"
}

validate_utc_timestamp() {
  [[ "$1" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] ||
    die "invalid UTC timestamp: $1"
}

validate_pin_list() {
  [[ "$1" =~ '^[0-9a-f]{64}(,[0-9a-f]{64})*$' ]] || die "invalid TLS pin list"
}

version_cmp() {
  local left="$1"
  local right="$2"
  local i max l r
  local -a left_parts right_parts

  validate_version "$left"
  validate_version "$right"
  left_parts=("${(@s:.:)left}")
  right_parts=("${(@s:.:)right}")
  max="${#left_parts[@]}"
  (( "${#right_parts[@]}" > max )) && max="${#right_parts[@]}"

  for (( i = 1; i <= max; i++ )); do
    l="${left_parts[$i]:-0}"
    r="${right_parts[$i]:-0}"
    if (( l > r )); then
      print -r -- 1
      return 0
    fi
    if (( l < r )); then
      print -r -- -1
      return 0
    fi
  done

  print -r -- 0
}

version_gt() {
  [[ "$(version_cmp "$1" "$2")" == "1" ]]
}

sha256_file() {
  local file="$1"
  local line

  line="$(/usr/bin/shasum -a 256 "$file")"
  print -r -- "${line%% *}"
}

timestamp_epoch() {
  local timestamp="$1"

  validate_utc_timestamp "$timestamp"
  /bin/date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s"
}

release_old_enough() {
  local component="$1"
  local version="$2"
  local published_at="$3"
  local published_epoch now_epoch min_age_seconds age_seconds remaining_seconds remaining_days

  validate_nonnegative_integer "$min_release_age_days"
  (( min_release_age_days == 0 )) && return 0

  published_epoch="$(timestamp_epoch "$published_at")"
  now_epoch="$(/bin/date -u "+%s")"
  min_age_seconds=$(( min_release_age_days * 86400 ))
  age_seconds=$(( now_epoch - published_epoch ))

  if (( age_seconds < 0 )); then
    release_age_hold=1
    hold_lines+=("- $component $version was published in the future according to release metadata: $published_at")
    return 1
  fi

  if (( age_seconds < min_age_seconds )); then
    release_age_hold=1
    remaining_seconds=$(( min_age_seconds - age_seconds ))
    remaining_days=$(( (remaining_seconds + 86399) / 86400 ))
    hold_lines+=("- $component $version was published at $published_at and is newer than the ${min_release_age_days}-day minimum age; retry in about $remaining_days day(s)")
    return 1
  fi

  return 0
}

load_pins() {
  local file="$1"
  local line key value
  typeset -A seen

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

  validate_version "${pins[obsidian_version]}"
  validate_version "${pins[electron_version]}"
  validate_sha256 "${pins[obsidian_sha256]}"
  validate_sha256 "${pins[electron_zip_sha256]}"
  validate_sha256 "${pins[electron_shasums_sha256]}"
  validate_pin_list "${pins[github_tls_intermediate_sha256]}"
  validate_pin_list "${pins[github_assets_tls_intermediate_sha256]}"
  [[ "${pins[obsidian_bundle_id]}" =~ '^[A-Za-z0-9.-]+$' ]] || die "invalid obsidian_bundle_id pin"
  [[ "${pins[obsidian_team_id]}" =~ '^[A-Z0-9]{10}$' ]] || die "invalid obsidian_team_id pin"
  [[ "${pins[obsidian_certificate_common_name]}" =~ '^[A-Za-z0-9 .,_()&:+/-]+$' ]] || die "invalid obsidian_certificate_common_name pin"
}

load_floor_pins() {
  typeset -A saved_pins

  [[ -n "$floor_pins_file" ]] || return 0
  saved_pins=("${(@kv)pins}")
  pins=()
  load_pins "$floor_pins_file"
  floor_pins=("${(@kv)pins}")
  pins=("${(@kv)saved_pins}")
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

cert_subject() {
  local cert="$1"

  /usr/bin/openssl x509 -in "$cert" -noout -subject |
    /usr/bin/awk '{ sub(/^subject=[[:space:]]*/, ""); print }'
}

verify_github_tls_pins() {
  local tls_info="$1"
  local effective_url host expected cert_dir cert count fingerprint subject
  local matched=0
  local matched_fingerprint=""
  local matched_subject=""
  local observed=""

  effective_url="$(/usr/bin/awk '/^URL_EFFECTIVE=/ { sub(/^URL_EFFECTIVE=/, ""); print; exit }' "$tls_info")"
  [[ -n "$effective_url" ]] || die "missing curl effective URL for TLS pin check"

  host="$(url_host "$effective_url")" || die "invalid HTTPS URL for TLS pin check: $effective_url"
  expected="$(github_tls_pins_for_host "$host")" || die "unexpected GitHub download host: $host"

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
    if cert_is_ca "$cert"; then
      count=$((count + 1))
      fingerprint="$(cert_sha256_fingerprint "$cert")"
      subject="$(cert_subject "$cert")"
      observed+="${observed:+; }$fingerprint ($subject)"
      if sha256_list_contains "$expected" "$fingerprint"; then
        matched=1
        matched_fingerprint="$fingerprint"
        matched_subject="$subject"
      fi
    fi
  done

  /bin/rm -rf "$cert_dir"

  [[ "$count" -gt 0 ]] || die "missing certificate chain for TLS pin check: $host"

  if [[ "$matched" == "1" ]]; then
    tls_lines+=("- $host: matched $matched_fingerprint ($matched_subject)")
    return 0
  fi

  tls_lines+=("- $host: mismatch; observed $observed")
  die "GitHub TLS intermediate pin mismatch for $host; verify independently before changing TLS pins"
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
}

download_json() {
  local url="$1"
  local out="$2"
  local tmp tls_info
  local -a auth_headers=()

  tmp="$(make_temp_file "${out:t}.download")"
  tls_info="$(make_temp_file "${out:t}.tls")"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_headers=(-H "Authorization: Bearer $GITHUB_TOKEN")
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
    --max-time 60 \
    --max-redirs 3 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${auth_headers[@]}" \
    --output "$tmp" \
    --write-out 'URL_EFFECTIVE=%{url_effective}
CERTS_BEGIN
%{certs}' \
    "$url" > "$tls_info"; then
    /bin/rm -f "$tmp" "$tls_info"
    return 1
  fi

  verify_github_tls_pins "$tls_info"
  /bin/chmod 600 "$tmp"
  /bin/mv -f "$tmp" "$out"
  /bin/rm -f "$tls_info"
}

download_file() {
  local url="$1"
  local out="$2"
  local tmp tls_info

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

  verify_github_tls_pins "$tls_info"
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

json_optional_string() {
  local file="$1"
  local key="$2"

  /usr/bin/plutil -extract "$key" raw -expect string -o - "$file" 2>/dev/null || true
}

asset_digest_sha256() {
  local digest="$1"
  local label="$2"
  local sha

  [[ -n "$digest" ]] || return 0
  [[ "$digest" == sha256:* ]] || die "unexpected digest for $label: $digest"
  sha="${digest#sha256:}"
  validate_sha256 "$sha"
  print -r -- "$sha"
}

find_release_asset_optional() {
  local json="$1"
  local expected="$2"
  local asset_key="${3:-assets}"
  local count index name url digest

  count="$(json_raw "$json" "$asset_key" array)"
  [[ "$count" =~ '^[0-9]+$' && "$count" -gt 0 ]] || return 1

  for (( index = 0; index < count; index++ )); do
    name="$(json_raw "$json" "$asset_key.$index.name" string)"
    if [[ "$name" == "$expected" ]]; then
      url="$(json_raw "$json" "$asset_key.$index.browser_download_url" string)"
      digest="$(json_optional_string "$json" "$asset_key.$index.digest")"
      print -r -- "$url"$'\t'"$digest"
      return 0
    fi
  done

  return 1
}

find_release_asset() {
  local json="$1"
  local expected="$2"
  local asset_key="${3:-assets}"

  find_release_asset_optional "$json" "$expected" "$asset_key" ||
  die "missing release asset: $expected"
}

validate_asset_url() {
  local repo="$1"
  local version="$2"
  local name="$3"
  local url="$4"
  local expected

  expected="https://github.com/$repo/releases/download/v$version/$name"
  [[ "$url" == "$expected" ]] || die "unexpected asset URL for $name: $url"
}

latest_release_json() {
  local repo="$1"
  local out="$2"

  download_json "https://api.github.com/repos/$repo/releases/latest" "$out" ||
    die "failed to fetch latest release metadata for $repo"
}

list_releases_json() {
  local repo="$1"
  local out="$2"

  download_json "https://api.github.com/repos/$repo/releases?per_page=$release_scan_count" "$out" ||
    die "failed to fetch release metadata for $repo"
}

read_latest_tag_version() {
  local json="$1"
  local tag

  tag="$(json_raw "$json" tag_name string)"
  [[ "$tag" =~ '^v[0-9]+([.][0-9]+)*$' ]] || die "unexpected release tag: $tag"
  print -r -- "${tag#v}"
}

release_index_exists() {
  local json="$1"
  local index="$2"

  /usr/bin/plutil -extract "$index.tag_name" raw -expect string -o - "$json" >/dev/null 2>&1
}

release_index_version() {
  local json="$1"
  local index="$2"
  local tag

  tag="$(json_raw "$json" "$index.tag_name" string)"
  [[ "$tag" =~ '^v[0-9]+([.][0-9]+)*$' ]] || return 1
  print -r -- "${tag#v}"
}

release_index_is_stable() {
  local json="$1"
  local index="$2"
  local draft prerelease

  draft="$(json_raw "$json" "$index.draft" bool)"
  prerelease="$(json_raw "$json" "$index.prerelease" bool)"
  [[ "$draft" == "false" && "$prerelease" == "false" ]]
}

parse_electron_zip_sha256() {
  local shasums="$1"
  local version="$2"
  local name="electron-v$version-mas-arm64.zip"
  local sha

  sha="$(/usr/bin/awk -v name="$name" '$2 == ("*" name) { print $1; found = 1 } END { exit found ? 0 : 1 }' "$shasums")" ||
    die "missing $name in Electron SHASUMS256.txt"
  validate_sha256 "$sha"
  print -r -- "$sha"
}

set_candidate() {
  local key="$1"
  local current="$2"
  local candidate="$3"

  if [[ "$current" != "$candidate" ]]; then
    pins_changed=1
    change_lines+=("- $key: $current -> $candidate")
  fi
}

evaluate_versioned_pin_change() {
  local component="$1"
  local current_version="$2"
  local upstream_version="$3"
  local current_hash="$4"
  local upstream_hash="$5"
  local current_aux_hash="${6:-}"
  local upstream_aux_hash="${7:-}"

  if [[ "$upstream_version" == "$current_version" ]]; then
    if [[ "$upstream_hash" != "$current_hash" || ( -n "$current_aux_hash" && "$upstream_aux_hash" != "$current_aux_hash" ) ]]; then
      manual_review_required=1
      warn "$component latest version is unchanged, but one or more hashes differ"
    fi
    return
  fi

  if version_gt "$upstream_version" "$current_version"; then
    return
  fi

  warn "$component latest version $upstream_version is not newer than pinned version $current_version"
}

obsidian_sha256_for_asset() {
  local version="$1"
  local url="$2"
  local digest="$3"
  local download_required="$4"
  local asset_name="Obsidian-$version.dmg"
  local digest_sha dmg computed_sha

  digest_sha="$(asset_digest_sha256 "$digest" "$asset_name")"
  if [[ "$download_required" != "1" && -n "$digest_sha" ]]; then
    typeset -g obsidian_asset_sha256_result="$digest_sha"
    return 0
  fi

  dmg="$(make_temp_file "$asset_name")"
  download_file "$url" "$dmg" || die "failed to download $asset_name"
  computed_sha="$(sha256_file "$dmg")"
  validate_sha256 "$computed_sha"
  if [[ -n "$digest_sha" && "$computed_sha" != "$digest_sha" ]]; then
    die "Obsidian asset digest does not match downloaded DMG"
  fi

  typeset -g obsidian_asset_sha256_result="$computed_sha"
}

electron_hashes_for_release() {
  local version="$1"
  local zip_digest="$2"
  local shasums_url="$3"
  local shasums_digest="$4"
  local zip_name="electron-v$version-mas-arm64.zip"
  local zip_digest_sha shasums_digest_sha shasums computed_shasums_sha zip_sha

  zip_digest_sha="$(asset_digest_sha256 "$zip_digest" "$zip_name")"
  shasums_digest_sha="$(asset_digest_sha256 "$shasums_digest" "SHASUMS256.txt")"

  shasums="$(make_temp_file "electron-$version-SHASUMS256.txt")"
  download_file "$shasums_url" "$shasums" || die "failed to download Electron SHASUMS256.txt for $version"
  computed_shasums_sha="$(sha256_file "$shasums")"
  validate_sha256 "$computed_shasums_sha"
  if [[ -n "$shasums_digest_sha" && "$computed_shasums_sha" != "$shasums_digest_sha" ]]; then
    die "Electron SHASUMS256.txt asset digest does not match downloaded file for $version"
  fi

  zip_sha="$(parse_electron_zip_sha256 "$shasums" "$version")"
  if [[ -n "$zip_digest_sha" && "$zip_sha" != "$zip_digest_sha" ]]; then
    die "Electron ZIP asset digest does not match SHASUMS256.txt for $version"
  fi

  typeset -g electron_hash_zip_sha256_result="$zip_sha"
  typeset -g electron_hash_shasums_sha256_result="$computed_shasums_sha"
}

enforce_obsidian_floor() {
  local current_version="${pins[obsidian_version]}"
  local floor_version="${floor_pins[obsidian_version]-}"
  local current_floor_cmp next_floor_cmp

  [[ -n "$floor_version" ]] || return 0

  current_floor_cmp="$(version_cmp "$floor_version" "$current_version")"
  if [[ "$current_floor_cmp" == "-1" ]]; then
    warn "existing advisory Obsidian floor $floor_version is older than trusted pin $current_version; ignoring it"
    return 0
  fi

  if [[ "$current_floor_cmp" == "0" ]]; then
    if [[ "${floor_pins[obsidian_sha256]}" != "${pins[obsidian_sha256]}" ]]; then
      manual_review_required=1
      warn "existing advisory Obsidian floor has same version as trusted pins but a different hash"
    fi
    return 0
  fi

  next_floor_cmp="$(version_cmp "$next_obsidian_version" "$floor_version")"
  if [[ "$next_floor_cmp" == "-1" ]]; then
    manual_review_required=1
    warn "existing advisory Obsidian floor $floor_version is newer than selected candidate $next_obsidian_version; refusing to replace or close it"
    return 0
  fi

  if [[ "$next_floor_cmp" == "0" && "$next_obsidian_sha256" != "${floor_pins[obsidian_sha256]}" ]]; then
    manual_review_required=1
    warn "existing advisory Obsidian floor matches selected candidate version but has a different hash"
  fi
}

enforce_electron_floor() {
  local current_version="${pins[electron_version]}"
  local floor_version="${floor_pins[electron_version]-}"
  local current_floor_cmp next_floor_cmp

  [[ -n "$floor_version" ]] || return 0

  current_floor_cmp="$(version_cmp "$floor_version" "$current_version")"
  if [[ "$current_floor_cmp" == "-1" ]]; then
    warn "existing advisory Electron floor $floor_version is older than trusted pin $current_version; ignoring it"
    return 0
  fi

  if [[ "$current_floor_cmp" == "0" ]]; then
    if [[ "${floor_pins[electron_zip_sha256]}" != "${pins[electron_zip_sha256]}" ||
          "${floor_pins[electron_shasums_sha256]}" != "${pins[electron_shasums_sha256]}" ]]; then
      manual_review_required=1
      warn "existing advisory Electron floor has same version as trusted pins but different hashes"
    fi
    return 0
  fi

  next_floor_cmp="$(version_cmp "$next_electron_version" "$floor_version")"
  if [[ "$next_floor_cmp" == "-1" ]]; then
    manual_review_required=1
    warn "existing advisory Electron floor $floor_version is newer than selected candidate $next_electron_version; refusing to replace or close it"
    return 0
  fi

  if [[ "$next_floor_cmp" == "0" &&
        ( "$next_electron_zip_sha256" != "${floor_pins[electron_zip_sha256]}" ||
          "$next_electron_shasums_sha256" != "${floor_pins[electron_shasums_sha256]}" ) ]]; then
    manual_review_required=1
    warn "existing advisory Electron floor matches selected candidate version but has different hashes"
  fi
}

enforce_floor_pins() {
  (( ${#floor_pins[@]} > 0 )) || return 0

  enforce_obsidian_floor
  enforce_electron_floor
}

check_obsidian() {
  local json index version published_at asset_name asset_info asset_url asset_digest
  local latest_asset_digest=""
  local latest_index="" candidate_index=""
  local candidate_version="" candidate_published_at="" candidate_asset_url="" candidate_asset_digest=""
  local candidate_sha256

  info "Checking Obsidian releases"
  json="$(make_temp_file obsidian-releases.json)"
  list_releases_json "obsidianmd/obsidian-releases" "$json"

  index=0
  while release_index_exists "$json" "$index"; do
    if ! release_index_is_stable "$json" "$index"; then
      index=$((index + 1))
      continue
    fi
    if ! version="$(release_index_version "$json" "$index")"; then
      index=$((index + 1))
      continue
    fi

    published_at="$(json_raw "$json" "$index.published_at" string)"
    validate_utc_timestamp "$published_at"

    if [[ -z "${obsidian_latest_version:-}" ]]; then
      latest_index="$index"
      obsidian_latest_version="$version"
      obsidian_published_at="$published_at"
    fi

    if version_gt "$version" "${pins[obsidian_version]}" &&
        release_old_enough "Obsidian" "$version" "$published_at"; then
      candidate_index="$index"
      candidate_version="$version"
      candidate_published_at="$published_at"
      break
    fi

    index=$((index + 1))
  done

  [[ -n "${obsidian_latest_version:-}" ]] || die "no usable Obsidian release found"
  info "Verifying Obsidian metadata and hashes"
  asset_name="Obsidian-$obsidian_latest_version.dmg"
  asset_info="$(find_release_asset "$json" "$asset_name" "$latest_index.assets")"
  obsidian_asset_url="${asset_info%%$'\t'*}"
  latest_asset_digest="${asset_info#*$'\t'}"
  validate_asset_url "obsidianmd/obsidian-releases" "$obsidian_latest_version" "$asset_name" "$obsidian_asset_url"
  obsidian_sha256_for_asset "$obsidian_latest_version" "$obsidian_asset_url" "$latest_asset_digest" 0
  obsidian_latest_sha256="$obsidian_asset_sha256_result"

  evaluate_versioned_pin_change \
    "Obsidian" \
    "${pins[obsidian_version]}" \
    "$obsidian_latest_version" \
    "${pins[obsidian_sha256]}" \
    "$obsidian_latest_sha256"

  if [[ "$manual_review_required" == "0" && -n "$candidate_version" ]]; then
    if [[ "$candidate_version" == "$obsidian_latest_version" ]]; then
      candidate_sha256="$obsidian_latest_sha256"
    else
      asset_name="Obsidian-$candidate_version.dmg"
      asset_info="$(find_release_asset "$json" "$asset_name" "$candidate_index.assets")"
      candidate_asset_url="${asset_info%%$'\t'*}"
      candidate_asset_digest="${asset_info#*$'\t'}"
      validate_asset_url "obsidianmd/obsidian-releases" "$candidate_version" "$asset_name" "$candidate_asset_url"
      obsidian_sha256_for_asset "$candidate_version" "$candidate_asset_url" "$candidate_asset_digest" 1
      candidate_sha256="$obsidian_asset_sha256_result"
    fi
    next_obsidian_version="$candidate_version"
    next_obsidian_sha256="$candidate_sha256"
    set_candidate obsidian_version "${pins[obsidian_version]}" "$candidate_version"
    set_candidate obsidian_sha256 "${pins[obsidian_sha256]}" "$candidate_sha256"
  fi
}

check_electron() {
  local json index version published_at zip_name shasums_name zip_info shasums_info
  local zip_url zip_digest shasums_url shasums_digest
  local latest_zip_digest="" latest_shasums_digest=""
  local latest_index="" candidate_index=""
  local candidate_version="" candidate_published_at="" candidate_zip_url="" candidate_zip_digest=""
  local candidate_shasums_url="" candidate_shasums_digest=""

  info "Checking Electron releases"
  json="$(make_temp_file electron-releases.json)"
  list_releases_json "electron/electron" "$json"

  index=0
  while release_index_exists "$json" "$index"; do
    if ! release_index_is_stable "$json" "$index"; then
      index=$((index + 1))
      continue
    fi
    if ! version="$(release_index_version "$json" "$index")"; then
      index=$((index + 1))
      continue
    fi

    published_at="$(json_raw "$json" "$index.published_at" string)"
    validate_utc_timestamp "$published_at"

    if [[ -z "${electron_latest_version:-}" ]]; then
      latest_index="$index"
      electron_latest_version="$version"
      electron_published_at="$published_at"
    fi

    if version_gt "$version" "${pins[electron_version]}" &&
        release_old_enough "Electron" "$version" "$published_at"; then
      candidate_index="$index"
      candidate_version="$version"
      candidate_published_at="$published_at"
      break
    fi

    index=$((index + 1))
  done

  [[ -n "${electron_latest_version:-}" ]] || die "no usable Electron release found"
  info "Verifying Electron checksums"
  zip_name="electron-v$electron_latest_version-mas-arm64.zip"
  shasums_name="SHASUMS256.txt"
  zip_info="$(find_release_asset "$json" "$zip_name" "$latest_index.assets")"
  shasums_info="$(find_release_asset "$json" "$shasums_name" "$latest_index.assets")"
  electron_zip_asset_url="${zip_info%%$'\t'*}"
  latest_zip_digest="${zip_info#*$'\t'}"
  electron_shasums_url="${shasums_info%%$'\t'*}"
  latest_shasums_digest="${shasums_info#*$'\t'}"
  validate_asset_url "electron/electron" "$electron_latest_version" "$zip_name" "$electron_zip_asset_url"
  validate_asset_url "electron/electron" "$electron_latest_version" "$shasums_name" "$electron_shasums_url"
  electron_hashes_for_release "$electron_latest_version" "$latest_zip_digest" "$electron_shasums_url" "$latest_shasums_digest"
  electron_latest_zip_sha256="$electron_hash_zip_sha256_result"
  electron_latest_shasums_sha256="$electron_hash_shasums_sha256_result"

  evaluate_versioned_pin_change \
    "Electron" \
    "${pins[electron_version]}" \
    "$electron_latest_version" \
    "${pins[electron_zip_sha256]}" \
    "$electron_latest_zip_sha256" \
    "${pins[electron_shasums_sha256]}" \
    "$electron_latest_shasums_sha256"

  if [[ "$manual_review_required" == "0" && -n "$candidate_version" ]]; then
    if [[ "$candidate_version" == "$electron_latest_version" ]]; then
      next_electron_zip_sha256="$electron_latest_zip_sha256"
      next_electron_shasums_sha256="$electron_latest_shasums_sha256"
    else
      zip_name="electron-v$candidate_version-mas-arm64.zip"
      shasums_name="SHASUMS256.txt"
      zip_info="$(find_release_asset "$json" "$zip_name" "$candidate_index.assets")"
      shasums_info="$(find_release_asset "$json" "$shasums_name" "$candidate_index.assets")"
      candidate_zip_url="${zip_info%%$'\t'*}"
      candidate_zip_digest="${zip_info#*$'\t'}"
      candidate_shasums_url="${shasums_info%%$'\t'*}"
      candidate_shasums_digest="${shasums_info#*$'\t'}"
      validate_asset_url "electron/electron" "$candidate_version" "$zip_name" "$candidate_zip_url"
      validate_asset_url "electron/electron" "$candidate_version" "$shasums_name" "$candidate_shasums_url"
      electron_hashes_for_release "$candidate_version" "$candidate_zip_digest" "$candidate_shasums_url" "$candidate_shasums_digest"
      next_electron_zip_sha256="$electron_hash_zip_sha256_result"
      next_electron_shasums_sha256="$electron_hash_shasums_sha256_result"
    fi
    next_electron_version="$candidate_version"
    set_candidate electron_version "${pins[electron_version]}" "$candidate_version"
    set_candidate electron_zip_sha256 "${pins[electron_zip_sha256]}" "$next_electron_zip_sha256"
    set_candidate electron_shasums_sha256 "${pins[electron_shasums_sha256]}" "$next_electron_shasums_sha256"
  fi
}

write_pins_file() {
  local tmp

  tmp="$(make_temp_file pins.conf)"
  {
    print -r -- "# Trust pins for build-sandboxed-obsidian.zsh."
    print -r -- "# This file is parsed as data, not sourced as shell code."
    print -r -- ""
    print -r -- "obsidian_version=$next_obsidian_version"
    print -r -- "obsidian_sha256=$next_obsidian_sha256"
    print -r -- "obsidian_bundle_id=${pins[obsidian_bundle_id]}"
    print -r -- "obsidian_team_id=${pins[obsidian_team_id]}"
    print -r -- "obsidian_certificate_common_name=${pins[obsidian_certificate_common_name]}"
    print -r -- ""
    print -r -- "electron_version=$next_electron_version"
    print -r -- "electron_zip_sha256=$next_electron_zip_sha256"
    print -r -- "electron_shasums_sha256=$next_electron_shasums_sha256"
    print -r -- ""
    print -r -- "github_tls_intermediate_sha256=${pins[github_tls_intermediate_sha256]}"
    print -r -- "github_assets_tls_intermediate_sha256=${pins[github_assets_tls_intermediate_sha256]}"
  } > "$tmp"
  /bin/chmod 644 "$tmp"
  /bin/mv -f "$tmp" "$pins_file"
  pins_written=1
  warning_lines+=("- $local_write_warning")
}

write_summary() {
  local out="$1"
  local result_status

  [[ -n "$out" ]] || return 0
  /bin/mkdir -p "${out:h}"

  if [[ "$manual_review_required" == "1" ]]; then
    result_status="manual review required"
  elif [[ "$release_age_hold" == "1" && "$pins_changed" != "1" ]]; then
    result_status="release age hold"
  elif [[ "$pins_changed" == "1" && "$pins_written" == "1" ]]; then
    result_status="pins.conf updated"
  elif [[ "$pins_changed" == "1" ]]; then
    result_status="candidate update available"
  else
    result_status="no pin updates detected"
  fi

  {
    print -r -- "# Upstream Pin Check"
    print -r -- ""
    print -r -- "Status: $result_status"
    print -r -- ""
    print -r -- "This is an advisory result. Treat CI output as a notification and verify locally from a trusted checkout before merging pin updates."
    print -r -- ""
    print -r -- "Release minimum age: $min_release_age_days day(s)"
    print -r -- "Release scan count: $release_scan_count"
    print -r -- ""
    print -r -- "## Current pins"
    print -r -- ""
    print -r -- "- Obsidian: ${pins[obsidian_version]} (${pins[obsidian_sha256]})"
    print -r -- "- Electron: ${pins[electron_version]} (zip ${pins[electron_zip_sha256]}, SHASUMS ${pins[electron_shasums_sha256]})"
    print -r -- ""
    if (( ${#floor_pins[@]} > 0 )); then
      print -r -- "## Existing advisory floor"
      print -r -- ""
      print -r -- "- Obsidian: ${floor_pins[obsidian_version]} (${floor_pins[obsidian_sha256]})"
      print -r -- "- Electron: ${floor_pins[electron_version]} (zip ${floor_pins[electron_zip_sha256]}, SHASUMS ${floor_pins[electron_shasums_sha256]})"
      print -r -- ""
    fi
    print -r -- "## Observed upstream"
    print -r -- ""
    print -r -- "- Obsidian: ${obsidian_latest_version:-unknown} (${obsidian_latest_sha256:-unknown})"
    print -r -- "  - Published: ${obsidian_published_at:-unknown}"
    print -r -- "  - $obsidian_asset_url"
    print -r -- "- Electron: ${electron_latest_version:-unknown}"
    print -r -- "  - Published: ${electron_published_at:-unknown}"
    print -r -- "  - ZIP: ${electron_latest_zip_sha256:-unknown}"
    print -r -- "  - SHASUMS256.txt: ${electron_latest_shasums_sha256:-unknown}"
    print -r -- "  - $electron_zip_asset_url"
    print -r -- "  - $electron_shasums_url"
    print -r -- ""
    print -r -- "## TLS observations"
    print -r -- ""
    if (( ${#tls_lines[@]} > 0 )); then
      print -r -- "${(F)tls_lines}"
    else
      print -r -- "- No TLS observations recorded."
    fi
    print -r -- ""
    print -r -- "## Candidate changes"
    print -r -- ""
    if (( ${#change_lines[@]} > 0 )); then
      print -r -- "${(F)change_lines}"
    else
      print -r -- "- None."
    fi
    if (( ${#hold_lines[@]} > 0 )); then
      print -r -- ""
      print -r -- "## Held releases"
      print -r -- ""
      print -r -- "${(F)hold_lines}"
    fi
    if (( ${#warning_lines[@]} > 0 )); then
      print -r -- ""
      print -r -- "## Warnings"
      print -r -- ""
      print -r -- "${(F)warning_lines}"
    fi
  } > "$out"
  /bin/chmod 644 "$out"
}

print_report() {
  print -r -- "Upstream pin check"
  print -r -- "  Obsidian: ${pins[obsidian_version]} (current) -> ${obsidian_latest_version:-unknown} (latest)"
  print -r -- "  Electron: ${pins[electron_version]} (current) -> ${electron_latest_version:-unknown} (latest)"
  if [[ "$pins_changed" == "1" ]]; then
    print -r -- "  Candidate changes:"
    print -r -- "${(F)change_lines}" | /usr/bin/awk '{ print "    " $0 }'
  else
    print -r -- "  Candidate changes: none"
  fi
  if (( ${#hold_lines[@]} > 0 )); then
    print -r -- "  Held releases:"
    print -r -- "${(F)hold_lines}" | /usr/bin/awk '{ print "    " $0 }'
  fi
  if [[ "$pins_written" == "1" ]]; then
    print -r -- "  Warning:"
    print -r -- "    pins.conf was updated locally."
    print -r -- "    This is not a trusted release."
    print -r -- "    Build and test before relying on it."
  fi
}

parse_args() {
  local arg

  while (( $# > 0 )); do
    arg="$1"
    shift
    case "$arg" in
      --write)
        write_pins=1
        ;;
      --summary)
        (( $# > 0 )) || { usage; exit 1; }
        summary_file="${1:A}"
        shift
        ;;
      --floor-pins)
        (( $# > 0 )) || { usage; exit 1; }
        floor_pins_file="${1:A}"
        shift
        ;;
      --min-release-age-days)
        (( $# > 0 )) || { usage; exit 1; }
        min_release_age_days="$1"
        shift
        ;;
      --release-scan-count)
        (( $# > 0 )) || { usage; exit 1; }
        release_scan_count="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done
}

run_check() {
  require curl
  require plutil
  require shasum
  require awk
  require openssl
  require mktemp
  require stat
  require ls
  require chmod
  require mkdir
  require mv
  require rm
  validate_nonnegative_integer "$min_release_age_days"
  validate_release_scan_count "$release_scan_count"
  info "Upstream pin check settings"
  info "  Minimum release age: $min_release_age_days day(s)"
  info "  Release scan count: $release_scan_count"
  if [[ -n "$floor_pins_file" ]]; then
    info "  Advisory floor: $floor_pins_file"
  fi
  require_github_tls_pin_support

  prepare_tmp
  load_pins "$pins_file"
  load_floor_pins
  next_obsidian_version="${pins[obsidian_version]}"
  next_obsidian_sha256="${pins[obsidian_sha256]}"
  next_electron_version="${pins[electron_version]}"
  next_electron_zip_sha256="${pins[electron_zip_sha256]}"
  next_electron_shasums_sha256="${pins[electron_shasums_sha256]}"
  check_obsidian
  check_electron
  enforce_floor_pins

  if [[ "$manual_review_required" == "1" ]]; then
    write_summary "$summary_file"
    print_report
    die "manual review required; not updating pins.conf"
  fi

  if [[ "$write_pins" == "1" && "$pins_changed" == "1" ]]; then
    write_pins_file
  fi

  write_summary "$summary_file"
  print_report
}

verify_internal_sandbox_invocation() {
  local expected_token

  [[ "${OBSIDIAN_PIN_CHECK_INTERNAL:-}" == "check" ]] ||
    die "invalid internal pin check environment"
  [[ -n "${OBSIDIAN_PIN_CHECK_TOKEN:-}" ]] || die "missing internal pin check token"
  [[ -n "${OBSIDIAN_PIN_CHECK_TOKEN_FILE:-}" ]] || die "missing internal pin check token file"
  [[ -f "$OBSIDIAN_PIN_CHECK_TOKEN_FILE" ]] || die "missing internal pin check token file"

  expected_token="$(< "$OBSIDIAN_PIN_CHECK_TOKEN_FILE")"
  [[ "$expected_token" == "$OBSIDIAN_PIN_CHECK_TOKEN" ]] ||
    die "invalid internal pin check token"
}

require_internal_sandbox() {
  local probe="/private/tmp/obsidian-pin-check-sandbox-probe.$$.$RANDOM"

  [[ ! -e "$probe" && ! -L "$probe" ]] ||
    die "sandbox probe path already exists: $probe"

  if ( print -r -- "probe" > "$probe" ) 2>/dev/null; then
    /bin/rm -f -- "$probe"
    die "internal pin check must run under sandbox-exec"
  fi
}

prepare_summary_for_sandbox() {
  local summary_dir

  [[ -n "$summary_file" ]] || return 0

  summary_dir="${summary_file:h}"
  if [[ -e "$summary_file" || -L "$summary_file" ]]; then
    require_safe_existing_file "$summary_file" "summary file"
  fi

  if [[ -e "$summary_dir" || -L "$summary_dir" ]]; then
    require_safe_existing_dir "$summary_dir" "summary directory"
    return 0
  fi

  case "$summary_dir" in
    "$artifact_dir"|"$artifact_dir"/*)
      /bin/mkdir -p "$summary_dir"
      /bin/chmod 700 "$summary_dir"
      require_safe_existing_dir "$summary_dir" "summary directory"
      ;;
    *)
      die "summary directory does not exist: $summary_dir"
      ;;
  esac
}

run_internal_sandboxed_check() {
  internal_sandbox=1
  verify_internal_sandbox_invocation
  require_internal_sandbox
  parse_args "$@"
  run_check
}

run_sandboxed_check() {
  local profile sandbox_home token token_file summary_dir_param floor_pins_param rc
  local -a original_args

  original_args=("$@")
  parse_args "$@"

  require sandbox-exec
  require uuidgen
  require env
  require_safe_existing_dir "$root" "project root"
  require_safe_existing_file "$pins_file" "pins file"

  profile="$root/sandbox/check-upstream-pins.sb"
  require_safe_existing_file "$profile" "pin check sandbox profile"

  prepare_sandbox_parent_dirs
  prepare_summary_for_sandbox
  if [[ -n "$floor_pins_file" ]]; then
    require_safe_existing_file "$floor_pins_file" "floor pins file"
    floor_pins_param="$floor_pins_file"
  else
    floor_pins_param="/dev/null"
  fi

  if [[ -n "$summary_file" ]]; then
    summary_dir_param="${summary_file:h}"
  else
    summary_file="/dev/null"
    summary_dir_param="/dev/null"
  fi

  sandbox_home="$tmp_parent/home"
  ensure_private_dir "$sandbox_home" "pin check sandbox home"

  sandbox_token_dir="$(/usr/bin/mktemp -d "$tmp_parent/tokens.XXXXXX")"
  /bin/chmod 700 "$sandbox_token_dir"
  token="pin-check.$$.$(/usr/bin/uuidgen)"
  token_file="$sandbox_token_dir/check.token"
  print -r -- "$token" > "$token_file"
  /bin/chmod 600 "$token_file"

  set +e
  /usr/bin/env -i \
    HOME="$sandbox_home" \
    TMPDIR="$tmp_parent" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LC_ALL=C \
    UPSTREAM_PIN_MIN_RELEASE_AGE_DAYS="$min_release_age_days" \
    UPSTREAM_PIN_RELEASE_SCAN_COUNT="$release_scan_count" \
    OBSIDIAN_PIN_CHECK_INTERNAL="check" \
    OBSIDIAN_PIN_CHECK_TOKEN="$token" \
    OBSIDIAN_PIN_CHECK_TOKEN_FILE="$token_file" \
    /usr/bin/sandbox-exec \
      -f "$profile" \
      -D CHECK_SCRIPT="$script_path" \
      -D ROOT="$root" \
      -D PINS="$pins_file" \
      -D FLOOR_PINS="$floor_pins_param" \
      -D CHECK_TMP_PARENT="$tmp_parent" \
      -D SUMMARY_FILE="$summary_file" \
      -D SUMMARY_DIR="$summary_dir_param" \
      -D HOME="$sandbox_home" \
      /bin/zsh "$script_path" --internal-sandbox "${original_args[@]}"
  rc="$?"
  set -e

  return "$rc"
}

trap cleanup_on_exit EXIT
if [[ "${1:-}" == "--internal-sandbox" ]]; then
  shift
  run_internal_sandboxed_check "$@"
else
  run_sandboxed_check "$@"
fi
