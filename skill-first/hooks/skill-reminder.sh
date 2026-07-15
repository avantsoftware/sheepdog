#!/usr/bin/env bash
# UserPromptSubmit: inject this project's skill-first routing reminder into
# context on every prompt. With config.json the routing table is GENERATED from
# the gate rules, so the reminder and the gate can never drift apart; with the
# legacy format, routing.md is printed verbatim. No config -> nothing injected.
case "${BASH_SOURCE[0]}" in */*) _dir="${BASH_SOURCE[0]%/*}" ;; *) _dir="." ;; esac
. "$_dir/lib/common.sh"

if [ -f "$SF_JSON" ]; then
  if ! sf_ensure_jq; then
    printf '[skill-first] WARNING: `jq` was not found on PATH. This project is governed by skill-first, so the gate is blocking ALL edits until jq is available to Claude Code.\n'
    exit 0
  fi
  if ! errmsg=$(sf_check_config); then
    # Surface the broken config in context: the gate is failing closed right now.
    printf '[skill-first] WARNING: .claude/skill-first/config.json is invalid (%s). The gate is blocking ALL edits until it parses — fix that file first.\n' "$errmsg"
    exit 0
  fi

  count=$(jq -r '(.rules // []) | length' "$SF_JSON")
  reminder=$(jq -r '.reminder // empty' "$SF_JSON")
  if [ "$count" -eq 0 ] && [ -z "$reminder" ]; then
    exit 0
  fi

  WINDOW=$(jq -r ".window // $WINDOW_DEFAULT" "$SF_JSON")
  win=$(sf_fmt_window "$WINDOW")
  if [ -n "$reminder" ]; then
    printf '%s\n' "$reminder"
  else
    printf '[skill-first] STOP. Before editing files in this project, invoke the matching skill below via the Skill tool FIRST, then edit. Edits to governed paths are hook-gated: the gate requires the EXACT matching skill for that file (not just any skill), valid for %s after you invoke it.\n' "$win"
  fi
  if [ "$count" -gt 0 ]; then
    printf "\nRouting (what you're touching -> required skill):\n"
    jq -r '(.rules // [])[] | "- " + .glob + (if .desc != null then " (" + .desc + ")" else "" end) + " -> " + .skill' "$SF_JSON"
  fi
  ov=$(jq -r '(.overrides // []) | join(", ")' "$SF_JSON")
  [ -n "$ov" ] && printf '\nOverride skills (authorize edits to ANY governed path): %s\n' "$ov"
  exit 0
fi

# Legacy format: print the hand-written routing.md verbatim (no jq needed).
[ -f "$SF_DIR/routing.md" ] && cat "$SF_DIR/routing.md"
exit 0
