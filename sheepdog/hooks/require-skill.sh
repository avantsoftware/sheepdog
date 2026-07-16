#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit) gate enforcing the sheepdog rule: a governed
# file may only be edited after the SPECIFIC matching skill for that file was
# invoked. The Skill tool's PostToolUse hook (stamp-skill.sh) records "<ts> <skill>"
# in the project's .claude/sheepdog/.skill-used.
#
# Config comes from .claude/sheepdog/config.json (see lib/common.sh for the
# schema and the legacy gate-map.conf fallback). No config -> every edit allowed.
# On a governed project the gate FAILS CLOSED when it cannot do its job — jq
# missing, config unparseable, unknown/misspelled keys — because a gate that
# silently turns itself off is worse than a loud one.
case "${BASH_SOURCE[0]}" in */*) _dir="${BASH_SOURCE[0]%/*}" ;; *) _dir="." ;; esac
. "$_dir/lib/common.sh"

# Project not opted in -> allow everything.
[ -f "$SD_JSON" ] || [ -f "$SD_LEGACY" ] || exit 0

if ! sf_ensure_jq; then
  {
    printf '\n  ✗  sheepdog: `jq` was not found on PATH, so the gate cannot run.\n'
    printf '     This project governs edits (.claude/sheepdog/), so all Edit/Write calls are\n'
    printf '     blocked until jq is available to Claude Code. Ask the user to install jq.\n'
  } >&2
  exit 2
fi

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0
FILE=${FILE//\\//}
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

required=""
rule=""
overrides=" "
LOG_ENABLED=1
if [ -f "$SD_JSON" ]; then
  SRC="config.json"
  if ! errmsg=$(sf_check_config); then
    {
      printf '\n  ✗  sheepdog: could not read .claude/sheepdog/%s\n' "$SRC"
      printf '     %s\n\n' "$errmsg"
      printf '  All Edit/Write calls are blocked until the config parses. Fix that file (or remove it to disable the gate).\n'
    } >&2
    exit 2
  fi
  WINDOW=$(jq -r ".window // $WINDOW_DEFAULT" "$SD_JSON")
  LOG_ENABLED=$(jq -r 'if .log == false then 0 else 1 end' "$SD_JSON")
  overrides=" $(jq -r '(.overrides // []) | join(" ")' "$SD_JSON") "
  # First matching glob wins; rules keep file order.
  while IFS='|' read -r glob skill; do
    [ -z "$glob" ] && continue
    # shellcheck disable=SC2254
    case "$FILE" in $glob) required="$skill"; rule="$glob"; break ;; esac
  done < <(jq -r '(.rules // [])[] | .glob + "|" + .skill' "$SD_JSON")
else
  # Legacy gate-map.conf: <glob>|<skill> lines, @override|<skill>, # comments.
  SRC="gate-map.conf"
  WINDOW=$WINDOW_DEFAULT
  while IFS='|' read -r glob skill; do
    case "$glob" in '' | \#*) continue ;; esac
    if [ "$glob" = "@override" ]; then
      overrides="$overrides$skill "
      continue
    fi
    # First matching glob wins; keep scanning so later @override lines are still read.
    if [ -z "$required" ]; then
      # shellcheck disable=SC2254
      case "$FILE" in $glob) required="$skill"; rule="$glob" ;; esac
    fi
  done <"$SD_LEGACY"
fi

# Not a governed path -> allow (and don't log: only governed decisions matter).
[ -z "$required" ] && exit 0

# Every decision on a governed path is journaled to log.jsonl (see common.sh).
sd_log() { # $1 event (allow|block), $2 reason
  [ "$LOG_ENABLED" = "1" ] || return 0
  sf_log_decision "$1" "$2" "$FILE" "$rule" "$required" "$used" "$SESSION"
}

ts=""
used=""
[ -f "$SD_STAMP" ] && read -r ts used <"$SD_STAMP"
case "$ts" in '' | *[!0-9]*) ts="" ;; esac
now=$(date +%s)
win=$(sf_fmt_window "$WINDOW")

# Would the stamped skill satisfy this gate, ignoring freshness?
satisfies=0
via=""
if [ -n "$used" ]; then
  if [ "$used" = "$required" ]; then
    satisfies=1 via="match"
  else
    case "$overrides" in *" $used "*) satisfies=1 via="override" ;; esac
  fi
fi

# Fresh AND satisfying -> allow the edit.
if [ "$satisfies" -eq 1 ] && [ -n "$ts" ] && [ "$((now - ts))" -lt "$WINDOW" ]; then
  sd_log allow "$via"
  exit 0
fi

# Blocked: report the precise reason and the exact next action.
if [ -z "$used" ]; then
  reason="no-skill"
  why="No skill has been invoked yet, so no edit to this path is authorized."
elif [ "$satisfies" -eq 1 ]; then
  reason="expired"
  why="You invoked '$used' earlier, but that was over $win ago and the authorization has expired."
else
  reason="wrong-skill"
  why="The last skill you invoked ('$used') does not authorize edits to this path."
fi
sd_log block "$reason"

{
  printf '\n'
  printf '  ✗  sheepdog blocked this edit\n\n'
  printf '     File       %s\n' "$FILE"
  printf '     Why        %s\n' "$why"
  printf '     Required   the "%s" skill\n\n' "$required"
  printf '  →  Do this now: invoke the Skill tool with skill "%s", then re-apply this exact edit.\n' "$required"
  printf '     This path is governed by .claude/sheepdog/%s; the skill stays valid for %s after you invoke it.\n' "$SRC" "$win"
} >&2
exit 2
