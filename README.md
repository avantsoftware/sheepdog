# skill-first

A generic **skill-first gate** for [Claude Code](https://code.claude.com), packaged as
a plugin. It nudges — and when needed, forces — Claude to invoke the *right* skill
before editing files that have strong conventions, so hand-edits that skip a project's
workflow get blocked instead of merged.

The plugin is **project-agnostic**: it ships zero rules of its own. Each project
declares what is governed and by which skill in `.claude/skill-first/config.json`. On
a project that hasn't opted in, the plugin is a silent no-op.

## How it works

Three bash hooks, all reading project-owned config from
`$CLAUDE_PROJECT_DIR/.claude/skill-first/`:

| Hook | Event | What it does |
| --- | --- | --- |
| `skill-reminder.sh` | `UserPromptSubmit` | Injects a reminder + the path→skill routing table (generated from `rules`) into context on every prompt. |
| `stamp-skill.sh` | `PostToolUse(Skill)` | Records `<timestamp> <skill>` in `.skill-used` whenever a skill is invoked. |
| `require-skill.sh` | `PreToolUse(Edit\|Write\|MultiEdit)` | Looks up the edited file in `rules`; blocks the edit unless the matching skill was stamped within the window. |

No config → nothing is injected, nothing is blocked.

**Requires `jq`.** macOS 15+ ships it at `/usr/bin/jq`; on Linux it's a standard
package. The hooks also look for it in common install locations (nix profiles,
homebrew, `~/.local/bin`) in case Claude Code runs with a minimal PATH. If jq can't
be found at all, a **governed** project **fails closed**: every edit is blocked with
a message saying what to install — the gate never silently turns itself off. The
same loud-over-silent policy applies to a config that doesn't parse or contains an
unknown/misspelled key. Ungoverned projects are unaffected either way.

## Install

```
/plugin marketplace add avantsoftware/skill-first
/plugin install skill-first@avantsoft
/reload-plugins
```

(For local development: `claude --plugin-dir ./skill-first`.)

## Set up a project

Run the bundled skill in the project you want to gate:

```
/skill-first:setup
```

It scaffolds:

- **`.claude/skill-first/config.json`** — the whole gate: window, overrides, rules
  (commit this).
- a `.gitignore` entry for **`.claude/skill-first/.skill-used`** (runtime state — do
  not commit).

## What it looks like in practice

On every prompt, Claude sees the routing table (generated from `rules`):

```
[skill-first] STOP. Before editing files in this project, invoke the matching skill
below via the Skill tool FIRST, then edit. [...]

Routing (what you're touching -> required skill):
- */app/operations/base/* (base operations) -> edit-or-create-base-operation
- */app/operations/* -> edit-or-create-action-operation
```

If Claude edits a governed file anyway, the edit is rejected and the error tells it
exactly how to recover:

```
  ✗  skill-first blocked this edit

     File       /repo/app/operations/create_user.rb
     Why        No skill has been invoked yet, so no edit to this path is authorized.
     Required   the "edit-or-create-action-operation" skill

  →  Do this now: invoke the Skill tool with skill "edit-or-create-action-operation", then re-apply this exact edit.
     This path is governed by .claude/skill-first/config.json; the skill stays valid for 5 min after you invoke it.
```

Claude invokes the skill (which stamps `.skill-used`), re-applies the edit, and the
gate lets it through.

## `config.json` reference

```json
{
  "window": 600,
  "overrides": ["edit-or-create-endpoint"],
  "rules": [
    { "glob": "*/app/operations/base/*", "skill": "edit-or-create-base-operation", "desc": "base operations" },
    { "glob": "*/app/operations/*", "skill": "edit-or-create-action-operation" },
    { "glob": "*/app/serializers/*", "skill": "edit-or-create-serializer" }
  ]
}
```

- **`window`** (optional, default `300`) — seconds a stamped skill stays valid.
- **`reminder`** (optional) — replaces the default preamble injected on every prompt;
  the routing table is appended after it either way.
- **`overrides`** (optional) — skills that may edit ANY governed path, e.g. an
  orchestrator skill that composes several governed edits in one flow.
- **`rules`** — ordered list of `{ "glob", "skill", "desc"? }`. **First matching glob
  wins**, so order specific → general. `desc` is an optional label shown in the
  routing table.
- Globs have shell-`case` semantics: `*` matches any run of characters **including
  `/`**, `?` matches exactly one. Patterns match against the absolute file path.
- Unknown keys (top-level or inside a rule) are rejected and the gate fails closed,
  so a typo like `"ruls"` can't silently disable enforcement.
- The routing table Claude sees is generated from `rules`, so the reminder and the
  gate can never drift apart.

## Legacy format

Projects set up before `config.json` used `gate-map.conf` (`<glob>|<skill>` lines,
`@override|<skill>` for overrides) plus a hand-written `routing.md`. Both are still
honored when `config.json` is absent; `config.json` supersedes them.
`/skill-first:setup` can migrate.

## Distribute to a team

Commit `.claude/skill-first/config.json` in the target repo, then have teammates run
the install commands — or wire it into the repo's `.claude/settings.json` so it's
automatic:

```json
{
  "extraKnownMarketplaces": {
    "avantsoft": { "source": { "source": "github", "repo": "avantsoftware/skill-first" } }
  },
  "enabledPlugins": { "skill-first@avantsoft": true }
}
```

## Notes

- State (`.skill-used`) always lives in the project dir, never in the plugin cache
  (`$CLAUDE_PLUGIN_ROOT` is read-only and changes on every update).
- The stamp holds only the LAST skill invoked — invoking any other skill between the
  required skill and the edit revokes the authorization. That's intentional: it forces
  the sequence "right skill → edit".
- JSON has no comments; use each rule's `desc` field to document intent.
