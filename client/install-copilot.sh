#!/usr/bin/env bash
# Installs the APIM-fronted New Relic MCP for GitHub Copilot CLI/App.

set -euo pipefail

CHECK_ONLY=0
FORCE=0
ENV_NAME="dev"
NR_MCP_APP_ID="api://709bbe94-f759-422f-b7fa-28f1fde28ae1"
ASSET_REF="3a4e3ddd184f7b9fae6f29328b04ee4932002256"
RAW_BASE="https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/${ASSET_REF}/client/copilot"

info() { printf '  %s\n' "$*"; }
ok() { printf '[ok] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
fail() { printf '[error] %s\n' "$*" >&2; }

expected_hash() {
  case "$1" in
    bridge.mjs) printf '%s' '9aebe36f9e378a97238828b2044d929e7e61b420a51277e9ed24a3429ad02cc9' ;;
    auth.mjs) printf '%s' 'ffc4c24921c446099873363f09f75fc080e1f4a8b27d1cf707df3ddb7b6da4e2' ;;
    azure-cli.mjs) printf '%s' '5dab75efa0d631ff9b03b3dcc55546b48899b06c92c56d90391e275e90054833' ;;
    package.json) printf '%s' 'd970c21eed2ffdd38a3b177bc53febb64bcdf1021c46c631597ad0f966f2fee9' ;;
    package-lock.copilot) printf '%s' '5678872d626f239d3b7ba51a16d1ca1ae7e207d9cfdcf0912104d0e0fc1099f4' ;;
    *) fail "No checksum is registered for $1."; exit 1 ;;
  esac
}

verify_asset() {
  local path=$1
  local name=$2
  local expected
  local actual
  expected=$(expected_hash "$name")
  actual=$("$NODE_PATH" -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$path")
  if [[ "$actual" != "$expected" ]]; then
    fail "Checksum verification failed for $name."
    exit 1
  fi
}

usage() {
  cat <<'HELP'
Install the APIM-fronted New Relic MCP for GitHub Copilot CLI and App.

Usage:
  install-copilot.sh [--env dev|int] [--check] [--force]

Options:
  --env dev|int  Select the APIM environment (default: dev).
  --check, -c    Validate and report without modifying files.
  --force, -f    Replace an existing newrelic MCP entry without prompting.
  --help, -h     Show this help.
HELP
}

while (($#)); do
  case "$1" in
    --check|-c)
      CHECK_ONLY=1
      shift
      ;;
    --force|-f)
      FORCE=1
      shift
      ;;
    --env)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        fail "--env requires a value (allowed: dev, int)"
        exit 1
      fi
      ENV_NAME="$2"
      shift 2
      ;;
    --env=*)
      ENV_NAME="${1#--env=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      exit 1
      ;;
    *)
      fail "unexpected argument: $1"
      exit 1
      ;;
  esac
done

case "$ENV_NAME" in
  dev|int) ;;
  *)
    fail "invalid --env: $ENV_NAME (allowed: dev, int)"
    exit 1
    ;;
esac

for command_name in az node npm jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "$command_name is required and was not found on PATH."
    exit 1
  fi
done

NODE_MAJOR=$(node -p 'Number(process.versions.node.split(".")[0])')
if [[ "$NODE_MAJOR" -lt 20 ]]; then
  fail "Node.js 20 or newer is required (found $(node --version))."
  exit 1
fi

NODE_PATH=$(command -v node)
AZ_PATH=$(command -v az)
COPILOT_ROOT="${COPILOT_HOME:-${HOME}/.copilot}"
CONFIG_FILE="${COPILOT_ROOT}/mcp-config.json"
INSTALL_DIR="${COPILOT_ROOT}/servers/newrelic-apim"
MCP_URL="https://api.${ENV_NAME}.amnhealthcare.io/ai/new-relic-mcp/${ENV_NAME}"

ENTRY=$(jq -n \
  --arg node "$NODE_PATH" \
  --arg bridge "${INSTALL_DIR}/bridge.mjs" \
  --arg url "$MCP_URL" \
  --arg audience "$NR_MCP_APP_ID" \
  --arg az "$AZ_PATH" \
  '{
    type: "stdio",
    command: $node,
    args: [
      $bridge,
      "--url", $url,
      "--audience", $audience,
      "--az-path", $az
    ],
    tools: ["*"]
  }')

info "Copilot config: $CONFIG_FILE"
info "Bridge install: $INSTALL_DIR"
info "Endpoint: $MCP_URL"

if ! az account show >/dev/null 2>&1; then
  warn "No active Azure CLI session. Run 'az login' before using New Relic."
elif [[ "$CHECK_ONLY" -eq 0 ]]; then
  if az account get-access-token \
    --resource "$NR_MCP_APP_ID" \
    --query accessToken \
    --output tsv \
    --only-show-errors >/dev/null 2>&1; then
    ok "Entra token acquisition succeeded."
  else
    warn "Token acquisition failed. Verify Azure login and AZ_JobRole_Observability_NewRelicMcp_User membership."
  fi
fi

