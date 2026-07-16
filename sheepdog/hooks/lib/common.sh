#!/usr/bin/env bash
# Shared helpers for the sheepdog hooks. Sourced by the hook scripts, never
# executed directly.
#
# All rules are PROJECT-OWNED, not shipped by the plugin. They live in
# $CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json (scaffold it with
# /sheepdog:setup), with a fallback to the legacy gate-map.conf format.
# No config -> the plugin is a no-op for this project.

WINDOW_DEFAULT=300 # seconds (5 min)

SD_DIR="$CLAUDE_PROJECT_DIR/.claude/sheepdog"
SD_JSON="$SD_DIR/config.json"
SD_LEGACY="$SD_DIR/gate-map.conf"
SD_STAMP="$SD_DIR/.skill-used"

# Claude Code may run hooks with a minimal PATH (GUI launch, bare shell); look
# for jq in common install locations before giving up. Returns 1 if jq is
# nowhere to be found.
sf_ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/${USER:-$(id -un)}/bin:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
  export PATH
  command -v jq >/dev/null 2>&1
}

sf_fmt_window() { # $1: seconds -> "5 min" | "90 s"
  if [ $(($1 % 60)) -eq 0 ]; then
    printf '%s min' "$(($1 / 60))"
  else
    printf '%s s' "$1"
  fi
}

# Validates config.json. Silent + status 0 when valid; prints the problem and
# returns 1 otherwise (including JSON syntax errors from jq itself).
sf_check_config() {
  local out
  out=$(jq -r '
    if type != "object" then "top level must be a JSON object (window/reminder/overrides/rules)"
    else (keys - ["window", "reminder", "overrides", "rules"]) as $extra
    | if ($extra | length) > 0 then "unknown key \"\($extra[0])\" (allowed: window, reminder, overrides, rules)"
      elif .window != null and ((.window | type) != "number" or .window <= 0 or (.window | floor) != .window) then "window must be a positive integer (seconds)"
      elif .reminder != null and (.reminder | type) != "string" then "reminder must be a string"
      elif .overrides != null and ((.overrides | type) != "array" or ([.overrides[]? | select((type != "string") or (. == ""))] | length) > 0) then "overrides must be a list of skill names"
      elif .rules != null and (.rules | type) != "array" then "rules must be a list"
      else
        first(
          ((.rules // []) | to_entries[]
            | if (.value | type) != "object" then "rules[\(.key)] must be an object with glob + skill"
              elif ((.value.glob | type) != "string") or (.value.glob == "") then "rules[\(.key)].glob must be a non-empty string"
              elif ((.value.skill | type) != "string") or (.value.skill == "") then "rules[\(.key)].skill must be a non-empty string"
              elif .value.desc != null and (.value.desc | type) != "string" then "rules[\(.key)].desc must be a string"
              elif ((.value | keys) - ["glob", "skill", "desc"] | length) > 0 then "rules[\(.key)] has an unknown key (allowed: glob, skill, desc)"
              else empty
              end),
          "OK")
      end
    end' "$SD_JSON" 2>&1)
  [ "$out" = "OK" ] && return 0
  printf '%s\n' "$out"
  return 1
}
