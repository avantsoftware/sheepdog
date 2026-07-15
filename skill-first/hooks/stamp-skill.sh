#!/usr/bin/env bash
# PostToolUse(Skill): record which skill was invoked + when, so require-skill.sh
# can require the SPECIFIC skill matching the edited file (not just "any skill").
# Stamp format: "<unix_ts> <skill_name>".
#
# State lives in the PROJECT dir, never the plugin dir: $CLAUDE_PLUGIN_ROOT is a
# read-only cache that changes on every plugin update. If this project hasn't
# opted into the gate (no .claude/skill-first/ dir), do nothing.
case "${BASH_SOURCE[0]}" in */*) _dir="${BASH_SOURCE[0]%/*}" ;; *) _dir="." ;; esac
. "$_dir/lib/common.sh"

[ -d "$SF_DIR" ] || exit 0
# Without jq we can't read the skill name; the gate is failing closed anyway.
sf_ensure_jq || exit 0

INPUT=$(cat)
SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
printf '%s %s\n' "$(date +%s)" "$SKILL" >"$SF_STAMP"
