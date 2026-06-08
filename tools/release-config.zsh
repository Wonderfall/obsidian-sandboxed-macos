# Shared release config parser.
# Caller must define die() and require_safe_existing_file().

validate_release_conf_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    manifest_format)
      [[ "$value" =~ '^[A-Za-z0-9._@+-]+$' ]] || die "invalid release config value for $key"
      ;;
    project)
      [[ "$value" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || die "invalid release config value for $key"
      ;;
    archive_project)
      [[ "$value" =~ '^[A-Za-z0-9._-]+$' ]] || die "invalid release config value for $key"
      ;;
    signer_identity|signing_namespace)
      [[ "$value" =~ '^[A-Za-z0-9._@+-]+$' ]] || die "invalid release config value for $key"
      ;;
    fixed_archive_time)
      [[ "$value" =~ '^[0-9]+$' ]] || die "invalid release config value for $key"
      ;;
    *)
      die "unknown release config key: $key"
      ;;
  esac
}

load_release_conf() {
  local release_conf="$1"
  local line key value expected
  local index=1
  local -a expected_keys=(
    manifest_format
    project
    archive_project
    signer_identity
    signing_namespace
    fixed_archive_time
  )
  typeset -gA release_conf_values
  release_conf_values=()

  require_safe_existing_file "$release_conf" "release config"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "invalid release config line: $line"

    expected="${expected_keys[$index]-}"
    [[ -n "$expected" ]] || die "unexpected extra release config line: $line"

    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" == "$expected" ]] || die "unexpected release config field: $key"
    [[ -z "${release_conf_values[$key]-}" ]] || die "duplicate release config field: $key"
    validate_release_conf_value "$key" "$value"

    release_conf_values[$key]="$value"
    index=$((index + 1))
  done < "$release_conf"

  [[ "$index" -eq $(( ${#expected_keys[@]} + 1 )) ]] || die "release config is missing fields"

  typeset -g manifest_format="${release_conf_values[manifest_format]}"
  typeset -g project="${release_conf_values[project]}"
  typeset -g archive_project="${release_conf_values[archive_project]}"
  typeset -g signer_identity="${release_conf_values[signer_identity]}"
  typeset -g signing_namespace="${release_conf_values[signing_namespace]}"
  typeset -g fixed_archive_time="${release_conf_values[fixed_archive_time]}"
}
