#!/usr/bin/env bash

set -euo pipefail

action_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly action_root
test_root="$(mktemp -d)"
readonly test_root
readonly original_path="$PATH"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local want="$1"
  local got="$2"
  local label="$3"
  [[ "$got" == "$want" ]] || fail "$label: got [$got], want [$want]"
}

assert_contains() {
  local text="$1"
  local want="$2"
  local label="$3"
  [[ "$text" == *"$want"* ]] || fail "$label: missing [$want] in [$text]"
}

assert_not_contains() {
  local text="$1"
  local forbidden="$2"
  local label="$3"
  [[ "$text" != *"$forbidden"* ]] || fail "$label: found forbidden [$forbidden] in [$text]"
}

output_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { value=$0; sub(/^[^=]*=/, "", value); print value }' "$GITHUB_OUTPUT" | tail -1
}

setup_case() {
  local name="$1"
  case_root="$test_root/$name"
  mkdir -p "$case_root/workspace/.ingitdb" "$case_root/runner" "$case_root/release" "$case_root/fake-bin"
  printf 'fixture\n' > "$case_root/workspace/data.txt"
  git -C "$case_root/workspace" init --quiet
  git -C "$case_root/workspace" add .
  git -C "$case_root/workspace" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m fixture

  cat > "$case_root/fake-ingitdb" <<'FAKE_CLI'
#!/usr/bin/env bash
set -u
if [[ -n "${TEST_EXEC_MARKER:-}" ]]; then
  : > "$TEST_EXEC_MARKER"
fi
printf '%s\n' "${FAKE_CLI_OUTPUT:-}" >&2
exit "${FAKE_CLI_STATUS:-0}"
FAKE_CLI
  chmod 0700 "$case_root/fake-ingitdb"
  cp "$case_root/fake-ingitdb" "$case_root/release/ingitdb"
  tar --create --gzip --file "$case_root/release/ingitdb_9.8.7_linux_amd64.tar.gz" --directory "$case_root/release" ingitdb
  (cd "$case_root/release" && sha256sum ingitdb_9.8.7_linux_amd64.tar.gz > checksums.txt)

  cat > "$case_root/fake-bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CURL_LOG"
if [[ "${TEST_CURL_FAIL:-0}" == "1" ]]; then
  exit 22
fi
url=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --fail|--silent|--show-error|--location)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
asset="${url##*/}"
cp "$TEST_RELEASE_DIR/$asset" "$output"
FAKE_CURL
  chmod 0700 "$case_root/fake-bin/curl"

  export INPUT_CLI_VERSION="v9.8.7"
  export INPUT_DATABASE_ROOT="."
  export GITHUB_WORKSPACE="$case_root/workspace"
  export RUNNER_TEMP="$case_root/runner"
  export RUNNER_OS="Linux"
  export RUNNER_ARCH="X64"
  export GITHUB_SHA="0123456789012345678901234567890123456789"
  export INGITDB_ACTION_REF="abcdefabcdefabcdefabcdefabcdefabcdefabcd"
  export GITHUB_OUTPUT="$case_root/github-output"
  export GITHUB_STEP_SUMMARY="$case_root/summary"
  export TEST_RELEASE_DIR="$case_root/release"
  export TEST_CURL_LOG="$case_root/curl.log"
  export TEST_EXEC_MARKER="$case_root/executed"
  export TEST_CURL_FAIL="0"
  export FAKE_CLI_STATUS="0"
  export FAKE_CLI_OUTPUT="repository validation passed"
  export PATH="$case_root/fake-bin:$original_path"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

run_action() {
  set +e
  run_output="$(bash "$action_root/scripts/validate.sh" 2>&1)"
  run_status=$?
  set -e
}

setup_case success
before_hash="$(sha256sum "$GITHUB_WORKSPACE/data.txt")"
run_action
after_hash="$(sha256sum "$GITHUB_WORKSPACE/data.txt")"
assert_eq "0" "$run_status" "success exit"
success_category="$(output_value terminal_category)"
assert_eq "success" "$success_category" "success category"
success_root="$(output_value database_root)"
assert_eq "." "$success_root" "canonical root"
assert_eq "$before_hash" "$after_hash" "workspace content"
workspace_status="$(git -C "$GITHUB_WORKSPACE" status --porcelain)"
assert_eq "" "$workspace_status" "Git worktree cleanliness"
assert_contains "$run_output" "InGitDB CLI release: v9.8.7" "identity log"
assert_not_contains "$run_output" "$GITHUB_WORKSPACE" "absolute workspace leakage"
curl_log="$(cat "$TEST_CURL_LOG")"
assert_contains "$curl_log" "github.com/ingitdb/ingitdb-cli/releases/download/v9.8.7" "canonical release source"
assert_not_contains "$curl_log" "ingitdb/ingitdb-go" "obsolete release source"

setup_case invalid-data
export FAKE_CLI_STATUS="2"
export FAKE_CLI_OUTPUT='collection "spaces": file "sneat/spaces/space-1/space.yaml": record "space-1": field "token": enum constraint failed'
run_action
assert_eq "2" "$run_status" "invalid-data exit"
invalid_category="$(output_value terminal_category)"
assert_eq "invalid_data" "$invalid_category" "invalid-data category"
assert_contains "$run_output" "enum constraint failed" "safe finding"
assert_not_contains "$run_output" "github_pat_secret_value" "record value leakage"

setup_case workflow-command-output
export FAKE_CLI_STATUS="2"
export FAKE_CLI_OUTPUT=$'collection "spaces": validation constraint failed\n::warning::must not execute as a workflow command'
run_action
assert_eq "2" "$run_status" "workflow command output exit"
assert_contains "$run_output" "::stop-commands::ingitdb_" "workflow command suppression"
assert_contains "$run_output" "must not execute as a workflow command" "suppressed validator text"

