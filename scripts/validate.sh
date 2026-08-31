#!/usr/bin/env bash

set -Eeuo pipefail

readonly release_base_url="https://github.com/ingitdb/ingitdb-cli/releases/download"
readonly minimum_cli_version="v0.65.13"
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
readonly started_at
readonly cli_version="${INPUT_CLI_VERSION:-}"
readonly database_root_input="${INPUT_DATABASE_ROOT:-.}"
readonly action_revision="${INGITDB_ACTION_REF:-unknown}"
readonly validated_commit="${GITHUB_SHA:-unknown}"

database_root_output=""

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

finish() {
  trap - ERR
  local category="$1"
  local exit_status="$2"
  local message="$3"
  local completed_at
  completed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  write_output terminal_category "$category"
  write_output cli_version "$cli_version"
  write_output database_root "$database_root_output"
  write_output validated_commit "$validated_commit"
  write_output action_revision "$action_revision"
  write_output started_at "$started_at"
  write_output completed_at "$completed_at"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### InGitDB repository validation\n\n'
      printf -- "- Terminal category: \`%s\`\n" "$category"
      printf -- "- InGitDB CLI: \`%s\`\n" "$cli_version"
      printf -- "- Database root: \`%s\`\n" "${database_root_output:-unresolved}"
      printf -- "- Validated commit: \`%s\`\n" "$validated_commit"
      printf -- "- Action revision: \`%s\`\n" "$action_revision"
      printf -- "- Started: \`%s\`\n" "$started_at"
      printf -- "- Completed: \`%s\`\n" "$completed_at"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ "$exit_status" -eq 0 ]]; then
    printf '::notice title=InGitDB validation::%s\n' "$message"
  else
    printf '::error title=InGitDB validation (%s)::%s\n' "$category" "$message" >&2
  fi
  exit "$exit_status"
}

# shellcheck disable=SC2329 # Invoked indirectly by the ERR trap.
unexpected_failure() {
  local status="$?"
  if [[ "$status" -eq 0 ]]; then
    status=1
  fi
  finish internal_error "$status" "the validation action failed unexpectedly"
}

trap unexpected_failure ERR

validate_archive_members() {
  local candidate_archive="$1"
  local member_list
  local verbose_list
  local executable_count=0
  local regular_executable_count

  if ! member_list="$(tar --list --gzip --file "$candidate_archive")"; then
    return 1
  fi
  while IFS= read -r member; do
    case "$member" in
      ingitdb)
        executable_count=$((executable_count + 1))
        ;;
      README.md|LICENSE|LICENSE.*)
        ;;
      *)
        return 1
        ;;
    esac
  done <<< "$member_list"
  if [[ "$executable_count" -ne 1 ]]; then
    return 1
  fi

  if ! verbose_list="$(tar --list --verbose --gzip --file "$candidate_archive")"; then
    return 1
  fi
  regular_executable_count="$(awk '$1 ~ /^-/ && $NF == "ingitdb" { count++ } END { print count+0 }' <<< "$verbose_list")"
  [[ "$regular_executable_count" == "1" ]]
}

emit_validator_log() {
  local validator_log="$1"
  if [[ ! -s "$validator_log" ]]; then
    return
  fi
  local stop_token="ingitdb_${RANDOM}_${RANDOM}_$$"
  printf '::stop-commands::%s\n' "$stop_token"
  cat "$validator_log"
  printf '::%s::\n' "$stop_token"
}

