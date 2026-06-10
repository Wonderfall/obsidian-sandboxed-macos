#!/bin/zsh
set -euo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=C

script_path="${0:A}"
root="${script_path:h}"
artifact_dir="$root/artifacts"
build_lock_dir="$root/.build-sandboxed-obsidian.lock"
build_lock_acquired=0
phase_token_dir=""

log() {
  print -r -- "$*"
}

log_blank() {
  print -r -- ""
}

log_detail() {
  print -r -- "  - $*"
}

log_kv() {
  local key="$1"
  shift

  print -r -- "  $key: $*"
}

log_done() {
  print -r -- "  [ok] $*"
}

display_path() {
  local path="$1"

  case "$path" in
    "$root"/*) print -r -- "${path#$root/}" ;;
    *) print -r -- "$path" ;;
  esac
}

print_indented() {
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    print -r -- "    $line"
  done
}

print_indented_err() {
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    print -r -- "    $line" >&2
  done
}

run_or_report() {
  local label="$1"
  shift
  local output rc

  set +e
  output="$("$@" 2>&1)"
  rc="$?"
  set -e
  if [[ "$rc" == "0" ]]; then
    return 0
  fi

  print -r -- "error: $label failed (exit $rc)" >&2
  if [[ -n "$output" ]]; then
    print -r -- "$output" | print_indented_err
  fi
  return "$rc"
}

die() {
  print -r -- "error: $*" >&2
  if [[ -n "${OBSIDIAN_INTERNAL_PHASE:-}" ]]; then
    print -r -- "  phase: $OBSIDIAN_INTERNAL_PHASE" >&2
  fi
  exit 1
}

warn() {
  print -r -- "warning: $*" >&2
}

usage() {
  print -r -- "usage: ${script_path:t} [clean|--self-test]" >&2
}

cleanup_on_exit() {
  local pid

  if [[ -n "$phase_token_dir" && -d "$phase_token_dir" ]]; then
    /bin/rm -rf -- "$phase_token_dir"
  fi

  if [[ "$build_lock_acquired" == "1" && -d "$build_lock_dir" ]]; then
    pid="$(< "$build_lock_dir/pid" 2>/dev/null || true)"
    if [[ "$pid" == "$$" ]]; then
      /bin/rm -rf -- "$build_lock_dir"
    fi
  fi
}

acquire_build_lock() {
  local pid_file="$build_lock_dir/pid"

  if ! /bin/mkdir "$build_lock_dir" 2>/dev/null; then
    die "another build appears to be running; lock exists: $build_lock_dir"
  fi

  build_lock_acquired=1
  /bin/chmod 700 "$build_lock_dir"
  print -r -- "$$" > "$pid_file"
  /bin/chmod 600 "$pid_file"
}

command="build"
requested_phase=""
case "$#" in
  0) ;;
  1)
    case "$1" in
      clean)
        command="clean"
        ;;
      --self-test)
        command="self-test"
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  2)
    [[ "$1" == "--internal-phase" ]] || { usage; exit 1; }
    requested_phase="$2"
    ;;
  *)
    usage
    exit 1
    ;;
esac

valid_phase() {
  case "$1" in
    fetch|unpack-verify|stage|sign|verify) return 0 ;;
    *) return 1 ;;
  esac
}

phase_label() {
  case "$1" in
    fetch) print -r -- "Fetch pinned downloads" ;;
    unpack-verify) print -r -- "Unpack and verify upstream apps" ;;
    stage) print -r -- "Stage sandboxed app bundle" ;;
    sign) print -r -- "Sign staged app" ;;
    verify) print -r -- "Verify final app" ;;
    *) print -r -- "$1" ;;
  esac
}

signing_label() {
  if [[ "$sign_identity" == "-" ]]; then
    print -r -- "ad hoc"
  else
    print -r -- "$sign_identity"
  fi
}

timestamp_label() {
  if [[ "$timestamp_enabled" == "1" ]]; then
    print -r -- "enabled"
  else
    print -r -- "disabled"
  fi
}

log_build_plan() {
  log "Building sandboxed Obsidian"
  log_kv "Obsidian" "$obsidian_version ($obsidian_asset)"
  log_kv "Electron" "$electron_version ($electron_asset)"
  log_kv "Output" "$(display_path "$stage_app")"
  log_kv "Bundle id" "$output_bundle_id"
  log_kv "Signing" "$(signing_label), timestamp $(timestamp_label)"
}

clean_path() {
  local path="$1"

  case "$path" in
    "$root"/*) ;;
    *) die "refusing to clean path outside project: $path" ;;
  esac

  [[ -e "$path" || -L "$path" ]] || return 0
  /bin/rm -rf -- "$path"
}

detach_mountpoint_if_mounted() {
  local path="$1"

  if /usr/sbin/diskutil info "$path" >/dev/null 2>&1; then
    /usr/bin/hdiutil detach "$path" -quiet ||
      die "failed to detach mounted build image: $path"
  fi
}

run_clean() {
  local mountpoint

  mountpoint="$artifact_dir/build/mnt"
  detach_mountpoint_if_mounted "$mountpoint"

  clean_path "$artifact_dir"
  log_done "Removed $(display_path "$artifact_dir")"
}

run_self_test() {
  local rc

  if run_or_report "intentional failure propagation self-test" /bin/zsh -fc 'print -r -- expected failure output >&2; exit 37' >/dev/null 2>&1; then
    die "run_or_report self-test unexpectedly succeeded"
  else
    rc="$?"
  fi

  [[ "$rc" == "37" ]] || die "run_or_report self-test returned $rc instead of 37"
  log_done "Failure propagation self-test"
}

pins_file="$root/pins.conf"
parent_entitlements_source="$root/entitlements/parent.entitlements"
child_entitlements_source="$root/entitlements/child.entitlements"
typeset -a static_policy_files=(
  "$script_path"
  "$pins_file"
  "$parent_entitlements_source"
  "$child_entitlements_source"
  "$root/sandbox/fetch.sb"
  "$root/sandbox/unpack-verify.sb"
  "$root/sandbox/stage.sb"
  "$root/sandbox/sign-ad-hoc.sb"
  "$root/sandbox/sign-identity.sb"
  "$root/sandbox/verify.sb"
)
typeset -A pins
typeset -a required_pins=(
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

load_pins() {
  local file="$1"
  local line key value
  typeset -A seen

  [[ -f "$file" ]] || die "missing pins file: $file"

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
}

validate_pins() {
  [[ "${pins[obsidian_version]}" =~ '^[0-9]+([.][0-9]+)*$' ]] || die "invalid obsidian_version pin"
  [[ "${pins[electron_version]}" =~ '^[0-9]+([.][0-9]+)*$' ]] || die "invalid electron_version pin"
  [[ "${pins[obsidian_sha256]}" =~ '^[0-9a-f]{64}$' ]] || die "invalid obsidian_sha256 pin"
  [[ "${pins[electron_zip_sha256]}" =~ '^[0-9a-f]{64}$' ]] || die "invalid electron_zip_sha256 pin"
  [[ "${pins[electron_shasums_sha256]}" =~ '^[0-9a-f]{64}$' ]] || die "invalid electron_shasums_sha256 pin"
  [[ "${pins[github_tls_intermediate_sha256]}" =~ '^[0-9a-f]{64}(,[0-9a-f]{64})*$' ]] || die "invalid github_tls_intermediate_sha256 pin"
  [[ "${pins[github_assets_tls_intermediate_sha256]}" =~ '^[0-9a-f]{64}(,[0-9a-f]{64})*$' ]] || die "invalid github_assets_tls_intermediate_sha256 pin"
  [[ "${pins[obsidian_bundle_id]}" =~ '^[A-Za-z0-9.-]+$' ]] || die "invalid obsidian_bundle_id pin"
  [[ "${pins[obsidian_team_id]}" =~ '^[A-Z0-9]{10}$' ]] || die "invalid obsidian_team_id pin"
  [[ "${pins[obsidian_certificate_common_name]}" =~ '^[A-Za-z0-9 .,_()&:+/-]+$' ]] || die "invalid obsidian_certificate_common_name pin"
}

pins_file_sha256() {
  local line

  line="$(/usr/bin/shasum -a 256 "$pins_file")"
  print -r -- "${line%% *}"
}

static_policy_inputs_digest() {
  local file rel line manifest

  manifest=""
  for file in "${static_policy_files[@]}"; do
    [[ -f "$file" ]] || die "missing static policy input: $file"
    rel="${file#$root/}"
    [[ "$rel" != "$file" ]] || die "static policy input is outside project root: $file"
    line="$(/usr/bin/shasum -a 256 "$file")"
    manifest+="${line%% *}"$'\t'"$rel"$'\n'
  done

  print -rn -- "$manifest" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

verify_pins_file_unchanged() {
  local expected actual

  expected="${pins_conf_sha256:-}"
  [[ -n "$expected" ]] || die "missing pins.conf digest"
  [[ "$expected" =~ '^[0-9a-f]{64}$' ]] || die "invalid pins.conf digest"

  actual="$(pins_file_sha256)"
  [[ "$actual" == "$expected" ]] || die "pins.conf changed during build"
}

verify_static_policy_inputs_unchanged() {
  local expected actual

  expected="${static_policy_inputs_sha256:-}"
  [[ -n "$expected" ]] || die "missing static policy digest"
  [[ "$expected" =~ '^[0-9a-f]{64}$' ]] || die "invalid static policy digest"

  actual="$(static_policy_inputs_digest)"
  [[ "$actual" == "$expected" ]] || die "static policy inputs changed during build"
}

configure_build() {
  if [[ -n "$requested_phase" ]]; then
    pins_conf_sha256="${OBSIDIAN_PINS_CONF_SHA256:-}"
    [[ -n "$pins_conf_sha256" ]] || die "missing pins.conf digest for internal phase"
  else
    pins_conf_sha256="$(pins_file_sha256)"
    static_policy_inputs_sha256="$(static_policy_inputs_digest)"
  fi
  verify_pins_file_unchanged

  load_pins "$pins_file"
  validate_pins
  verify_pins_file_unchanged

  obsidian_version="${pins[obsidian_version]}"
  obsidian_asset="Obsidian-${obsidian_version}.dmg"
  obsidian_sha256="${pins[obsidian_sha256]}"
  obsidian_url="https://github.com/obsidianmd/obsidian-releases/releases/download/v${obsidian_version}/${obsidian_asset}"
  obsidian_bundle_id="${pins[obsidian_bundle_id]}"
  obsidian_team_id="${pins[obsidian_team_id]}"
  obsidian_certificate_common_name="${pins[obsidian_certificate_common_name]}"
  obsidian_requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$obsidian_team_id\" and certificate leaf[subject.CN] = \"$obsidian_certificate_common_name\""

  electron_version="${pins[electron_version]}"
  electron_asset="electron-v${electron_version}-mas-arm64"
  electron_zip_sha256="${pins[electron_zip_sha256]}"
  electron_shasums_sha256="${pins[electron_shasums_sha256]}"
  electron_url="https://github.com/electron/electron/releases/download/v${electron_version}/${electron_asset}.zip"
  electron_shasums_url="https://github.com/electron/electron/releases/download/v${electron_version}/SHASUMS256.txt"

  team_id="${OBSIDIAN_APP_GROUP_TEAM_ID:-LOCALOBSDN}"
  [[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || die "invalid effective team_id"
  output_app_name="${OBSIDIAN_OUTPUT_APP_NAME:-Obsidian Sandboxed}"
  [[ "$output_app_name" =~ '^[A-Za-z0-9][A-Za-z0-9 .,_()&+-]*$' ]] || die "invalid output app name"
  output_bundle_name="${OBSIDIAN_OUTPUT_BUNDLE_NAME:-Obsidian Sandboxed}"
  [[ "$output_bundle_name" =~ '^[A-Za-z0-9][A-Za-z0-9 .,_()&+-]*$' ]] || die "invalid output bundle name"
  output_bundle_id="${OBSIDIAN_OUTPUT_BUNDLE_ID:-dev.local.sandboxed.obsidian}"
  [[ "$output_bundle_id" =~ '^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$' ]] || die "invalid output bundle id"
  sign_identity="${SIGN_IDENTITY:--}"
  sign_timestamp="${SIGN_TIMESTAMP:-auto}"
  case "$sign_timestamp" in
    auto|0|1) ;;
    *) die "SIGN_TIMESTAMP must be auto, 0, or 1" ;;
  esac

  developer_id_identity=0
  developer_id_team_id=""
  developer_id_identity_regex='^Developer ID Application: .* \(([A-Z0-9]{10})\)$'
  if [[ "$sign_identity" == Developer\ ID\ Application:* ]]; then
    developer_id_identity=1
    [[ "$sign_identity" =~ $developer_id_identity_regex ]] ||
      die "SIGN_IDENTITY must include Developer ID team id, e.g. Developer ID Application: Name (TEAMID)"
    developer_id_team_id="${match[1]}"
  fi

  if [[ "$developer_id_identity" == "1" && "$team_id" != "$developer_id_team_id" ]]; then
    die "Developer ID team id $developer_id_team_id does not match OBSIDIAN_APP_GROUP_TEAM_ID=$team_id"
  fi

  timestamp_enabled=0
  case "$sign_timestamp" in
    auto)
      [[ "$developer_id_identity" == "1" ]] && timestamp_enabled=1
      ;;
    1)
      timestamp_enabled=1
      ;;
  esac
  [[ "$sign_identity" == "-" && "$timestamp_enabled" == "1" ]] &&
    die "SIGN_TIMESTAMP=1 cannot be used with ad hoc signing"

  typeset -ga codesign_timestamp_args
  if [[ "$timestamp_enabled" == "1" ]]; then
    codesign_timestamp_args=(--timestamp)
  else
    codesign_timestamp_args=(--timestamp=none)
  fi

  cache_dir="$artifact_dir/cache"
  build_dir="$artifact_dir/build"
  out_dir="$artifact_dir/out"
  obsidian_dmg="$cache_dir/$obsidian_asset"
  mountpoint="$build_dir/mnt"
  source_app="$build_dir/source/Obsidian.app"
  electron_zip="$cache_dir/${electron_asset}.zip"
  electron_shasums="$cache_dir/SHASUMS256-${electron_version}.txt"
  electron_dir="$build_dir/electron/${electron_asset}"
  electron_app="$electron_dir/Electron.app"
  stage_app="$out_dir/$output_app_name.app"
  helper_suffixes=("" " (Renderer)" " (Plugin)" " (GPU)")
  parent_entitlements="$build_dir/entitlements/parent.entitlements"
  child_entitlements="$build_dir/entitlements/child.entitlements"
  phase_tmp_dir="${OBSIDIAN_PHASE_TMP:-$build_dir/tmp}"
}

cleanup_mount() {
  hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

make_temp_file() {
  local name="$1"
  mktemp "$phase_tmp_dir/${name}.XXXXXX"
}

make_temp_dir() {
  local name="$1"
  mktemp -d "$phase_tmp_dir/${name}.XXXXXX"
}

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"

  /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $file
  expected: $expected
  actual:   $actual"
}

require_github_tls_pin_support() {
  local version
  version="$(curl --disable -V | awk 'NR == 1 { print $2 }')"

  curl --disable -V | awk '
    NR == 1 {
      split($2, v, ".")
      exit (v[1] > 7 || (v[1] == 7 && v[2] >= 88)) ? 0 : 1
    }
  ' || die "GitHub TLS pinning requires curl >= 7.88.0 for %{certs}; found curl $version"

  require openssl
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
    github.com)
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

  openssl x509 -in "$cert" -noout -text |
    awk '
      /X509v3 Basic Constraints/ { seen = 1; if (/CA:TRUE/) found = 1; next }
      seen && /CA:TRUE/ { found = 1; exit }
      seen && /^[[:space:]]*X509v3/ { exit }
      END { exit found ? 0 : 1 }
    '
}

cert_sha256_fingerprint() {
  local cert="$1"

  openssl x509 -in "$cert" -noout -fingerprint -sha256 |
    awk -F= '/Fingerprint/ { gsub(":", "", $2); print tolower($2); exit }'
}

verify_github_tls_pins() {
  local tls_info="$1"
  local effective_url host expected cert_dir cert count fingerprint
  local matched=0

  effective_url="$(awk '/^URL_EFFECTIVE=/ { sub(/^URL_EFFECTIVE=/, ""); print; exit }' "$tls_info")"
  [[ -n "$effective_url" ]] || {
    print -r -- "error: missing curl effective URL for TLS pin check" >&2
    return 1
  }

  host="$(url_host "$effective_url")" || {
    print -r -- "error: invalid HTTPS URL for TLS pin check: $effective_url" >&2
    return 1
  }

  expected="$(github_tls_pins_for_host "$host")" || {
    print -r -- "error: unexpected GitHub download host: $host" >&2
    return 1
  }

  cert_dir="$(make_temp_dir tls-certs)"

  awk -v dir="$cert_dir" '
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

  rm -rf "$cert_dir"

  [[ "$count" -gt 0 ]] || {
    print -r -- "error: missing certificate chain for TLS pin check: $host" >&2
    return 1
  }

  [[ "$matched" == "1" ]] || {
    print -r -- "error: GitHub TLS intermediate pin mismatch for $host" >&2
    return 1
  }
}

check_github_tls_url() {
  local url="$1"
  local tls_info

  tls_info="$(make_temp_file github-tls-head)"

  if ! curl \
    --disable \
    --silent \
    --show-error \
    --fail \
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
    rm -f "$tls_info"
    return 1
  fi

  if ! verify_github_tls_pins "$tls_info"; then
    rm -f "$tls_info"
    return 1
  fi

  rm -f "$tls_info"
}

download_file() {
  local url="$1"
  local out="$2"
  local tmp
  local tls_info
  typeset -a curl_output_args

  tmp="$(make_temp_file "${out:t}.download")"
  tls_info="$(make_temp_file "${out:t}.tls")"
  if [[ -t 2 ]]; then
    curl_output_args=(--progress-bar)
  else
    curl_output_args=(--silent --show-error)
  fi

  if ! check_github_tls_url "$url"; then
    rm -f "$tmp" "$tls_info"
    return 1
  fi

  if ! curl \
    --disable \
    "${curl_output_args[@]}" \
    --fail \
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
    rm -f "$tmp" "$tls_info"
    return 1
  fi

  if ! verify_github_tls_pins "$tls_info"; then
    rm -f "$tmp" "$tls_info"
    return 1
  fi

  chmod 600 "$tmp"
  mv -f "$tmp" "$out"
  rm -f "$tls_info"
}

expected_zip_sha256_from_manifest() {
  awk -v name="${electron_asset}.zip" '{ file = $2; sub(/^\*/, "", file) } file == name { print $1; found = 1 } END { exit found ? 0 : 1 }' "$electron_shasums"
}

