---
description: Summarize the sheepdog decision log for this project. Use when the user asks how the gate is doing, how often Claude was blocked, which conventions are being skipped, or for a sheepdog report/stats/summary — reads .claude/sheepdog/log.jsonl and turns it into insights.
---

# Report on the sheepdog decision log

Every decision the gate makes on a governed path is journaled as one JSON line in
`$CLAUDE_PROJECT_DIR/.claude/sheepdog/log.jsonl`:

```json
{"ts":1752680000,"event":"block","reason":"no-skill","file":"/repo/src/api/users.ts","rule":"*/src/api/*","required":"create-api-route","used":null,"session":"abc123"}
```

- `event` — `allow` or `block`.
- `reason` — `match` / `override` (allows); `no-skill` / `wrong-skill` / `expired` (blocks).
- `required` — the skill the matched rule demands; `used` — the skill actually stamped (null if none).

If the file does not exist, say so: either no governed path was touched yet, or
logging is disabled (`"log": false` in config.json). Don't invent numbers.

## 1. Gather the numbers

Run these (adjust the path if needed). The log is line-delimited JSON, so always
use `jq -s` to aggregate:

```bash
LOG="$CLAUDE_PROJECT_DIR/.claude/sheepdog/log.jsonl"

# Time range covered + totals by event
jq -s '{from: (.[0].ts | todate), to: (.[-1].ts | todate), total: length}' "$LOG"
jq -s 'group_by(.event) | map({key: .[0].event, value: length}) | from_entries' "$LOG"

# Blocks by reason
jq -s '[.[] | select(.event == "block")] | group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries' "$LOG"

# Most-blocked skills (the conventions Claude tries to skip)
jq -s '[.[] | select(.event == "block")] | group_by(.required) | map({skill: .[0].required, blocks: length}) | sort_by(-.blocks)' "$LOG"

# Most-blocked files
jq -s '[.[] | select(.event == "block")] | group_by(.file) | map({file: .[0].file, blocks: length}) | sort_by(-.blocks) | .[:10]' "$LOG"

# Recovery rate: after a block on a file, did an allow on that same file follow?
jq -s '[group_by(.file)[] | select(any(.event == "block")) | {file: .[0].file, recovered: (last | .event == "allow")}] | {blocked_files: length, recovered: map(select(.recovered)) | length}' "$LOG"
```

## 2. Present a short report

Lead with the headline (e.g. "sheepdog blocked 14 convention detours across 3
sessions this week; all were recovered by invoking the right skill"), then the
breakdowns. Keep it to what the numbers actually show.

## 3. Turn numbers into advice

The log is a signal about the *rules and skills*, not just about Claude:

- Many `no-skill` / `wrong-skill` blocks on one rule → Claude isn't recognizing
  when that skill applies. Improve that rule's `desc` in config.json and the
  skill's frontmatter `description` so routing is unambiguous.
- Many `expired` blocks → legitimate flows outlive the window. Suggest raising
  `window` in config.json.
- A file that is blocked and never recovered → Claude may be routing around the
  gate (e.g. via Bash). Worth flagging to the user.
- Zero blocks over a long range → either the flock is well herded, or the rules
  don't cover the paths being edited. Compare `rules` globs against recent git
  activity before declaring victory.
