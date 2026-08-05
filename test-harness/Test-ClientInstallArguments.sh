#!/usr/bin/env bash
# Regression coverage for deterministic client/install.sh argument parsing.

set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_ROOT/client/install.sh"
BASH_BIN=$(command -v bash)
if ! JQ_BIN=$(command -v jq); then
  printf 'jq is required to run this regression test.\n' >&2
  exit 1
fi
ORIGINAL_PATH=$PATH
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/newrelic-mcp-apim-args.XXXXXX")
FAKE_BIN="$TEMP_ROOT/bin"
FAKE_CALL_LOG="$TEMP_ROOT/prerequisite-calls.log"
failures=0
case_number=0

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

pass() {
  printf '  PASS  %s\n' "$1"
}

fail_test() {
  printf '  FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_equal() {
  local expected=$1
  local actual=$2
  local message=$3

  if [[ "$actual" == "$expected" ]]; then
    pass "$message"
  else
    fail_test "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local needle=$1
  local message=$2

  if [[ "$RUN_OUTPUT" == *"$needle"* ]]; then
    pass "$message"
  else
    fail_test "$message (output did not contain '$needle')"
  fi
}

assert_config_absent() {
  local message=$1

  if [[ ! -e "$RUN_CONFIG" ]]; then
    pass "$message"
  else
    fail_test "$message"
  fi
}

assert_prerequisites_not_run() {
  local message=$1

  if [[ ! -s "$FAKE_CALL_LOG" ]]; then
    pass "$message"
  else
    fail_test "$message"
  fi
}

prepare_case() {
  case_number=$((case_number + 1))
  RUN_HOME="$TEMP_ROOT/home-$case_number"
  RUN_CONFIG="$RUN_HOME/.claude.json"
  RUN_OUTPUT=
  RUN_STATUS=0
  mkdir -p "$RUN_HOME"
  : > "$FAKE_CALL_LOG"
}

invoke_installer() {
  RUN_OUTPUT=$(
    HOME="$RUN_HOME" \
      FAKE_CALL_LOG="$FAKE_CALL_LOG" \
      PATH="$FAKE_BIN:$ORIGINAL_PATH" \
      "$BASH_BIN" "$INSTALLER" "$@" 2>&1
  )
  RUN_STATUS=$?
}

run_installer() {
  prepare_case
  invoke_installer "$@"
}

run_check_case() {
  local description=$1
  local environment=$2
  shift 2

  run_installer "$@"
  assert_equal 0 "$RUN_STATUS" "$description exits successfully"
  assert_contains "env=$environment" "$description selects $environment"
  assert_contains "Check-only mode" "$description enables check-only mode"
  assert_config_absent "$description does not write configuration"
}

run_help_case() {
  local description=$1
  shift

  run_installer "$@"
  assert_equal 0 "$RUN_STATUS" "$description exits successfully"
  assert_contains "Usage:" "$description prints usage"
  assert_config_absent "$description does not write configuration"
  assert_prerequisites_not_run "$description exits before prerequisite commands"
}

run_invalid_case() {
  local description=$1
  local expected_error=$2
  shift 2

  prepare_case
  printf '{"preserved":true}\n' > "$RUN_CONFIG"
  local original_config
  original_config=$(<"$RUN_CONFIG")

  invoke_installer "$@"

  if [[ "$RUN_STATUS" -ne 0 ]]; then
    pass "$description fails"
  else
    fail_test "$description fails"
  fi
  assert_contains "$expected_error" "$description reports the parsing error"
  assert_equal "$original_config" "$(<"$RUN_CONFIG")" "$description leaves configuration unchanged"
  assert_prerequisites_not_run "$description exits before prerequisite commands"
}

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/az" <<'FAKE_AZ'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
case "$*" in
  "account show")
    printf '{}\n'
    ;;
  *"get-access-token"*)
    printf 'fake-token\n'
    ;;
esac
FAKE_AZ
cat > "$FAKE_BIN/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
FAKE_CLAUDE
ln -s "$JQ_BIN" "$FAKE_BIN/jq"
chmod +x "$FAKE_BIN/az" "$FAKE_BIN/claude"

printf 'Client installer argument parser regression tests\n'

run_check_case 'spaced env before long check' int --env int --check
run_check_case 'long check before spaced env' int --check --env int
run_check_case 'equals env before short check' int --env=int -c
run_check_case 'short check before equals env' dev -c --env=dev

run_installer --env int
assert_equal 0 "$RUN_STATUS" 'spaced env install exits successfully'
assert_equal \
  'https://api.int.amnhealthcare.io/ai/new-relic-mcp/int' \
  "$("$JQ_BIN" -r '.mcpServers.newrelic.url' "$RUN_CONFIG")" \
  'spaced env install writes the int endpoint'

run_installer --env=dev
assert_equal 0 "$RUN_STATUS" 'equals env install exits successfully'
assert_equal \
  'https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev' \
  "$("$JQ_BIN" -r '.mcpServers.newrelic.url' "$RUN_CONFIG")" \
  'equals env install writes the dev endpoint'

run_help_case 'long help alias' --help
run_help_case 'short help alias' -h
run_help_case 'help after valid env' --env int --help
run_help_case 'help before valid options' --help --env int --check

run_invalid_case 'missing spaced env value' '--env requires a value' --env
run_invalid_case 'option after env is not a value' '--env requires a value' --env --check
run_invalid_case 'empty equals env value' '--env requires a value' --env=
run_invalid_case 'empty spaced env value' '--env requires a value' --env ''
run_invalid_case 'invalid spaced env value' 'invalid --env: prod' --env prod
run_invalid_case 'invalid equals env value' 'invalid --env: prod' --env=prod
run_invalid_case 'unknown long option' 'unknown option: --unknown' --unknown
run_invalid_case 'unknown short option' 'unknown option: -x' -x
run_invalid_case 'positional garbage' 'unexpected argument: garbage' garbage
run_invalid_case 'garbage after valid option' 'unexpected argument: garbage' --check garbage

printf '\n'
if [[ $failures -eq 0 ]]; then
  printf 'CLIENT INSTALL ARGUMENT TESTS PASSED\n'
  exit 0
fi

printf 'CLIENT INSTALL ARGUMENT TESTS FAILED (%d failure(s))\n' "$failures" >&2
exit 1
