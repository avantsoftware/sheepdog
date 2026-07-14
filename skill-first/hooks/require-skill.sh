#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit) gate enforcing the skill-first rule: a governed
# file may only be edited after the SPECIFIC matching skill for that file was
# invoked. The Skill tool's PostToolUse hook (stamp-skill.sh) records "<ts> <skill>"
# in the project's .claude/skill-first/.skill-used.
#
# All rules are PROJECT-OWNED, not shipped by the plugin. The path->skill map lives
# at .claude/skill-first/gate-map.conf (scaffold it with /skill-first:setup).
# No map -> the plugin is a no-op for this project (every edit allowed).
#
# gate-map.conf format (first matching glob wins; comments/blank lines ignored):
#   <glob>|<skill>        a file matching <glob> requires <skill>
#   @override|<skill>     <skill> may edit ANY governed file (e.g. an orchestrator
#                         skill that composes several others); repeatable

WINDOW=300 # seconds (5 min)

MAP="$CLAUDE_PROJECT_DIR/.claude/skill-first/gate-map.conf"
[ -f "$MAP" ] || exit 0

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

required=""
overrides=" "
while IFS='|' read -r glob skill; do
  case "$glob" in '' | \#*) continue ;; esac
  if [ "$glob" = "@override" ]; then
    overrides="$overrides$skill "
    continue
  fi
  # First matching glob wins; keep scanning so later @override lines are still read.
  if [ -z "$required" ]; then
    # shellcheck disable=SC2254
    case "$FILE" in $glob) required="$skill" ;; esac
  fi
done <"$MAP"

# Not a governed path -> allow.
[ -z "$required" ] && exit 0

STAMP="$CLAUDE_PROJECT_DIR/.claude/skill-first/.skill-used"
ts=""
used=""
[ -f "$STAMP" ] && read -r ts used <"$STAMP"
now=$(date +%s)

if [ -n "$ts" ] && [ "$((now - ts))" -lt "$WINDOW" ]; then
  [ "$used" = "$required" ] && exit 0
  case "$overrides" in *" $used "*) exit 0 ;; esac
fi

echo "Blocked: $FILE requires the '$required' skill. Invoke it via the Skill tool (last skill: '${used:-none}'), then redo this edit. (Gate: skill-first plugin; rules in .claude/skill-first/gate-map.conf; valid ${WINDOW}s after the matching skill.)" >&2
exit 2
