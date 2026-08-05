#!/usr/bin/env bash
# client/install.sh — add the APIM-fronted New Relic MCP to Claude Code.
#
# Merges a `newrelic` server entry into ~/.claude.json using the
# headersHelper pattern — az mints an Entra bearer on connection/reconnect and
# after a 401/403, APIM validates it + injects the KV-stored NerdGraph key
# server-side. No NR key on disk.
#
# For AMN engineers on the APIM Claude Code path. SSO / Anthropic-direct users
# should install from AMNEngineering/newrelic-mcp-sso instead.
#
# Idempotent: re-running is a no-op. Use --check to validate without modifying.

set -euo pipefail

# ------ ui helpers ------
c_ok='\033[32m'; c_warn='\033[33m'; c_fail='\033[31m'; c_head='\033[36m'; c_reset='\033[0m'
ok()   { printf "${c_ok}✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}!${c_reset} %s\n" "$*"; }
fail() { printf "${c_fail}✗${c_reset} %s\n" "$*" 1>&2; }
info() { printf "  %s\n" "$*"; }
head() { printf "\n${c_head}== %s ==${c_reset}\n" "$*"; }

# ------ args ------
CHECK_ONLY=0
ENV_NAME="dev"
NR_MCP_APP_ID="api://709bbe94-f759-422f-b7fa-28f1fde28ae1"

while (($#)); do
  case "$1" in
    --check|-c)
      CHECK_ONLY=1
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
      if [[ -z "$ENV_NAME" ]]; then
        fail "--env requires a value (allowed: dev, int)"
        exit 1
      fi
      shift
      ;;
    --help|-h)
      cat <<'HELP'
client/install.sh — add APIM-fronted New Relic MCP to Claude Code.

Usage:
  install.sh                      Install for dev (default).
  install.sh --env int            Install for int environment.
  install.sh --env=int            Install for int environment.
  install.sh --check              Validate + report only, no modifications.
  install.sh --help               Show this help.

Environments:  dev, int
HELP
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
  dev|int) : ;;
  *) fail "invalid --env: $ENV_NAME (allowed: dev, int)"; exit 1 ;;
esac

MCP_URL="https://api.${ENV_NAME}.amnhealthcare.io/ai/new-relic-mcp/${ENV_NAME}"
HEADERS_HELPER_COMMAND="az account get-access-token --resource \"$NR_MCP_APP_ID\" --query \"{Authorization: join(' ', ['Bearer', accessToken])}\" -o json"

head "New Relic MCP — APIM install (env=$ENV_NAME)"

# ------ locate config file ------
CFG_FILE="${HOME}/.claude.json"

# ------ prereq check: Claude Code CLI ------
if ! command -v claude >/dev/null 2>&1; then
  warn "'claude' CLI not found on PATH. Install Claude Code first (see AMNEngineering/amn-claude-code-client)."
fi

# ------ prereq check: az ------
if ! command -v az >/dev/null 2>&1; then
  fail "Azure CLI (az) is required for the headersHelper token acquisition. Install: brew install azure-cli  (macOS) / winget install Microsoft.AzureCLI  (Windows)."
  exit 1
fi
ok "az on PATH"

# ------ prereq check: active az session ------
if ! az account show >/dev/null 2>&1; then
  warn "no active 'az' session. Run 'az login' before Claude Code starts (the APIM client bootstrap does this)."
else
  ok "active az session detected"
fi

# ------ prereq check: token acquisition works ------
if [[ $CHECK_ONLY -eq 0 ]]; then
  info "Testing token acquisition against $NR_MCP_APP_ID..."
  if TOKEN=$(az account get-access-token --resource "$NR_MCP_APP_ID" --query accessToken -o tsv 2>&1); then
    if [[ -n "$TOKEN" && "$TOKEN" != *"ERROR"* ]]; then
      ok "Entra token acquired successfully (${#TOKEN} chars)"
      unset TOKEN
    else
      warn "token acquisition returned empty/error. Membership in AZ_JobRole_Observability_NewRelicMcp_User is required."
      info "Continuing install; you can fix the group membership later."
    fi
  else
    warn "token acquisition failed. Membership in AZ_JobRole_Observability_NewRelicMcp_User is required."
    info "Continuing install; you can fix the group membership later."
  fi