if [[ -f "$CONFIG_FILE" ]]; then
  if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    fail "$CONFIG_FILE is not valid JSON; refusing to modify it."
    exit 1
  fi
  if ! jq -e 'type == "object" and ((.mcpServers? == null) or (.mcpServers | type == "object"))' "$CONFIG_FILE" >/dev/null; then
    fail "$CONFIG_FILE must contain a JSON object with an optional mcpServers object."
    exit 1
  fi
  EXISTING=$(jq -c '.mcpServers.newrelic // empty' "$CONFIG_FILE")
  if [[ -n "$EXISTING" && "$(jq -cS . <<<"$EXISTING")" != "$(jq -cS . <<<"$ENTRY")" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
      warn "A different mcpServers.newrelic entry exists and would be replaced."
    elif [[ "$FORCE" -ne 1 ]]; then
      warn "A different mcpServers.newrelic entry already exists."
      printf 'Replace it with the APIM Copilot bridge? (y/N) '
      if [[ ! -r /dev/tty ]]; then
        fail "Cannot prompt without a terminal. Re-run interactively or pass --force."
        exit 1
      fi
      read -r response </dev/tty
      case "$response" in
        y|Y|yes|YES|Yes) ;;
        *)
          info "Aborted."
          exit 0
          ;;
      esac
    fi
  fi
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  ok "Check-only mode; no files changed."
  printf '%s\n' "$ENTRY" | sed 's/^/    /'
  exit 0
fi

mkdir -p "$COPILOT_ROOT" "${COPILOT_ROOT}/servers"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SOURCE_DIR=
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != /dev/fd/* && "$SCRIPT_SOURCE" != /proc/self/fd/* && -f "$SCRIPT_SOURCE" ]]; then
  SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)
  SOURCE_DIR="${SCRIPT_DIR}/copilot"
fi
TEMP_DIR=
STAGING_DIR=$(mktemp -d "${COPILOT_ROOT}/servers/.newrelic-apim-install.XXXXXX")
CONFIG_TMP="${COPILOT_ROOT}/.mcp-config.install.$$"
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
  rm -f "$CONFIG_TMP"
}
trap cleanup EXIT

if [[ -n "$SOURCE_DIR" && -f "${SOURCE_DIR}/bridge.mjs" && -f "${SOURCE_DIR}/auth.mjs" && -f "${SOURCE_DIR}/azure-cli.mjs" && -f "${SOURCE_DIR}/package.json" && -f "${SOURCE_DIR}/package-lock.copilot" ]]; then
  for asset in bridge.mjs auth.mjs azure-cli.mjs package.json package-lock.copilot; do
    verify_asset "${SOURCE_DIR}/${asset}" "$asset"
  done
  cp "${SOURCE_DIR}/bridge.mjs" "${SOURCE_DIR}/auth.mjs" "${SOURCE_DIR}/azure-cli.mjs" "${SOURCE_DIR}/package.json" "$STAGING_DIR/"
  cp "${SOURCE_DIR}/package-lock.copilot" "${STAGING_DIR}/package-lock.json"
else
  if ! command -v curl >/dev/null 2>&1; then
    fail "curl is required when the installer is not run from a repository clone."
    exit 1
  fi
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/newrelic-copilot.XXXXXX")
  for asset in bridge.mjs auth.mjs azure-cli.mjs package.json package-lock.copilot; do
    curl -fsSL "${RAW_BASE}/${asset}" -o "${TEMP_DIR}/${asset}"
    verify_asset "${TEMP_DIR}/${asset}" "$asset"
  done
  cp "${TEMP_DIR}/bridge.mjs" "${TEMP_DIR}/auth.mjs" "${TEMP_DIR}/azure-cli.mjs" "${TEMP_DIR}/package.json" "$STAGING_DIR/"
  cp "${TEMP_DIR}/package-lock.copilot" "${STAGING_DIR}/package-lock.json"
fi

npm ci \
  --prefix "$STAGING_DIR" \
  --omit=dev \
  --ignore-scripts \
  --no-audit \
  --no-fund \
  --silent

if [[ -f "$CONFIG_FILE" ]]; then
  jq --argjson entry "$ENTRY" \
    '.mcpServers = ((.mcpServers // {}) | .newrelic = $entry)' \
    "$CONFIG_FILE" > "$CONFIG_TMP"
else
  jq --argjson entry "$ENTRY" -n \
    '{mcpServers: {newrelic: $entry}}' > "$CONFIG_TMP"
fi
jq empty "$CONFIG_TMP" >/dev/null
chmod 600 "$CONFIG_TMP"

BACKUP=
if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP"
  chmod 600 "$BACKUP"
fi

PREVIOUS_DIR=
if [[ -d "$INSTALL_DIR" ]]; then
  PREVIOUS_DIR="${INSTALL_DIR}.previous-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$INSTALL_DIR" "$PREVIOUS_DIR"
fi

if ! mv "$STAGING_DIR" "$INSTALL_DIR"; then
  [[ -n "$PREVIOUS_DIR" && -d "$PREVIOUS_DIR" ]] && mv "$PREVIOUS_DIR" "$INSTALL_DIR"
  fail "Failed to activate the staged bridge."
  exit 1
fi
STAGING_DIR=

if ! mv "$CONFIG_TMP" "$CONFIG_FILE"; then
  rm -rf "$INSTALL_DIR"
  [[ -n "$PREVIOUS_DIR" && -d "$PREVIOUS_DIR" ]] && mv "$PREVIOUS_DIR" "$INSTALL_DIR"
  fail "Failed to activate the Copilot MCP configuration."
  exit 1
fi

[[ -n "$PREVIOUS_DIR" && -d "$PREVIOUS_DIR" ]] && rm -rf "$PREVIOUS_DIR"
ok "Installed the version-pinned local MCP bridge."
[[ -n "$BACKUP" ]] && ok "Backed up the previous configuration to $BACKUP."
ok "Configured New Relic for Copilot CLI, Copilot App, and VS Code Agent Host."
info "Start a new Copilot session, then run '/mcp show newrelic'."
