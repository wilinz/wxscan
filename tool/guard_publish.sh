#!/usr/bin/env bash
# Refuses a direct `pub publish` or `cargo publish`, and says what to run
# instead.
#
# A Claude Code PreToolUse hook on Bash. It reads the tool call as JSON on
# stdin and answers with a permission decision, so it is the harness that
# enforces this, not an agent's willingness to read the documentation. That
# distinction is the whole point: wxscan 0.1.4 shipped broken because the
# release went out by hand, past `publish-kit` and past everything the README
# and CLAUDE.md say about it.
#
# publish-kit spawns the real publish command as a subprocess of its own, which
# never passes through the Bash tool, so a release driven properly is unaffected.
#
# Wired up in .claude/settings.json. To check it by hand:
#
#   echo '{"tool_input":{"command":"dart pub publish"}}' | tool/guard_publish.sh
set -euo pipefail

command_json=$(cat)
command=$(printf '%s' "$command_json" | jq -r '.tool_input.command // ""')

# A dry run uploads nothing, so it stays available: it is how you check that a
# package packs before handing it to the kit.
if printf '%s' "$command" | grep -q -- '--dry-run'; then
  exit 0
fi

reason=""
if printf '%s' "$command" | grep -Eq '(^|[;&|[:space:]])(dart|flutter)[[:space:]]+pub[[:space:]]+publish([[:space:]]|$)'; then
  reason='Refusing a direct `pub publish`.

Releases in this workspace go through publish-kit, which publishes seven
targets to two registries in dependency order. Publishing wxscan by hand skips
`release-deps`, which rewrites packages/wxscan/rust/Cargo.toml from the sibling
path dependencies the checkout commits to the crates.io versions a consumer
needs. That form builds locally and nowhere else, and it is how wxscan 0.1.4
went out unbuildable.

  cd wxscan/publish-kit
  dart run publish_kit check
  dart run publish_kit release-deps
  dart run publish_kit publish
  dart run publish_kit restore-dev

See wxscan/CLAUDE.md and wxscan/publish-kit/README.md. Add --dry-run to run
this command anyway.'
elif printf '%s' "$command" | grep -Eq '(^|[;&|[:space:]])cargo[[:space:]]+publish([[:space:]]|$)'; then
  reason='Refusing a direct `cargo publish`.

Releases in this workspace go through publish-kit, which publishes the five
crates in dependency order — cvlite, wxing, wxscan-tflite, wxscan, wxscan-ffi —
and skips whatever the registry already serves. A crate version cannot be taken
back once it is up, even by yanking.

  cd wxscan/publish-kit
  dart run publish_kit check
  dart run publish_kit publish --only crate:<name>

See wxscan/CLAUDE.md and wxscan/publish-kit/README.md. Add --dry-run to run
this command anyway.'
fi

if [ -z "$reason" ]; then
  exit 0
fi

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