fi

# ------ prereq check: jq ------
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for a safe non-destructive merge. Install: brew install jq  (macOS) / apt install jq  (Debian)."
  exit 1
fi

# ------ current state ------
if [[ -f "$CFG_FILE" ]]; then
  info "Found existing $CFG_FILE"
  if jq empty "$CFG_FILE" >/dev/null 2>&1; then
    ok "existing config is valid JSON"
  else
    fail "existing $CFG_FILE is not valid JSON — refusing to touch it. Fix or move aside and re-run."
    exit 1
  fi
  HAS_NEWRELIC=$(jq -r '.mcpServers.newrelic // empty | if . == "" then "no" else "yes" end' "$CFG_FILE" 2>/dev/null || echo "no")
  if [[ "$HAS_NEWRELIC" == "yes" ]]; then
    warn "an 'newrelic' MCP entry already exists in $CFG_FILE."
    info "Current entry:"
    jq '.mcpServers.newrelic' "$CFG_FILE" | sed 's/^/    /'
    if [[ $CHECK_ONLY -eq 1 ]]; then
      info "Check-only: no changes made."
      exit 0
    fi
    info "This installer will OVERWRITE the existing 'newrelic' entry with the APIM/headersHelper config."
    printf "Continue? (y/N) "
    read -r resp
    case "$resp" in [yY]|[yY][eE][sS]) : ;; *) info "Aborted."; exit 0 ;; esac
  fi
fi

# ------ the APIM/headersHelper entry ------
NEWRELIC_ENTRY=$(jq -n \
  --arg url "$MCP_URL" \
  --arg headersHelper "$HEADERS_HELPER_COMMAND" \
  '{type: "http", url: $url, headersHelper: $headersHelper}')

if [[ $CHECK_ONLY -eq 1 ]]; then
  ok "Check-only mode. Would merge this into $CFG_FILE:"
  echo "$NEWRELIC_ENTRY" | sed 's/^/    /'
  exit 0
fi

# ------ backup ------
if [[ -f "$CFG_FILE" ]]; then
  BACKUP="${CFG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CFG_FILE" "$BACKUP"
  ok "backed up existing config → $BACKUP"
fi

# ------ merge ------
if [[ -f "$CFG_FILE" ]]; then
  jq --argjson entry "$NEWRELIC_ENTRY" \
     '.mcpServers = ((.mcpServers // {}) | .newrelic = $entry)' \
     "$CFG_FILE" > "${CFG_FILE}.tmp"
  mv "${CFG_FILE}.tmp" "$CFG_FILE"
else
  jq --argjson entry "$NEWRELIC_ENTRY" \
     -n '{ mcpServers: { newrelic: $entry } }' \
     > "$CFG_FILE"
fi

ok "newrelic MCP (APIM $ENV_NAME) added to $CFG_FILE"

# ------ verify JSON well-formed after write ------
if ! jq empty "$CFG_FILE" >/dev/null 2>&1; then
  fail "post-write validation failed. Restoring backup."
  [[ -n "${BACKUP:-}" ]] && cp "$BACKUP" "$CFG_FILE" && info "restored from $BACKUP"
  exit 1
fi

head "Next steps"
info "1. Fully quit Claude Code and relaunch."
info "2. Run /mcp — 'newrelic' should show ✔ Connected (no OAuth prompt — headersHelper mints a token from your az session when Claude Code connects)."
info "3. If it shows 'Failed to connect', check: az account show (session active?) and group membership (AZ_JobRole_Observability_NewRelicMcp_User)."
echo ""
info "Endpoint: $MCP_URL"
info "Audience: $NR_MCP_APP_ID"
echo ""
