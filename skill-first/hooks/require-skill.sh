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
mins=$((WINDOW / 60))

# Would the stamped skill satisfy this gate, ignoring freshness?
satisfies=0
if [ -n "$used" ]; then
  if [ "$used" = "$required" ]; then
    satisfies=1
  else
    case "$overrides" in *" $used "*) satisfies=1 ;; esac
  fi
fi

# Fresh AND satisfying -> allow the edit.
if [ "$satisfies" -eq 1 ] && [ -n "$ts" ] && [ "$((now - ts))" -lt "$WINDOW" ]; then
  exit 0
fi

# Blocked: report the precise reason and the exact next action.
if [ -z "$used" ]; then
  why="No skill has been invoked yet, so no edit to this path is authorized."
elif [ "$satisfies" -eq 1 ]; then
  why="You invoked '$used' earlier, but that was over ${mins} min ago and the authorization has expired."
else
  why="The last skill you invoked ('$used') does not authorize edits to this path."
fi

{
  printf '\n'
  printf '  ✗  skill-first blocked this edit\n\n'
  printf '     File       %s\n' "$FILE"
  printf '     Why        %s\n' "$why"
  printf '     Required   the "%s" skill\n\n' "$required"
  printf '  →  Do this now: invoke the Skill tool with skill "%s", then re-apply this exact edit.\n' "$required"
  printf '     This path is governed by .claude/skill-first/gate-map.conf; the skill stays valid for %s min after you invoke it.\n' "$mins"
} >&2
exit 2