verify_upstream_obsidian() {
  local app="$1"
  local bundle_id
  local version

  bundle_id="$(plist_get "$app/Contents/Info.plist" CFBundleIdentifier)"
  version="$(plist_get "$app/Contents/Info.plist" CFBundleShortVersionString)"

  [[ "$bundle_id" == "$obsidian_bundle_id" ]] || die "unexpected Obsidian bundle id: $bundle_id"
  [[ "$version" == "$obsidian_version" ]] ||
    die "pinned Obsidian version $obsidian_version does not match bundle CFBundleShortVersionString $version"

  run_or_report "upstream Obsidian signature verification" \
    codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    --test-requirement "$obsidian_requirement" \
    "$app"

  run_or_report "upstream Obsidian Gatekeeper assessment" \
    spctl --assess --type execute --verbose=4 "$app"
}

codesign_item() {
  local item="$1"
  shift

  run_or_report "signing $(display_path "$item")" \
    codesign \
    --force \
    --sign "$sign_identity" \
    "${codesign_timestamp_args[@]}" \
    --options runtime \
    "$@" \
    "$item"
}

write_entitlements() {
  local bundle_id="$1"
  local app_group="$team_id.$bundle_id"

  mkdir -p "${parent_entitlements:h}"
  rm -f "$parent_entitlements" "$child_entitlements"

  [[ -f "$parent_entitlements_source" ]] || die "missing parent entitlements source: $parent_entitlements_source"
  [[ -f "$child_entitlements_source" ]] || die "missing child entitlements source: $child_entitlements_source"
  awk 'index($0, "__APP_GROUP__") { found = 1 } END { exit found ? 0 : 1 }' "$parent_entitlements_source" ||
    die "missing __APP_GROUP__ placeholder in $parent_entitlements_source"

  awk -v app_group="$app_group" '
    {
      gsub(/__APP_GROUP__/, app_group)
      print
    }
  ' "$parent_entitlements_source" > "$parent_entitlements"

  cp "$child_entitlements_source" "$child_entitlements"

  ! awk 'index($0, "__APP_GROUP__") { found = 1 } END { exit found ? 0 : 1 }' "$parent_entitlements" ||
    die "unresolved __APP_GROUP__ placeholder in $parent_entitlements"

  plutil -lint "$parent_entitlements" >/dev/null
  plutil -lint "$child_entitlements" >/dev/null
  chmod 600 "$parent_entitlements" "$child_entitlements"
}

