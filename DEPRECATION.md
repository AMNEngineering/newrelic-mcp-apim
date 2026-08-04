# Status history

## Un-deprecated on 2026-07-30

This repo is **active again**. It is the default New Relic MCP install path for
AMN engineers on the APIM Claude Code client.

**Why it came back**: the 2026-07-29 soft-deprecation was based on the premise
that AMN was migrating Claude Code to Anthropic-direct via OneLogin SSO. That
turned out to be true for a small exempted cohort only; the majority of AMN
users continue to route Claude Code through APIM. For those users, per-user
OAuth to New Relic (the direct model) is not policy-compatible — AMN prefers
a centralized KV-key path where individual users do not hold NR tokens. This
repo's design is exactly that path.

**Sibling repo**: [`AMNEngineering/newrelic-mcp-sso`](https://github.com/AMNEngineering/newrelic-mcp-sso)
serves the OAuth-direct cohort. Both point at the same New Relic MCP; they
differ only in client-side auth.

**What's live now**:

- APIM route (`/ai/new-relic-mcp/{env}`) — deployed and expected to receive
  traffic again. The soft-deprecation's queued `terraform destroy` is **cancelled**.
- Key Vault secret `AMNHealthcare-NR-Terraform-UserKey` — kept (unchanged).
- Entra app registration `api://709bbe94-…` + assigned AD groups — kept (unchanged).
- Client-side installer under [`client/`](client/) — new; adds the `mcpServers`
  headersHelper entry to the user-scope `~/.claude.json`.

## Previous soft-deprecation (2026-07-29 → 2026-07-30)

Original narrative below, kept for reference:

> This repo was built to translate an Entra token into a NerdGraph User key at
> the gateway, on the assumption that New Relic's API only accepted static keys.
> Direct probing on 2026-07-29 showed the New Relic MCP endpoint supports OAuth
> natively (`/.well-known/oauth-protected-resource` + a canonical
> `WWW-Authenticate: Bearer resource_metadata=…` on 401). NR MCP federates
> through the customer's IdP — OneLogin in AMN's case — so no translation layer
> is needed for that endpoint. The APIM route worked correctly; it was just
> solving a problem this particular service doesn't have.

That probe was factually correct — OAuth-direct **is** technically viable and
still is (see the sibling `newrelic-mcp-sso` repo). But AMN policy for the
majority-user population prefers the centralized-key model, so the APIM route
stays as the default install path.

## The general lesson (revised)

Before designing a translation layer for an MCP server's auth, probe the
endpoint's `/.well-known/oauth-protected-resource`. If it advertises OAuth and
your IdP federates to it, **OAuth-direct is technically viable** — that's a
tool in the box (see `newrelic-mcp-sso`). But **the choice of auth path is
governance, not capability**. If your org policy prefers centralized key
custody (no per-user tokens), the APIM key-injection route (this repo) is the
right pattern regardless of whether OAuth-direct would work.