if [[ ! "$cli_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  finish configuration_error 1 "cli-version must be an exact stable ingitdb/ingitdb-cli release tag such as v0.65.13"
fi
version_number="${cli_version#v}"
IFS='.' read -r version_major version_minor version_patch <<< "$version_number"
if (( 10#$version_major == 0 && (10#$version_minor < 65 || (10#$version_minor == 65 && 10#$version_patch < 13)) )); then
  finish configuration_error 1 "cli-version must be ${minimum_cli_version} or newer because earlier releases do not provide the required safe validation protocol"
fi

if [[ -z "${GITHUB_WORKSPACE:-}" || ! -d "$GITHUB_WORKSPACE" ]]; then
  finish configuration_error 1 "GITHUB_WORKSPACE must name the checked-out repository"
fi

if [[ ! "$database_root_input" =~ ^[A-Za-z0-9._/-]+$ || "$database_root_input" == /* ]]; then
  finish configuration_error 1 "database-root must be a repository-relative path containing only letters, numbers, dot, underscore, dash, and slash"
fi

IFS='/' read -r -a database_root_parts <<< "$database_root_input"
for path_part in "${database_root_parts[@]}"; do
  if [[ -z "$path_part" || "$path_part" == ".." ]]; then
    finish configuration_error 1 "database-root must not contain empty or parent-directory path segments"
  fi
done

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
  Linux/X64)
    release_os="linux"
    release_arch="amd64"
    ;;
  *)
    runner_pair="${RUNNER_OS:-unknown}/${RUNNER_ARCH:-unknown}"
    finish unsupported_runner 1 "unsupported runner ${runner_pair}; the exercised first release supports GitHub-hosted Ubuntu amd64 only"
    ;;
esac

if ! workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"; then
  finish configuration_error 1 "GITHUB_WORKSPACE could not be canonicalized"
fi
root_candidate="$workspace/$database_root_input"
if ! root_path="$(cd "$root_candidate" && pwd -P)"; then
  finish configuration_error 1 "database-root does not exist in the checked-out repository"
fi

case "$root_path" in
  "$workspace")
    database_root_output="."
    ;;
  "$workspace"/*)
    database_root_output="${root_path#"$workspace"/}"
    ;;
  *)
    finish configuration_error 1 "database-root resolves outside the checked-out repository"
    ;;
esac
if [[ ! "$database_root_output" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  database_root_output=""
  finish configuration_error 1 "database-root resolves to a path that cannot be represented safely in GitHub Action output"
fi

if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
  finish configuration_error 1 "RUNNER_TEMP must name an existing runner-temporary directory"
fi

if ! tool_dir="$(mktemp -d "${RUNNER_TEMP%/}/ingitdb-action.XXXXXX")"; then
  finish installation_error 1 "could not create the temporary InGitDB CLI directory"
fi

archive="ingitdb_${version_number}_${release_os}_${release_arch}.tar.gz"
archive_path="$tool_dir/$archive"
checksums_path="$tool_dir/checksums.txt"
release_url="$release_base_url/$cli_version"

printf 'InGitDB action revision: %s\n' "$action_revision"
printf 'InGitDB CLI release: %s\n' "$cli_version"
printf 'Database root: %s\n' "$database_root_output"
printf 'Validated commit: %s\n' "$validated_commit"
printf 'Validation started: %s\n' "$started_at"

if ! curl --fail --silent --show-error --location "$release_url/$archive" --output "$archive_path"; then
  finish download_error 1 "failed to download the exact InGitDB CLI archive from ingitdb/ingitdb-cli"
fi
if ! curl --fail --silent --show-error --location "$release_url/checksums.txt" --output "$checksums_path"; then
  finish download_error 1 "failed to download checksums for the exact InGitDB CLI release"
fi

expected_checksum_path="$tool_dir/expected.sha256"
if ! awk -v asset="$archive" '{ name=$2; sub(/^\*/, "", name); if (name == asset) print $1 "  " asset }' "$checksums_path" > "$expected_checksum_path"; then
  finish checksum_error 1 "could not parse the InGitDB CLI checksum manifest"
fi
checksum_line_count="$(wc -l < "$expected_checksum_path")"
checksum_line_count="${checksum_line_count//[[:space:]]/}"
if [[ "$checksum_line_count" != "1" ]]; then
  finish checksum_error 1 "the checksum manifest must contain exactly one entry for the selected archive"
fi
expected_hash="$(cut -d ' ' -f 1 "$expected_checksum_path")"
if [[ ! "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
  finish checksum_error 1 "the selected archive checksum is malformed"
fi
expected_checksum_name="$(basename "$expected_checksum_path")"
if ! (cd "$tool_dir" && sha256sum --check --strict "$expected_checksum_name"); then
  finish checksum_error 1 "the InGitDB CLI archive checksum does not match the published manifest"
fi

if ! validate_archive_members "$archive_path"; then
  finish extraction_error 1 "the verified archive contains an unsafe or unexpected member"
fi
if ! tar --extract --gzip --file "$archive_path" --directory "$tool_dir" ingitdb; then
  finish extraction_error 1 "the verified InGitDB CLI archive could not be extracted"
fi
cli_path="$tool_dir/ingitdb"
if [[ ! -f "$cli_path" || -L "$cli_path" ]]; then
  finish extraction_error 1 "the verified archive does not contain a regular InGitDB CLI executable"
fi
if ! chmod 0700 "$cli_path"; then
  finish extraction_error 1 "the InGitDB CLI executable could not be prepared"
fi

validator_log="$tool_dir/validator.log"
if "$cli_path" validate --path="$root_path" --safe-diagnostics > "$validator_log" 2>&1; then
  validator_status=0
else
  validator_status=$?
fi
case "$validator_status" in
  0)
    emit_validator_log "$validator_log"
    finish success 0 "the complete InGitDB repository is valid"
    ;;
  2)
    emit_validator_log "$validator_log"
    finish invalid_data 2 "the InGitDB CLI found invalid repository data"
    ;;
  *)
    finish validator_error "$validator_status" "the InGitDB validator could not complete"
    ;;
esac
