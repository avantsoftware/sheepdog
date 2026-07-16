#!/usr/bin/env bash
# End-to-end tests for the sheepdog bash hooks (config.json engine).
set -u
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sheepdog/hooks" && pwd)"
BASH_BIN="/bin/bash" # macOS system bash 3.2 — catches bashisms too
WORK="$(mktemp -d)"
PASS=0; FAIL=0; SKIP=0

# run <name> <expected_exit> <stdin_json> <hook-file> [grep_pattern] [stream]
run() {
  local name="$1" want_exit="$2" stdin="$3" hook="$4" pattern="${5:-}" stream="${6:-both}"
  local out err code
  out="$(mktemp)"; err="$(mktemp)"
  printf '%s' "$stdin" | "$BASH_BIN" "$HOOKS/$hook" >"$out" 2>"$err"; code=$?
  local ok=1
  [ "$code" -eq "$want_exit" ] || ok=0
  if [ -n "$pattern" ]; then
    case "$stream" in
      stdout) grep -qF -- "$pattern" "$out" || ok=0 ;;
      stderr) grep -qF -- "$pattern" "$err" || ok=0 ;;
      both)   cat "$out" "$err" | grep -qF -- "$pattern" || ok=0 ;;
      empty_stdout) [ ! -s "$out" ] || ok=0 ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS  $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $name (exit=$code want=$want_exit)"
    echo "--- stdout:"; sed 's/^/    /' "$out"; echo "--- stderr:"; sed 's/^/    /' "$err"
  fi
  rm -f "$out" "$err"
}