fetch_electron() {
  mkdir -p "$cache_dir"

  if [[ ! -f "$electron_zip" ]]; then
    log_detail "Downloading Electron archive: ${electron_asset}.zip"
    download_file "$electron_url" "$electron_zip"
  else
    log_detail "Using cached Electron archive: $(display_path "$electron_zip")"
  fi

  if [[ ! -f "$electron_shasums" ]]; then
    log_detail "Downloading Electron checksum manifest: SHASUMS256.txt"
    download_file "$electron_shasums_url" "$electron_shasums"
  else
    log_detail "Using cached Electron checksum manifest: $(display_path "$electron_shasums")"
  fi

  verify_electron_downloads
}

unpack_verify_electron() {
  verify_electron_downloads
  log_detail "Unpacking Electron archive"
  rm -rf "$electron_dir"
  mkdir -p "$electron_dir"
  ditto -x -k "$electron_zip" "$electron_dir"
  [[ -d "$electron_app" ]] || die "missing extracted Electron.app: $electron_app"
}

verify_electron_downloads() {
  [[ -f "$electron_shasums" ]] || die "missing cached Electron SHASUMS256.txt: $electron_shasums"
  [[ -f "$electron_zip" ]] || die "missing cached Electron ZIP: $electron_zip"

  log_detail "Verifying Electron checksum manifest"
  verify_sha256 "$electron_shasums" "$electron_shasums_sha256"
  chmod 600 "$electron_shasums"

  local manifest_zip_sha256
  manifest_zip_sha256="$(expected_zip_sha256_from_manifest)" || die "missing ${electron_asset}.zip in $electron_shasums"
  [[ "$manifest_zip_sha256" == "$electron_zip_sha256" ]] || die "pinned ZIP hash does not match Electron SHASUMS256.txt
  pinned:   $electron_zip_sha256
  manifest: $manifest_zip_sha256"

  log_detail "Verifying Electron archive hash"
  verify_sha256 "$electron_zip" "$manifest_zip_sha256"
  chmod 600 "$electron_zip"
}