setup_case checksum-mismatch
printf 'tamper\n' >> "$TEST_RELEASE_DIR/ingitdb_9.8.7_linux_amd64.tar.gz"
run_action
assert_eq "1" "$run_status" "checksum exit"
checksum_category="$(output_value terminal_category)"
assert_eq "checksum_error" "$checksum_category" "checksum category"
[[ ! -e "$TEST_EXEC_MARKER" ]] || fail "checksum mismatch executed the CLI"

setup_case duplicate-checksum
cat "$TEST_RELEASE_DIR/checksums.txt" >> "$TEST_RELEASE_DIR/checksums.txt.copy"
cat "$TEST_RELEASE_DIR/checksums.txt.copy" >> "$TEST_RELEASE_DIR/checksums.txt"
run_action
assert_eq "1" "$run_status" "duplicate checksum exit"
duplicate_checksum_category="$(output_value terminal_category)"
assert_eq "checksum_error" "$duplicate_checksum_category" "duplicate checksum category"
[[ ! -e "$TEST_EXEC_MARKER" ]] || fail "duplicate checksum executed the CLI"

setup_case unsafe-archive
mv "$TEST_RELEASE_DIR/ingitdb" "$TEST_RELEASE_DIR/real-ingitdb"
ln -s /bin/echo "$TEST_RELEASE_DIR/ingitdb"
tar --create --gzip --file "$TEST_RELEASE_DIR/ingitdb_9.8.7_linux_amd64.tar.gz" --directory "$TEST_RELEASE_DIR" ingitdb
(cd "$TEST_RELEASE_DIR" && sha256sum ingitdb_9.8.7_linux_amd64.tar.gz > checksums.txt)
run_action
assert_eq "1" "$run_status" "unsafe archive exit"
unsafe_archive_category="$(output_value terminal_category)"
assert_eq "extraction_error" "$unsafe_archive_category" "unsafe archive category"
[[ ! -e "$TEST_EXEC_MARKER" ]] || fail "unsafe archive executed the CLI"

setup_case unsupported-runner
export RUNNER_OS="macOS"
export RUNNER_ARCH="ARM64"
run_action
assert_eq "1" "$run_status" "unsupported runner exit"
runner_category="$(output_value terminal_category)"
assert_eq "unsupported_runner" "$runner_category" "unsupported runner category"
[[ ! -e "$TEST_CURL_LOG" ]] || fail "unsupported runner attempted a download"

setup_case injection
injection_marker="$case_root/injected"
export INPUT_DATABASE_ROOT="\$(touch $injection_marker)"
run_action
assert_eq "1" "$run_status" "injection exit"
injection_category="$(output_value terminal_category)"
assert_eq "configuration_error" "$injection_category" "injection category"
[[ ! -e "$injection_marker" ]] || fail "database-root input executed a command"
[[ ! -e "$TEST_CURL_LOG" ]] || fail "invalid input attempted a download"

setup_case symlink-escape
mkdir -p "$case_root/outside"
ln -s "$case_root/outside" "$GITHUB_WORKSPACE/linked-root"
export INPUT_DATABASE_ROOT="linked-root"
run_action
assert_eq "1" "$run_status" "symlink escape exit"
symlink_escape_category="$(output_value terminal_category)"
assert_eq "configuration_error" "$symlink_escape_category" "symlink escape category"
[[ ! -e "$TEST_CURL_LOG" ]] || fail "symlink escape attempted a download"

setup_case newline-target
newline_directory="$GITHUB_WORKSPACE/line"$'\n'"break"
mkdir -p "$newline_directory"
ln -s "$newline_directory" "$GITHUB_WORKSPACE/linked-root"
export INPUT_DATABASE_ROOT="linked-root"
run_action
assert_eq "1" "$run_status" "newline target exit"
newline_category="$(output_value terminal_category)"
assert_eq "configuration_error" "$newline_category" "newline target category"
output_line_count="$(wc -l < "$GITHUB_OUTPUT")"
output_line_count="${output_line_count//[[:space:]]/}"
assert_eq "7" "$output_line_count" "newline-safe output record count"

setup_case missing-version
export INPUT_CLI_VERSION=""
run_action
assert_eq "1" "$run_status" "missing version exit"
version_category="$(output_value terminal_category)"
assert_eq "configuration_error" "$version_category" "missing version category"
[[ ! -e "$TEST_CURL_LOG" ]] || fail "missing version attempted a download"

setup_case unsupported-cli-protocol
export INPUT_CLI_VERSION="v0.65.12"
run_action
assert_eq "1" "$run_status" "unsupported CLI protocol exit"
protocol_category="$(output_value terminal_category)"
assert_eq "configuration_error" "$protocol_category" "unsupported CLI protocol category"
[[ ! -e "$TEST_CURL_LOG" ]] || fail "unsupported CLI protocol attempted a download"

setup_case download-failure
export TEST_CURL_FAIL="1"
run_action
assert_eq "1" "$run_status" "download failure exit"
download_category="$(output_value terminal_category)"
assert_eq "download_error" "$download_category" "download failure category"
[[ ! -e "$TEST_EXEC_MARKER" ]] || fail "download failure executed the CLI"

setup_case validator-error
export FAKE_CLI_STATUS="7"
export FAKE_CLI_OUTPUT="validator startup failed"
run_action
assert_eq "7" "$run_status" "validator exit propagation"
validator_category="$(output_value terminal_category)"
assert_eq "validator_error" "$validator_category" "validator category"

printf 'All repository validation action tests passed.\n'