edit_json() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
skill_json() { printf '{"tool_input":{"skill":"%s"}}' "$1"; }
stamp_now() { printf '%s %s\n' "$(date +%s)" "$1" > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"; }
stamp_old() { printf '%s %s\n' "$(( $(date +%s) - 9999 ))" "$1" > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"; }

### 1. Project without config: everything no-ops
export CLAUDE_PROJECT_DIR="$WORK/bare"; mkdir -p "$CLAUDE_PROJECT_DIR"
run "no-config: gate allows"            0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "no-config: reminder silent"        0 "" skill-reminder.sh "" empty_stdout
run "no-config: stamp no-op"            0 "$(skill_json foo)" stamp-skill.sh
[ ! -e "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used" ] && { PASS=$((PASS+1)); echo "PASS  no-config: no stamp file written"; } || { FAIL=$((FAIL+1)); echo "FAIL  no-config: stamp file was written"; }

### 2. JSON project
export CLAUDE_PROJECT_DIR="$WORK/json"; mkdir -p "$CLAUDE_PROJECT_DIR/.claude/sheepdog"
cat > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json" <<'EOF'
{
  "window": 300,
  "overrides": ["edit-or-create-endpoint"],
  "rules": [
    { "glob": "*/app/operations/base/*", "skill": "edit-or-create-base-operation", "desc": "base operations" },
    { "glob": "*/app/operations/*", "skill": "edit-or-create-action-operation" },
    { "glob": "*/spec/uni?.rb", "skill": "single-char-skill" }
  ]
}
EOF

run "json: reminder has preamble"       0 "" skill-reminder.sh "[sheepdog] STOP." stdout
run "json: reminder has generated rule" 0 "" skill-reminder.sh "- */app/operations/base/* (base operations) -> edit-or-create-base-operation" stdout
run "json: reminder lists overrides"    0 "" skill-reminder.sh "Override skills (authorize edits to ANY governed path): edit-or-create-endpoint" stdout
run "json: reminder says 5 min"         0 "" skill-reminder.sh "valid for 5 min" stdout

run "json: ungoverned path allowed"     0 "$(edit_json /x/lib/foo.rb)" require-skill.sh
run "json: no stamp -> block"           2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "No skill has been invoked yet" stderr
run "json: block names required skill"  2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh 'invoke the Skill tool with skill "edit-or-create-action-operation"' stderr
run "json: block cites config.json"     2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "governed by .claude/sheepdog/config.json" stderr

run "json: stamp writes file"           0 "$(skill_json edit-or-create-action-operation)" stamp-skill.sh
grep -q "edit-or-create-action-operation" "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used" && { PASS=$((PASS+1)); echo "PASS  json: stamp content"; } || { FAIL=$((FAIL+1)); echo "FAIL  json: stamp content"; }

run "json: right skill fresh -> allow"  0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "json: first match wins (base)"     2 "$(edit_json /x/app/operations/base/b.rb)" require-skill.sh 'Required   the "edit-or-create-base-operation" skill' stderr
run "json: wrong skill -> block"        2 "$(edit_json /x/app/operations/base/b.rb)" require-skill.sh "does not authorize edits to this path" stderr

stamp_now edit-or-create-endpoint
run "json: override skill -> allow"     0 "$(edit_json /x/app/operations/base/b.rb)" require-skill.sh
run "json: override on other rule"      0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh

stamp_old edit-or-create-action-operation
run "json: expired -> block"            2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "over 5 min ago and the authorization has expired" stderr

stamp_now single-char-skill
run "json: ? matches one char"          0 "$(edit_json /x/spec/unit.rb)" require-skill.sh
run "json: ? does not match two chars"  0 "$(edit_json /x/spec/unitt.rb)" require-skill.sh
rm -f "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"
run "json: backslash path normalized"   2 "$(edit_json 'C:\\x\\app\\operations\\a.rb')" require-skill.sh "No skill has been invoked yet" stderr
run "json: empty stdin -> allow"        0 "" require-skill.sh
run "json: no file_path -> allow"       0 '{"tool_input":{}}' require-skill.sh
run "json: garbage stamp ts -> block"   2 "$(edit_json /x/app/operations/a.rb; printf 'zzz edit-or-create-action-operation\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used")" require-skill.sh "expired" stderr
rm -f "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"

### 3. Custom window + custom reminder
cat > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json" <<'EOF'
{
  "window": 90,
  "reminder": "CUSTOM PREAMBLE HERE",
  "rules": [
    { "glob": "*/app/operations/*", "skill": "edit-or-create-action-operation" }
  ]
}
EOF
run "custom: reminder replaced"         0 "" skill-reminder.sh "CUSTOM PREAMBLE HERE" stdout
run "custom: table still generated"     0 "" skill-reminder.sh "- */app/operations/* -> edit-or-create-action-operation" stdout
printf '%s %s\n' "$(( $(date +%s) - 120 ))" "edit-or-create-action-operation" > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"
run "custom: 90s window expires at 120s" 2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "over 90 s ago" stderr
printf '%s %s\n' "$(( $(date +%s) - 60 ))" "edit-or-create-action-operation" > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"
run "custom: 60s-old stamp still valid" 0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
rm -f "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"

### 4. Broken / invalid configs fail closed
printf '{"rules": [\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "broken: gate blocks everything"    2 "$(edit_json /x/anything.txt)" require-skill.sh "could not read .claude/sheepdog/config.json" stderr
run "broken: reminder warns"            0 "" skill-reminder.sh "[sheepdog] WARNING" stdout
printf '{"rules": [{"glob": "*/a/*"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "invalid: missing skill field"      2 "$(edit_json /x/anything.txt)" require-skill.sh "rules[0].skill must be a non-empty string" stderr
printf '{"window": -5, "rules": []}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "invalid: negative window"          2 "$(edit_json /x/a.txt)" require-skill.sh "window must be a positive integer" stderr
printf '{"window": 300, "ruls": [{"glob": "*/a/*", "skill": "s"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "invalid: unknown top-level key"    2 "$(edit_json /x/a.txt)" require-skill.sh 'unknown key "ruls" (allowed: window, reminder, overrides, rules, log)' stderr
run "invalid: unknown key reminder warns" 0 "" skill-reminder.sh "[sheepdog] WARNING" stdout
printf '{"rules": [{"glob": "*/a/*", "skill": "s", "des": "typo"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "invalid: unknown key inside rule"  2 "$(edit_json /x/a.txt)" require-skill.sh "rules[0] has an unknown key (allowed: glob, skill, desc)" stderr

### 5. Empty variants
printf '{}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "empty-obj: gate allows"            0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "empty-obj: reminder silent"        0 "" skill-reminder.sh "" empty_stdout
printf '{"rules": []}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "empty-rules: gate allows"          0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "empty-rules: reminder silent"      0 "" skill-reminder.sh "" empty_stdout
: > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "empty-file: gate fails closed"     2 "$(edit_json /x/a.txt)" require-skill.sh "could not read" stderr
run "empty-file: reminder warns"        0 "" skill-reminder.sh "[sheepdog] WARNING" stdout

### 6. Legacy gate-map.conf + routing.md
export CLAUDE_PROJECT_DIR="$WORK/legacy"; mkdir -p "$CLAUDE_PROJECT_DIR/.claude/sheepdog"
cat > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/gate-map.conf" <<'EOF'
# comment
@override|edit-or-create-endpoint
*/app/operations/base/*|edit-or-create-base-operation
*/app/operations/*|edit-or-create-action-operation
EOF
printf 'LEGACY ROUTING TABLE\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/routing.md"

run "legacy: reminder prints routing.md" 0 "" skill-reminder.sh "LEGACY ROUTING TABLE" stdout
run "legacy: no stamp -> block"          2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "No skill has been invoked yet" stderr
run "legacy: block cites gate-map.conf"  2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "governed by .claude/sheepdog/gate-map.conf" stderr
run "legacy: block says 5 min"           2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "valid for 5 min" stderr
stamp_now edit-or-create-action-operation
run "legacy: right skill -> allow"       0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "legacy: first match wins"           2 "$(edit_json /x/app/operations/base/b.rb)" require-skill.sh 'the "edit-or-create-base-operation" skill' stderr
stamp_now edit-or-create-endpoint
run "legacy: override -> allow"          0 "$(edit_json /x/app/operations/base/b.rb)" require-skill.sh
stamp_old edit-or-create-action-operation
run "legacy: expired -> block"           2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "expired" stderr
run "legacy: ungoverned allowed"         0 "$(edit_json /x/lib/x.rb)" require-skill.sh
run "legacy: stamp empty skill ok"       0 '{"tool_input":{}}' stamp-skill.sh
run "legacy: empty stamp -> no-skill msg" 2 "$(edit_json /x/app/operations/a.rb)" require-skill.sh "No skill has been invoked yet" stderr

### 7. config.json wins over legacy when both exist
printf '{"rules": [{"glob": "*/only-json/*", "skill": "json-skill"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "precedence: json wins (legacy path free)" 0 "$(edit_json /x/app/operations/a.rb)" require-skill.sh
run "precedence: json rules active"      2 "$(edit_json /x/only-json/f)" require-skill.sh 'the "json-skill" skill' stderr

### 8. jq missing (restricted env; skipped if the PATH fallback still finds jq)
FAKEHOME="$WORK/fakehome"; mkdir -p "$FAKEHOME"
JQ_LEAK=$(env -i PATH=/bin HOME="$FAKEHOME" USER=nouser /bin/bash -c 'PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/${USER}/bin:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"; command -v jq' 2>/dev/null || true)
if [ -n "$JQ_LEAK" ]; then
  SKIP=$((SKIP+4)); echo "SKIP  jq-missing scenarios (jq reachable at $JQ_LEAK even with restricted PATH)"
else
  jrun() { # name want_exit stdin hook pattern projdir
    local name="$1" want="$2" stdin="$3" hook="$4" pattern="$5" pdir="$6"
    local o code
    o=$(printf '%s' "$stdin" | env -i PATH=/bin HOME="$FAKEHOME" USER=nouser CLAUDE_PROJECT_DIR="$pdir" /bin/bash "$HOOKS/$hook" 2>&1); code=$?
    if [ "$code" -eq "$want" ] && { [ -z "$pattern" ] || printf '%s' "$o" | grep -qF -- "$pattern"; }; then
      PASS=$((PASS+1)); echo "PASS  $name"
    else
      FAIL=$((FAIL+1)); echo "FAIL  $name (exit=$code want=$want)"; printf '%s\n' "$o" | sed 's/^/    /'
    fi
  }
  GOV="$WORK/legacy"   # governed (config.json + gate-map.conf)
  UNGOV="$WORK/bare"   # not governed
  jrun "no-jq: governed gate blocks"     2 "$(edit_json /x/a.txt)" require-skill.sh '`jq` was not found on PATH' "$GOV"
  jrun "no-jq: governed reminder warns"  0 "" skill-reminder.sh "[sheepdog] WARNING" "$GOV"
  jrun "no-jq: stamp silent no-op"       0 "$(skill_json x)" stamp-skill.sh "" "$GOV"
  jrun "no-jq: ungoverned still allowed" 0 "$(edit_json /x/a.txt)" require-skill.sh "" "$UNGOV"
fi

### 9. Decision log (log.jsonl)
export CLAUDE_PROJECT_DIR="$WORK/logproj"; mkdir -p "$CLAUDE_PROJECT_DIR/.claude/sheepdog"
LOG="$CLAUDE_PROJECT_DIR/.claude/sheepdog/log.jsonl"
cat > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json" <<'EOF'
{
  "overrides": ["orchestrator"],
  "rules": [{ "glob": "*/app/gov/*", "skill": "gov-skill" }]
}
EOF
log_last() { # <name> <pattern> — assert the LAST log line contains pattern
  if tail -n 1 "$LOG" 2>/dev/null | grep -qF -- "$2"; then PASS=$((PASS+1)); echo "PASS  $1"
  else FAIL=$((FAIL+1)); echo "FAIL  $1"; echo "--- last log line:"; tail -n 1 "$LOG" 2>/dev/null | sed 's/^/    /'; fi
}
log_lines() { wc -l < "$LOG" 2>/dev/null | tr -d ' '; }

run "log: no-skill block still blocks"  2 '{"session_id":"sess-1","tool_input":{"file_path":"/x/app/gov/a.rb"}}' require-skill.sh "No skill has been invoked yet" stderr
log_last "log: block/no-skill recorded" '"event":"block","reason":"no-skill"'
log_last "log: required skill recorded" '"required":"gov-skill"'
log_last "log: empty used -> null"      '"used":null'
log_last "log: session id recorded"     '"session":"sess-1"'
log_last "log: matched rule recorded"   '"rule":"*/app/gov/*"'
if tail -n 1 "$LOG" | jq -e '(.ts | type) == "number"' >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS  log: line is valid JSON with numeric ts"; else FAIL=$((FAIL+1)); echo "FAIL  log: line is valid JSON with numeric ts"; fi

stamp_now other-skill
run "log: wrong-skill block"            2 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
log_last "log: wrong-skill recorded"    '"reason":"wrong-skill"'
log_last "log: stamped skill recorded"  '"used":"other-skill"'
stamp_old gov-skill
run "log: expired block"                2 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
log_last "log: expired recorded"        '"reason":"expired"'
stamp_now gov-skill
run "log: matching allow"               0 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
log_last "log: allow/match recorded"    '"event":"allow","reason":"match"'
stamp_now orchestrator
run "log: override allow"               0 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
log_last "log: allow/override recorded" '"reason":"override"'

before=$(log_lines)
run "log: ungoverned path allowed"      0 "$(edit_json /x/lib/free.rb)" require-skill.sh
[ "$(log_lines)" = "$before" ] && { PASS=$((PASS+1)); echo "PASS  log: ungoverned path not logged"; } || { FAIL=$((FAIL+1)); echo "FAIL  log: ungoverned path not logged"; }

printf '{"log": false, "rules": [{"glob": "*/app/gov/*", "skill": "gov-skill"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
rm -f "$CLAUDE_PROJECT_DIR/.claude/sheepdog/.skill-used"
before=$(log_lines)
run "log-off: gate still blocks"        2 "$(edit_json /x/app/gov/a.rb)" require-skill.sh "No skill has been invoked yet" stderr
[ "$(log_lines)" = "$before" ] && { PASS=$((PASS+1)); echo "PASS  log-off: nothing written"; } || { FAIL=$((FAIL+1)); echo "FAIL  log-off: nothing written"; }

printf '{"log": "yes", "rules": []}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
run "invalid: log must be boolean"      2 "$(edit_json /x/a.txt)" require-skill.sh "log must be true or false" stderr

# Rotation: a >1MB log is trimmed to its newest 2000 lines after the append.
printf '{"rules": [{"glob": "*/app/gov/*", "skill": "gov-skill"}]}\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/config.json"
awk 'BEGIN{s="";for(i=0;i<160;i++)s=s"x";for(i=0;i<8000;i++)print "{\"pad\":\""s"\"}"}' > "$LOG"
stamp_now gov-skill
run "log: edit allowed during rotation" 0 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
[ "$(log_lines)" = "2000" ] && { PASS=$((PASS+1)); echo "PASS  log: rotated to 2000 lines"; } || { FAIL=$((FAIL+1)); echo "FAIL  log: rotated to 2000 lines ($(log_lines) lines)"; }
log_last "log: newest line survives rotation" '"event":"allow"'

# Legacy projects log too (no toggle there; on by default).
export CLAUDE_PROJECT_DIR="$WORK/legacylog"; mkdir -p "$CLAUDE_PROJECT_DIR/.claude/sheepdog"
LOG="$CLAUDE_PROJECT_DIR/.claude/sheepdog/log.jsonl"
printf '*/app/gov/*|gov-skill\n' > "$CLAUDE_PROJECT_DIR/.claude/sheepdog/gate-map.conf"
run "log: legacy block"                 2 "$(edit_json /x/app/gov/a.rb)" require-skill.sh
log_last "log: legacy block recorded"   '"event":"block","reason":"no-skill"'

echo
echo "== $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