fetch_obsidian() {
  mkdir -p "$cache_dir"

  if [[ ! -f "$obsidian_dmg" ]]; then
    log_detail "Downloading Obsidian DMG: $obsidian_asset"
    download_file "$obsidian_url" "$obsidian_dmg"
  else
    log_detail "Using cached Obsidian DMG: $(display_path "$obsidian_dmg")"
  fi

  verify_obsidian_download
}

verify_obsidian_download() {
  [[ -f "$obsidian_dmg" ]] || die "missing cached Obsidian DMG: $obsidian_dmg"
  log_detail "Verifying Obsidian DMG hash"
  verify_sha256 "$obsidian_dmg" "$obsidian_sha256"
  chmod 600 "$obsidian_dmg"
}

unpack_verify_obsidian() {
  verify_obsidian_download
  detach_mountpoint_if_mounted "$mountpoint"
  rm -rf "$build_dir/source" "$mountpoint"
  mkdir -p "$build_dir/source" "$mountpoint"
  trap cleanup_mount EXIT

  log_detail "Mounting Obsidian DMG"
  hdiutil attach \
    -nobrowse \
    -readonly \
    -noautoopen \
    -mountpoint "$mountpoint" \
    "$obsidian_dmg" >/dev/null

  local mounted_app
  mounted_app="$(find "$mountpoint" -maxdepth 2 -name "Obsidian.app" -type d -print -quit)"
  [[ -n "$mounted_app" ]] || die "could not find Obsidian.app in $obsidian_asset"

  log_detail "Copying upstream Obsidian.app"
  ditto "$mounted_app" "$source_app"
  cleanup_mount
  trap - EXIT
  rmdir "$mountpoint" 2>/dev/null || true

  log_detail "Verifying upstream Obsidian signature and Gatekeeper assessment"
  verify_upstream_obsidian "$source_app"
}

output_helper_name() {
  local suffix="$1"

  print -r -- "$output_bundle_name Helper${suffix}"
}

helper_bundle_id_for_suffix() {
  local suffix="$1"

  case "$suffix" in
    "") print -r -- "$output_bundle_id.helper" ;;
    " (Renderer)") print -r -- "$output_bundle_id.helper.Renderer" ;;
    " (Plugin)") print -r -- "$output_bundle_id.helper.Plugin" ;;
    " (GPU)") print -r -- "$output_bundle_id.helper.GPU" ;;
    *) die "unexpected helper suffix: $suffix" ;;
  esac
}

is_output_helper_bundle_name() {
  local bundle_name="$1"
  local suffix helper_name

  for suffix in "${helper_suffixes[@]}"; do
    helper_name="$(output_helper_name "$suffix")"
    [[ "$bundle_name" == "${helper_name}.app" ]] && return 0
  done

  return 1
}

replace_helper() {
  local suffix="$1"
  local donor_helper="Electron Helper${suffix}"
  local source_helper="Obsidian Helper${suffix}"
  local output_helper
  local donor dest source_info donor_exe dest_exe staged_source_helper helper_bundle_id

  output_helper="$(output_helper_name "$suffix")"
  donor="$electron_app/Contents/Frameworks/${donor_helper}.app"
  dest="$stage_app/Contents/Frameworks/${output_helper}.app"
  source_info="$source_app/Contents/Frameworks/${source_helper}.app/Contents/Info.plist"
  donor_exe="$dest/Contents/MacOS/${donor_helper}"
  dest_exe="$dest/Contents/MacOS/${output_helper}"
  staged_source_helper="$stage_app/Contents/Frameworks/${source_helper}.app"
  helper_bundle_id="$(helper_bundle_id_for_suffix "$suffix")"

  [[ -d "$donor" ]] || die "missing Electron helper: $donor"
  [[ -f "$source_info" ]] || die "missing source helper Info.plist: $source_info"

  rm -rf "$dest"
  [[ "$staged_source_helper" == "$dest" ]] || rm -rf "$staged_source_helper"
  ditto "$donor" "$dest"
  cp "$source_info" "$dest/Contents/Info.plist"
  plist_set_string "$dest/Contents/Info.plist" CFBundleIdentifier "$helper_bundle_id"
  plist_set_string "$dest/Contents/Info.plist" CFBundleDisplayName "$output_helper"
  plist_set_string "$dest/Contents/Info.plist" CFBundleExecutable "$output_helper"
  plist_set_string "$dest/Contents/Info.plist" CFBundleName "$output_helper"
  mv "$donor_exe" "$dest_exe"
  chmod 755 "$dest_exe"
}

