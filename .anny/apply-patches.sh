#!/usr/bin/env bash
#
# Turns a pristine upstream checkout into the anny mirror.
#
# Every patch is anchored: the anchors are asserted before anything is
# rewritten, so an upstream restructure fails the sync loudly instead of
# quietly shipping a plugin that still points at PostHog Cloud. Idempotent --
# running it twice changes nothing.
#
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=config.env
source .anny/config.env

fail() { echo "apply-patches: $*" >&2; exit 1; }

# jq that keeps the anchor honest: the filter must match something that
# already exists, otherwise we are inventing structure rather than patching it.
assert() {
    jq -e "$2" "$1" >/dev/null 2>&1 || fail "anchor gone in $1 -- upstream restructured: $2"
}
jqi() {
    local f=$1; shift
    jq "$@" "$f" > "$f.tmp" || fail "jq failed on $f"
    mv "$f.tmp" "$f"
}
# Portable in-place sed over a file list on stdin (BSD and GNU both take -i.bak).
sed_files() {
    local expr=$1
    while IFS= read -r f; do
        sed -i.bak -E "$expr" "$f" && rm -f "$f.bak"
    done
}

# --- anchors -----------------------------------------------------------------
for f in .mcp.json mcp.json .claude-plugin/plugin.json \
         .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
    [ -f "$f" ] || fail "missing $f"
done
assert .mcp.json                     '.mcpServers.posthog.url'
assert mcp.json                      '.mcpServers.posthog.url'
assert .claude-plugin/plugin.json    '.name == "posthog"'
assert .claude-plugin/marketplace.json '.plugins[0].source == "./"'
assert .agents/plugins/marketplace.json '.plugins[0].source.url'

# --- 1. the MCP endpoint -----------------------------------------------------
# The entire reason this mirror exists. A blanket rewrite (not just the two
# JSONs) so a new file upstream that hardcodes the hosted endpoint gets caught
# too; the assertion at the bottom proves none was missed.
grep -rlF 'https://mcp.posthog.com/mcp' . \
    --exclude-dir=.git --exclude-dir=.anny --exclude-dir=node_modules 2>/dev/null \
    | sed_files "s#https://mcp\.posthog\.com/mcp#${MCP_URL}#g"

# --- 2. identity -------------------------------------------------------------
# Renamed so it can live side by side with the official plugin: someone who
# also has `posthog@claude-plugins-official` installed gets both, pointed at
# two different instances, instead of a name collision.
jqi .claude-plugin/plugin.json \
    --arg n "$PLUGIN_NAME" --arg r "$REPO_URL" --arg p "$POSTHOG_URL" '
    .name = $n
    | .description = "PostHog on \($p) (anny self-hosted) -- analytics, feature flags, experiments, error tracking. Mirror of PostHog/ai-plugin."
    | .repository = $r
    | .homepage = $r'

jqi .claude-plugin/marketplace.json \
    --arg m "$MARKETPLACE_NAME" --arg n "$PLUGIN_NAME" --arg r "$REPO_URL" --arg p "$POSTHOG_URL" '
    .name = $m
    | .owner = { name: "anny", url: "https://anny.co" }
    | .description = "anny plugins for Claude. PostHog wired to \($p)."
    | .plugins |= map(
        .name = $n
        | .displayName = "PostHog (anny)"
        | .description = "PostHog on \($p) (anny self-hosted) -- analytics, feature flags, experiments, error tracking."
        | .repository = $r
        | .homepage = $r
        | .author = { name: "anny", url: "https://anny.co" })'

# The manifest the Claude app reads when a marketplace is added from a repo.
# Upstream points it back at PostHog/ai-plugin -- left alone, the app would
# install the OFFICIAL plugin (pointed at PostHog Cloud) from our marketplace.
jqi .agents/plugins/marketplace.json \
    --arg m "$MARKETPLACE_NAME" --arg n "$PLUGIN_NAME" --arg r "${REPO_URL}.git" '
    .name = $m
    | .interface.displayName = "PostHog (anny)"
    | .plugins |= map(.name = $n | .source.url = $r)'

# --- 3. deep links in the skills --------------------------------------------
# ~250 "open this in PostHog" links across the skills point at the hosted app.
# Left alone every one of them sends a reader to an instance they have no
# account on.
grep -rlE 'https://(us|eu|app)\.posthog\.com' skills commands agents 2>/dev/null \
    | sed_files "s#https://(us|eu|app)\.posthog\.com#${POSTHOG_URL}#g"

# --- 4. LLM Analytics session capture ---------------------------------------
# Opt-in hook, but its default host is PostHog Cloud. Anyone who flips
# POSTHOG_LLMA_CC_ENABLED without also setting POSTHOG_HOST would ship their
# Claude Code transcripts to the wrong company.
grep -rlE 'https://(us|eu)\.i\.posthog\.com' posthog_llma hooks 2>/dev/null \
    | sed_files "s#https://(us|eu)\.i\.posthog\.com#${POSTHOG_INGEST_URL}#g"

# --- assertions --------------------------------------------------------------
[ "$(jq -r '.mcpServers.posthog.url' .mcp.json)" = "$MCP_URL" ] || fail ".mcp.json url not rewritten"
[ "$(jq -r '.mcpServers.posthog.url' mcp.json)" = "$MCP_URL" ] || fail "mcp.json url not rewritten"
[ "$(jq -r '.name' .claude-plugin/plugin.json)" = "$PLUGIN_NAME" ] || fail "plugin not renamed"
[ "$(jq -r '.plugins[0].source.url' .agents/plugins/marketplace.json)" = "${REPO_URL}.git" ] \
    || fail "app marketplace still points upstream"
if grep -rqF 'mcp.posthog.com' . --exclude-dir=.git --exclude-dir=.anny --exclude='*.md' 2>/dev/null; then
    echo "apply-patches: leftover references to the hosted MCP endpoint:" >&2
    grep -rlF 'mcp.posthog.com' . --exclude-dir=.git --exclude-dir=.anny --exclude='*.md' >&2
    exit 1
fi

# --- 5. our own files --------------------------------------------------------
# Upstream's CI has no business running in a mirror (it releases to PostHog's
# marketplace and syncs skills from their monorepo). Drop it, then lay our
# workflow back down -- .anny/ is the canonical copy, this is just the copy
# GitHub actually reads.
rm -rf .github
mkdir -p .github/workflows
cp .anny/workflows/mirror.yml .github/workflows/mirror.yml

# Upstream's README tells the reader to install `posthog@posthog` from
# PostHog. Keep it for reference, lead with ours.
[ -f README.md ] && mv README.md UPSTREAM_README.md
cp .anny/README.md README.md

echo "apply-patches: ok -- MCP ${MCP_URL}, auth server ${POSTHOG_URL}"
