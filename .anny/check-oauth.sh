#!/usr/bin/env bash
#
# Preflight for the MCP + dynamic-client-registration path.
#
# Run this before handing the plugin to anyone. It walks exactly the sequence
# the Claude app walks on first use, so a failure here is the failure a user
# would hit -- except it names the cause instead of showing "could not connect".
#
#   .anny/check-oauth.sh              read-only probes
#   .anny/check-oauth.sh --register   also does a real RFC 7591 registration
#                                     (creates an OAuth app in PostHog; the
#                                     client_id is printed so you can delete it)
#
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=config.env
source .anny/config.env

MCP_ORIGIN="${MCP_URL%/mcp}"
MCP_PATH="/${MCP_URL#"${MCP_ORIGIN}/"}"
fails=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
info() { printf '        %s\n' "$1"; }

echo
echo "PostHog   ${POSTHOG_URL}"
echo "MCP       ${MCP_URL}"
echo

# 1 -- The MCP server must refuse an unauthenticated call and say where to
#      authenticate. This is what kicks the whole OAuth dance off.
echo "1. MCP rejects unauthenticated calls"
hdrs=$(curl -sS -m 15 -D - -o /dev/null -X POST "$MCP_URL" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"preflight","version":"1"}}}' 2>&1)
code=$(printf '%s' "$hdrs" | awk 'NR==1{print $2}')
case "$code" in
    401) pass "401 as expected" ;;
    "")  fail "no response -- is ${MCP_ORIGIN} deployed and reachable?" ;;
    *)   fail "expected 401, got ${code}" ;;
esac
if printf '%s' "$hdrs" | grep -qi '^www-authenticate:'; then
    pass "WWW-Authenticate header present"
    info "$(printf '%s' "$hdrs" | grep -i '^www-authenticate:' | head -1 | tr -d '\r')"
else
    fail "no WWW-Authenticate header -- clients cannot discover the auth server"
fi

# 2 -- RFC 9728. Served by the MCP server itself; must name our PostHog, not
#      PostHog Cloud. This is what POSTHOG_API_BASE_URL controls.
echo
echo "2. Protected-resource metadata (RFC 9728)"
prm=$(curl -sS -m 15 "${MCP_ORIGIN}/.well-known/oauth-protected-resource${MCP_PATH}" 2>/dev/null)
as=$(printf '%s' "$prm" | jq -r '.authorization_servers[0] // empty' 2>/dev/null)
if [ -z "$as" ]; then
    fail "no authorization_servers -- MCP server not serving RFC 9728 metadata"
else
    if [ "${as%/}" = "${POSTHOG_URL%/}" ]; then
        pass "authorization_server = ${as}"
    else
        fail "authorization_server = ${as} (expected ${POSTHOG_URL})"
        info "set POSTHOG_API_BASE_URL=${POSTHOG_URL} on the MCP deployment"
    fi
fi

# 3 -- The consent page in PostHog fetches this metadata from the browser.
#      OAUTH_CONSENT_PAGE_ORIGINS in the MCP image is a hardcoded allowlist
#      (us/eu.posthog.com + localhost) that a self-hosted origin is not in, so
#      this header has to come from the ingress instead.
echo
echo "3. CORS for the consent page"
acao=$(curl -sS -m 15 -D - -o /dev/null \
    -H "Origin: ${POSTHOG_URL}" \
    "${MCP_ORIGIN}/.well-known/oauth-protected-resource${MCP_PATH}" 2>/dev/null \
    | grep -i '^access-control-allow-origin:' | head -1 | tr -d '\r')
if [ -n "$acao" ]; then
    pass "${acao}"
else
    fail "no Access-Control-Allow-Origin for ${POSTHOG_URL}"
    info "expected -- add it on the ingress; see README, 'CORS für die Consent-Seite'"
fi

# 4 -- The authorization server itself.
echo
echo "4. Authorization server metadata (RFC 8414)"
asm=$(curl -sS -m 15 "${POSTHOG_URL}/.well-known/oauth-authorization-server" 2>/dev/null)
reg=$(printf '%s' "$asm" | jq -r '.registration_endpoint // empty' 2>/dev/null)
if [ -z "$reg" ]; then
    fail "no registration_endpoint -- this instance does not offer DCR"
    info "without it every user would need a manually created OAuth app"
else
    pass "registration_endpoint = ${reg}"
    for ep in authorization_endpoint token_endpoint jwks_uri; do
        v=$(printf '%s' "$asm" | jq -r ".${ep} // empty")
        [ -n "$v" ] && pass "${ep} = ${v}" || fail "missing ${ep}"
    done
fi

# 5 -- DCR must answer an unauthenticated caller. Anthropic's backend registers
#      from its own servers with none of the user's credentials.
echo
echo "5. Dynamic client registration (RFC 7591)"
if [ -n "$reg" ]; then
    body=$(curl -sS -m 15 -w '\n%{http_code}' -X POST "$reg" \
        -H 'content-type: application/json' -d '{}' 2>/dev/null)
    code=${body##*$'\n'}
    if [ "$code" = "400" ] && printf '%s' "$body" | grep -q invalid_client_metadata; then
        pass "reachable and unauthenticated (400 invalid_client_metadata on an empty body)"
    elif [ "$code" = "401" ] || [ "$code" = "403" ]; then
        fail "registration requires auth (${code}) -- Claude cannot self-register"
    else
        fail "unexpected ${code}: $(printf '%s' "$body" | head -c 200)"
    fi

    if [ "${1:-}" = "--register" ]; then
        echo
        echo "   real registration"
        resp=$(curl -sS -m 20 -X POST "$reg" -H 'content-type: application/json' -d '{
            "client_name": "anny preflight (delete me)",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        }' 2>/dev/null)
        cid=$(printf '%s' "$resp" | jq -r '.client_id // empty')
        if [ -n "$cid" ]; then
            pass "registered client_id=${cid}"
            info "delete it under ${POSTHOG_URL}/settings/organization-connected-apps"
        else
            fail "registration rejected: $(printf '%s' "$resp" | head -c 300)"
        fi
    fi
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed -- the plugin is ready to hand out"
else
    echo "${fails} check(s) failed"
fi
exit $((fails > 0))