expect_plist_string() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(plist_get "$plist" "$key")"
  [[ "$actual" == "$expected" ]] || die "unexpected $key in $plist
  expected: $expected
  actual:   $actual"
}

validate_stage_symlinks() {
  local link target target_path resolved stage_real

  stage_real="${stage_app:A}"
  while IFS= read -r -d '' link; do
    target="$(/usr/bin/readlink "$link")" || die "failed to read symlink: $link"
    [[ -n "$target" ]] || die "symlink has an empty target: $link"
    [[ "$target" != *$'\n'* ]] || die "symlink target contains newline: $link"

    case "$target" in
      /*) target_path="$target" ;;
      *) target_path="${link:h}/$target" ;;
    esac

    [[ -e "$target_path" ]] || die "symlink target does not exist: $link -> $target"
    resolved="${target_path:A}"
    case "$resolved" in
      "$stage_real"|"$stage_real"/*) ;;
      *) die "symlink escapes staged app: $link -> $target" ;;
    esac
  done < <(find "$stage_app" -type l -print0)
}

validate_stage_bundles() {
  local bundle rel suffix helper_name
  typeset -A expected

  expected=(
    "Contents/Frameworks/Electron Framework.framework" 1
    "Contents/Frameworks/Mantle.framework" 1
    "Contents/Frameworks/ReactiveObjC.framework" 1
    "Contents/Frameworks/Squirrel.framework" 1
  )
  for suffix in "${helper_suffixes[@]}"; do
    helper_name="$(output_helper_name "$suffix")"
    rel="Contents/Frameworks/${helper_name}.app"
    expected[$rel]=1
  done

  for rel in "${(@k)expected}"; do
    [[ -d "$stage_app/$rel" ]] || die "missing expected nested bundle: $rel"
  done

  while IFS= read -r -d '' bundle; do
    rel="${bundle#$stage_app/}"
    [[ -n "${expected[$rel]-}" ]] || die "unexpected nested bundle: $rel"
  done < <(
    find "$stage_app/Contents" -type d \
      \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" -o -name "*.bundle" -o -name "*.app" \) \
      -print0
  )
}

validate_stage_helpers() {
  local suffix helper_name helper_plist

  for suffix in "${helper_suffixes[@]}"; do
    helper_name="$(output_helper_name "$suffix")"
    helper_plist="$stage_app/Contents/Frameworks/${helper_name}.app/Contents/Info.plist"

    expect_plist_string "$helper_plist" CFBundleIdentifier "$(helper_bundle_id_for_suffix "$suffix")"
    expect_plist_string "$helper_plist" CFBundleDisplayName "$helper_name"
    expect_plist_string "$helper_plist" CFBundleExecutable "$helper_name"
    expect_plist_string "$helper_plist" CFBundleName "$helper_name"
  done
}

is_known_standalone_executable() {
  local rel="$1"
  local main_executable suffix helper_name

  main_executable="$(plist_get "$stage_app/Contents/Info.plist" CFBundleExecutable)"
  [[ "$rel" == "Contents/MacOS/$main_executable" ]] && return 0

  for suffix in "${helper_suffixes[@]}"; do
    helper_name="$(output_helper_name "$suffix")"
    [[ "$rel" == "Contents/Frameworks/${helper_name}.app/Contents/MacOS/${helper_name}" ]] && return 0
  done

  return 1
}

is_standalone_macho_executable() {
  local item="$1"

  case "$(file -b "$item")" in
    *Mach-O*executable*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_unknown_standalone_executables() {
  local item rel

  while IFS= read -r -d '' item; do
    is_standalone_macho_executable "$item" || continue
    rel="${item#$stage_app/}"
    if ! is_known_standalone_executable "$rel"; then
      log_detail "Removing unexpected executable: $rel"
      rm -f "$item"
    fi
  done < <(find "$stage_app/Contents" -type f -print0)
}

has_shebang() {
  local item="$1"

  /usr/bin/perl -e 'read(STDIN, my $magic, 2); exit($magic eq "#!" ? 0 : 1)' < "$item"
}

normalize_resource_execute_bits() {
  local item

  while IFS= read -r -d '' item; do
    case "$(file -b "$item")" in
      *Mach-O*) continue ;;
    esac

    has_shebang "$item" && continue
    chmod a-x "$item"
  done < <(
    find "$stage_app/Contents/Resources" -type f \
      \( -perm -0100 -o -perm -0010 -o -perm -0001 \) \
      -print0
  )
}

validate_standalone_executables() {
  local item rel

  while IFS= read -r -d '' item; do
    is_standalone_macho_executable "$item" || continue
    rel="${item#$stage_app/}"
    is_known_standalone_executable "$rel" ||
      die "unexpected standalone executable: $rel"
  done < <(find "$stage_app/Contents" -type f -print0)
}

validate_stage_macho_inventory() {
  local item rel main_executable suffix helper_name
  typeset -A expected

  main_executable="$(plist_get "$stage_app/Contents/Info.plist" CFBundleExecutable)"
  expected=(
    "Contents/MacOS/$main_executable" 1
    "Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework" 1
    "Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libEGL.dylib" 1
    "Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libGLESv2.dylib" 1
    "Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libffmpeg.dylib" 1
    "Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libvk_swiftshader.dylib" 1
    "Contents/Frameworks/Mantle.framework/Versions/A/Mantle" 1
    "Contents/Frameworks/ReactiveObjC.framework/Versions/A/ReactiveObjC" 1
    "Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel" 1
    "Contents/Resources/app.asar.unpacked/node_modules/btime/bin/darwin-x64-101/btime.node" 1
    "Contents/Resources/app.asar.unpacked/node_modules/btime/bin/darwin-x64-87/btime.node" 1
    "Contents/Resources/app.asar.unpacked/node_modules/btime/binding.node" 1
    "Contents/Resources/app.asar.unpacked/node_modules/get-fonts/bin/darwin-x64-101/get-fonts.node" 1
    "Contents/Resources/app.asar.unpacked/node_modules/get-fonts/binding.node" 1
  )
  for suffix in "${helper_suffixes[@]}"; do
    helper_name="$(output_helper_name "$suffix")"
    rel="Contents/Frameworks/${helper_name}.app/Contents/MacOS/${helper_name}"
    expected[$rel]=1
  done

  for rel in "${(@k)expected}"; do
    [[ -f "$stage_app/$rel" ]] || die "missing expected Mach-O file: $rel"
  done

  while IFS= read -r -d '' item; do
    case "$(file -b "$item")" in
      *Mach-O*)
        rel="${item#$stage_app/}"
        [[ -n "${expected[$rel]-}" ]] || die "unexpected Mach-O file: $rel"
        ;;
    esac
  done < <(find "$stage_app/Contents" -type f -print0)
}

collect_resource_tree() {
  local root="$1"
  local side="$2"
  local item rel hash_line hash

  [[ -d "$root" ]] || die "missing resource tree: $root"
  [[ ! -L "$root" ]] || die "resource tree is a symlink: $root"

  while IFS= read -r -d '' item; do
    [[ "$item" == "$root" ]] && continue
    rel="${item#$root/}"
    [[ "$rel" != "$item" ]] || die "resource path escaped root: $item"
    [[ "$rel" != *$'\n'* ]] || die "resource path contains newline: $item"

    if [[ -L "$item" ]]; then
      die "resource symlink is not expected: $item"
    elif [[ -d "$item" ]]; then
      case "$side" in
        expected) expected_resource_dirs[$rel]=1 ;;
        actual) actual_resource_dirs[$rel]=1 ;;
        *) die "unknown resource tree side: $side" ;;
      esac
    elif [[ -f "$item" ]]; then
      hash_line="$(shasum -a 256 "$item")"
      hash="${hash_line%% *}"
      case "$side" in
        expected) expected_resource_files[$rel]="$hash" ;;
        actual) actual_resource_files[$rel]="$hash" ;;
        *) die "unknown resource tree side: $side" ;;
      esac
    else
      die "unsupported resource file type: $item"
    fi
  done < <(find "$root" -print0)
}

verify_staged_resources_match_source() {
  local rel expected_hash actual_hash
  typeset -A expected_resource_dirs actual_resource_dirs
  typeset -A expected_resource_files actual_resource_files

  collect_resource_tree "$source_app/Contents/Resources" expected
  collect_resource_tree "$stage_app/Contents/Resources" actual

  for rel in "${(@k)expected_resource_dirs}"; do
    [[ -n "${actual_resource_dirs[$rel]-}" ]] ||
      die "missing staged resource directory: Contents/Resources/$rel"
  done
  for rel in "${(@k)actual_resource_dirs}"; do
    [[ -n "${expected_resource_dirs[$rel]-}" ]] ||
      die "unexpected staged resource directory: Contents/Resources/$rel"
  done

  for rel in "${(@k)expected_resource_files}"; do
    expected_hash="${expected_resource_files[$rel]}"
    actual_hash="${actual_resource_files[$rel]-}"
    [[ -n "$actual_hash" ]] ||
      die "missing staged resource file: Contents/Resources/$rel"
    [[ "$actual_hash" == "$expected_hash" ]] || die "staged resource hash mismatch: Contents/Resources/$rel
  expected: $expected_hash
  actual:   $actual_hash"
  done
  for rel in "${(@k)actual_resource_files}"; do
    [[ -n "${expected_resource_files[$rel]-}" ]] ||
      die "unexpected staged resource file: Contents/Resources/$rel"
  done
}

validate_stage_tree() {
  local info_plist electron_info

  [[ -d "$stage_app" ]] || die "missing staged app: $stage_app"
  info_plist="$stage_app/Contents/Info.plist"
  electron_info="$stage_app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"
  [[ -f "$info_plist" ]] || die "missing staged Info.plist: $info_plist"
  [[ -f "$electron_info" ]] || die "missing staged Electron Info.plist: $electron_info"

  expect_plist_string "$info_plist" CFBundleIdentifier "$output_bundle_id"
  expect_plist_string "$info_plist" CFBundleName "$output_bundle_name"
  expect_plist_string "$info_plist" CFBundleExecutable "Obsidian"
  expect_plist_string "$info_plist" ElectronTeamID "$team_id"
  expect_plist_string "$electron_info" CFBundleVersion "$electron_version"
  validate_stage_symlinks
  validate_stage_bundles
  validate_stage_helpers
  validate_standalone_executables
  validate_stage_macho_inventory
}

stage_app_bundle() {
  local source_electron_info source_electron_version electron_info downloaded_electron_version
  local source_bundle_id bundle_executable

  [[ -d "$source_app" ]] || die "missing verified source app: $source_app"
  [[ -d "$electron_app" ]] || die "missing extracted Electron app: $electron_app"

  source_electron_info="$source_app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"
  source_electron_version="$(plist_get "$source_electron_info" CFBundleVersion)"
  log_detail "Replacing upstream Electron $source_electron_version with sandbox-compatible Electron $electron_version"

  electron_info="$electron_app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"
  downloaded_electron_version="$(plist_get "$electron_info" CFBundleVersion)"
  [[ "$downloaded_electron_version" == "$electron_version" ]] || die "downloaded Electron version mismatch: $downloaded_electron_version"

  source_bundle_id="$(plist_get "$source_app/Contents/Info.plist" CFBundleIdentifier)"
  [[ "$source_bundle_id" == "$obsidian_bundle_id" ]] || die "unexpected staged source bundle id: $source_bundle_id"
  bundle_executable="$(plist_get "$source_app/Contents/Info.plist" CFBundleExecutable)"
  [[ "$bundle_executable" == "Obsidian" ]] || die "unexpected source executable: $bundle_executable"

  rm -rf "$stage_app"
  mkdir -p "$out_dir"
  log_detail "Copying verified Obsidian resources"
  ditto "$source_app" "$stage_app"
  xattr -cr "$stage_app"

  log_detail "Replacing app executable and framework"
  rm -f "$stage_app/Contents/MacOS/$bundle_executable"
  ditto "$electron_app/Contents/MacOS/Electron" "$stage_app/Contents/MacOS/$bundle_executable"
  chmod 755 "$stage_app/Contents/MacOS/$bundle_executable"

  rm -rf "$stage_app/Contents/Frameworks/Electron Framework.framework"
  ditto "$electron_app/Contents/Frameworks/Electron Framework.framework" \
    "$stage_app/Contents/Frameworks/Electron Framework.framework"

  log_detail "Replacing helper apps"
  replace_helper ""
  replace_helper " (Renderer)"
  replace_helper " (Plugin)"
  replace_helper " (GPU)"
  remove_unknown_standalone_executables
  normalize_resource_execute_bits

  log_detail "Writing output bundle metadata"
  plist_set_string "$stage_app/Contents/Info.plist" CFBundleIdentifier "$output_bundle_id"
  plist_set_string "$stage_app/Contents/Info.plist" CFBundleName "$output_bundle_name"
  plist_set_string "$stage_app/Contents/Info.plist" CFBundleDisplayName "$output_app_name"
  plist_set_string "$stage_app/Contents/Info.plist" ElectronTeamID "$team_id"
  log_detail "Validating staged app inventory"
  validate_stage_tree
}

sign_loose_macho() {
  local app="$1"
  local main_exec="$2"

  while IFS= read -r -d '' item; do
    [[ "$item" == "$main_exec" ]] && continue

    case "$(file -b "$item")" in
      *Mach-O*) codesign_item "$item" ;;
    esac
  done < <(find "$app/Contents" -type f -print0)
}

sign_nested_bundles() {
  local app="$1"

  while IFS= read -r -d '' bundle; do
    if is_output_helper_bundle_name "${bundle:t}"; then
      codesign_item "$bundle" --entitlements "$child_entitlements"
    else
      codesign_item "$bundle"
    fi
  done < <(
    find "$app/Contents" -depth -type d \
      \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" -o -name "*.bundle" -o -name "*.app" \) \
      -print0
  )
}

remove_existing_signatures() {
  local app="$1"
  local app_real stage_real

  [[ -n "$app" ]] || die "empty app path"
  [[ -d "$app/Contents" ]] || die "not an app bundle: $app"
  [[ ! -L "$app" ]] || die "app bundle is a symlink: $app"

  app_real="${app:A}"
  stage_real="${stage_app:A}"
  [[ "$app_real" == "$stage_real" ]] ||
    die "refusing to strip signatures outside staged app: $app"

  find "$app" \
    -name _CodeSignature \
    \( -type d -o -type l \) \
    -prune \
    -exec /bin/rm -rf -- {} +

  find "$app" \
    -path "*/Contents/CodeResources" \
    \( -type f -o -type l \) \
    -exec /bin/rm -f -- {} +
}

sign_app() {
  local app="$1"
  local info_plist="$app/Contents/Info.plist"
  local main_exec

  main_exec="$app/Contents/MacOS/$(plist_get "$info_plist" CFBundleExecutable)"

  remove_existing_signatures "$app"
  sign_loose_macho "$app" "$main_exec"
  sign_nested_bundles "$app"
  codesign_item "$app" --entitlements "$parent_entitlements"
}

plist_sha256() {
  local plist="$1"
  local binary_plist="$2"

  plutil -convert binary1 -o "$binary_plist" "$plist"
  shasum -a 256 "$binary_plist" | awk '{ print $1 }'
}

verify_entitlements_match() {
  local item="$1"
  local expected="$2"
  local label="$3"
  local actual expected_binary actual_binary
  local expected_hash actual_hash

  actual="$(make_temp_file "${label}.entitlements")"
  expected_binary="$(make_temp_file "${label}.expected")"
  actual_binary="$(make_temp_file "${label}.actual")"

  run_or_report "code signature verification for $item" \
    codesign --verify --strict "$item"
  codesign -d --entitlements :- "$item" 2>/dev/null > "$actual" ||
    die "failed to read signed entitlements for $item"

  plutil -lint "$expected" >/dev/null
  plutil -lint "$actual" >/dev/null

  expected_hash="$(plist_sha256 "$expected" "$expected_binary")"
  actual_hash="$(plist_sha256 "$actual" "$actual_binary")"

  rm -f "$actual" "$expected_binary" "$actual_binary"

  [[ "$actual_hash" == "$expected_hash" ]] || die "entitlements mismatch for $item
  expected: $expected
  expected hash: $expected_hash
  actual hash:   $actual_hash"
}

verify_signed_entitlements() {
  local app="$1"
  local helper count suffix

  verify_entitlements_match "$app" "$parent_entitlements" "parent"

  count=0
  for suffix in "${helper_suffixes[@]}"; do
    helper="$app/Contents/Frameworks/$(output_helper_name "$suffix").app"
    [[ -d "$helper" ]] || die "missing helper for entitlement verification: $helper"
    count=$((count + 1))
    verify_entitlements_match "$helper" "$child_entitlements" "helper-$count"
  done

  [[ "$count" -gt 0 ]] || die "no helper apps found for entitlement verification"
}

verify_final_app() {
  local app="$1"

  log_detail "Verifying final code signature"
  run_or_report "final code signature verification" \
    codesign --verify --deep --strict --verbose=4 "$app"
  log_done "Final code signature is valid"

  log_detail "Comparing signed entitlements with generated entitlements"
  verify_signed_entitlements "$app"
  log_done "Signed entitlements match generated entitlements"
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

prepare_parent_dirs() {
  require_safe_existing_dir "$root" "project root"
  ensure_private_dir "$artifact_dir" "artifacts directory"
  ensure_private_dir "$cache_dir" "cache directory"
  ensure_private_dir "$build_dir" "build directory"
  ensure_private_dir "$build_dir/electron" "electron build directory"
  ensure_private_dir "$build_dir/tmp" "build temp directory"
  ensure_private_dir "$build_dir/home" "build home directory"
  ensure_private_dir "$out_dir" "output directory"
}

prepare_phase_dirs() {
  local phase_tmp_real build_tmp_real

  build_tmp_real="${build_dir:A}/tmp"
  phase_tmp_real="${phase_tmp_dir:A}"
  case "$phase_tmp_real" in
    "$build_tmp_real"|"$build_tmp_real"/*) ;;
    *) die "phase temp directory must be under $build_dir/tmp: $phase_tmp_dir" ;;
  esac

  /bin/mkdir -p "$phase_tmp_dir"
  /bin/chmod 700 "$phase_tmp_dir"
}

require_plistbuddy() {
  [[ -x /usr/libexec/PlistBuddy ]] || die "missing required command: /usr/libexec/PlistBuddy"
}

require_phase_commands() {
  local phase="$1"
  local cmd
  typeset -a commands

  case "$phase" in
    fetch)
      commands=(zsh curl shasum awk openssl mv rm mkdir chmod mktemp uname)
      ;;
    unpack-verify)
      commands=(zsh shasum awk hdiutil ditto codesign spctl find plutil rm mkdir chmod rmdir uname)
      require_plistbuddy
      ;;
    stage)
      commands=(zsh ditto xattr file find plutil readlink shasum cp mv rm mkdir chmod perl uname)
      require_plistbuddy
      ;;
    sign)
      commands=(zsh awk codesign file find plutil readlink shasum cp rm mkdir chmod uname)
      require_plistbuddy
      ;;
    verify)
      commands=(zsh shasum awk codesign file find plutil readlink rm mkdir chmod mktemp uname)
      require_plistbuddy
      ;;
    *)
      die "unknown phase: $phase"
      ;;
  esac

  for cmd in "${commands[@]}"; do
    require "$cmd"
  done
}

verify_internal_phase_invocation() {
  local expected_token

  valid_phase "$requested_phase" || die "unknown internal phase: $requested_phase"
  [[ "${OBSIDIAN_INTERNAL_PHASE:-}" == "$requested_phase" ]] ||
    die "phase argument/environment mismatch"
  [[ -n "${OBSIDIAN_PHASE_TOKEN:-}" ]] || die "missing internal phase token"
  [[ -n "${OBSIDIAN_PHASE_TOKEN_FILE:-}" ]] || die "missing internal phase token file"
  [[ -f "$OBSIDIAN_PHASE_TOKEN_FILE" ]] || die "missing internal phase token file: $OBSIDIAN_PHASE_TOKEN_FILE"

  expected_token="$(< "$OBSIDIAN_PHASE_TOKEN_FILE")"
  [[ "$expected_token" == "$OBSIDIAN_PHASE_TOKEN" ]] || die "invalid internal phase token"
}

require_internal_phase_sandbox() {
  local probe="/private/tmp/obsidian-internal-phase-sandbox-probe.$$.$RANDOM"

  [[ ! -e "$probe" && ! -L "$probe" ]] ||
    die "sandbox probe path already exists: $probe"

  # Phase profiles intentionally deny writes outside the private build tree.
  if ( print -r -- "probe" > "$probe" ) 2>/dev/null; then
    /bin/rm -f -- "$probe"
    die "internal phases must run under sandbox-exec"
  fi
}

run_internal_phase() {
  local phase="$1"

  verify_internal_phase_invocation
  require_internal_phase_sandbox
  prepare_phase_dirs
  require_phase_commands "$phase"
  verify_pins_file_unchanged
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || die "this script is pinned to the sandbox-compatible arm64 Electron build"

  case "$phase" in
    fetch)
      require_github_tls_pin_support
      fetch_obsidian
      fetch_electron
      ;;
    unpack-verify)
      unpack_verify_obsidian
      unpack_verify_electron
      expect_plist_string "$electron_app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist" \
        CFBundleVersion "$electron_version"
      ;;
    stage)
      stage_app_bundle
      ;;
    sign)
      validate_stage_tree
      verify_staged_resources_match_source
      write_entitlements "$output_bundle_id"
      log_detail "Signing staged app"
      sign_app "$stage_app"
      ;;
    verify)
      validate_stage_tree
      verify_final_app "$stage_app"
      ;;
  esac
}

phase_home_for() {
  local phase="$1"

  if [[ "$phase" == "sign" && "$sign_identity" != "-" ]]; then
    print -r -- "${HOME:A}"
  else
    print -r -- "$build_dir/home/$phase"
  fi
}

sandbox_profile_for() {
  local phase="$1"

  case "$phase" in
    sign)
      if [[ "$sign_identity" == "-" ]]; then
        print -r -- "$root/sandbox/sign-ad-hoc.sb"
      else
        print -r -- "$root/sandbox/sign-identity.sb"
      fi
      ;;
    *)
      print -r -- "$root/sandbox/$phase.sb"
      ;;
  esac
}

run_phase() {
  local phase="$1"
  local phase_index="$2"
  local phase_total="$3"
  local profile phase_home phase_tmp token token_file
  local rc

  profile="$(sandbox_profile_for "$phase")"
  phase_home="$(phase_home_for "$phase")"
  phase_tmp="$build_dir/tmp/$phase"
  token="$phase.$$.$(/usr/bin/uuidgen)"
  token_file="$phase_token_dir/$phase.token"

  [[ -f "$profile" ]] || die "missing sandbox profile: $profile"
  ensure_private_dir "$phase_tmp" "$phase temp directory"
  case "${phase_home:A}" in
    "${build_dir:A}/home"|"${build_dir:A}/home"/*)
      ensure_private_dir "$phase_home" "$phase home directory"
      ;;
  esac
  print -r -- "$token" > "$token_file"
  /bin/chmod 600 "$token_file"

  verify_static_policy_inputs_unchanged
  log_blank
  log "[$phase_index/$phase_total] $(phase_label "$phase")"
  if /usr/bin/sandbox-exec \
      -f "$profile" \
      -D ROOT="$root" \
      -D TMP="$phase_tmp" \
      -D HOME="$phase_home" \
      -D SIGN_TIMESTAMP="$timestamp_enabled" \
      /usr/bin/env -i \
        HOME="$phase_home" \
        TMPDIR="$phase_tmp" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        OBSIDIAN_INTERNAL_PHASE="$phase" \
        OBSIDIAN_PINS_CONF_SHA256="$pins_conf_sha256" \
        OBSIDIAN_PHASE_TOKEN="$token" \
        OBSIDIAN_PHASE_TOKEN_FILE="$token_file" \
        OBSIDIAN_PHASE_TMP="$phase_tmp" \
        OBSIDIAN_APP_GROUP_TEAM_ID="${OBSIDIAN_APP_GROUP_TEAM_ID:-}" \
        OBSIDIAN_OUTPUT_APP_NAME="${OBSIDIAN_OUTPUT_APP_NAME:-}" \
        OBSIDIAN_OUTPUT_BUNDLE_NAME="${OBSIDIAN_OUTPUT_BUNDLE_NAME:-}" \
        OBSIDIAN_OUTPUT_BUNDLE_ID="${OBSIDIAN_OUTPUT_BUNDLE_ID:-}" \
        SIGN_IDENTITY="${SIGN_IDENTITY:-}" \
        SIGN_TIMESTAMP="${SIGN_TIMESTAMP:-}" \
        /bin/zsh "$script_path" --internal-phase "$phase"; then
    log_done "$(phase_label "$phase")"
  else
    rc="$?"
    print -r -- "error: phase failed: $(phase_label "$phase") (exit $rc)" >&2
    return "$rc"
  fi
}

run_parent_build() {
  local phase phase_index phase_total
  typeset -a phases

  [[ -x /usr/bin/sandbox-exec ]] || die "missing required command: /usr/bin/sandbox-exec"
  [[ -x /usr/bin/uuidgen ]] || die "missing required command: /usr/bin/uuidgen"
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || die "this script is pinned to the sandbox-compatible arm64 Electron build"
  prepare_parent_dirs
  /usr/bin/find "$build_dir/tmp" -maxdepth 1 -type d -name "phase-tokens.*" -exec /bin/rm -rf -- {} +
  phase_token_dir="$(/usr/bin/mktemp -d "$build_dir/tmp/phase-tokens.XXXXXX")"
  /bin/chmod 700 "$phase_token_dir"
  require_safe_existing_dir "$phase_token_dir" "phase token directory"

  phases=(fetch unpack-verify stage sign verify)
  log_build_plan
  phase_index=0
  phase_total="${#phases[@]}"
  for phase in "${phases[@]}"; do
    phase_index=$((phase_index + 1))
    run_phase "$phase" "$phase_index" "$phase_total"
  done

  log_blank
  log "Build complete"
  log_kv "App" "$stage_app"
}

if [[ "$command" == "clean" ]]; then
  trap cleanup_on_exit EXIT
  acquire_build_lock
  run_clean
  exit 0
fi

if [[ "$command" == "self-test" ]]; then
  run_self_test
  exit 0
fi

configure_build

if [[ -n "$requested_phase" ]]; then
  run_internal_phase "$requested_phase"
else
  trap cleanup_on_exit EXIT
  acquire_build_lock
  run_parent_build
fi
