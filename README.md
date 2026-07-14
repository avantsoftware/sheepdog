# skill-first

A generic **skill-first gate** for [Claude Code](https://code.claude.com), packaged as
a plugin. It nudges — and when needed, forces — Claude to invoke the *right* skill
before editing files that have strong conventions, so hand-edits that skip a project's
workflow get blocked instead of merged.

The plugin is **project-agnostic**: it ships zero rules of its own. Each project
declares what is governed and by which skill, in `.claude/skill-first/`. On a project
that hasn't opted in, the plugin is a silent no-op.

## How it works

Three hooks, all reading project-owned config from `$CLAUDE_PROJECT_DIR/.claude/skill-first/`:

| Hook | Event | What it does |
| --- | --- | --- |
| `skill-reminder.sh` | `UserPromptSubmit` | Injects `routing.md` (the task→skill table) into context on every prompt. |
| `stamp-skill.sh` | `PostToolUse(Skill)` | Records `<timestamp> <skill>` in `.skill-used` whenever a skill is invoked. |
| `require-skill.sh` | `PreToolUse(Edit\|Write\|MultiEdit)` | Looks up the edited file in `gate-map.conf`; blocks the edit unless the matching skill was stamped within the last 5 minutes. |

No `.claude/skill-first/` directory → nothing is injected, nothing is blocked.

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

- **`.claude/skill-first/gate-map.conf`** — path→skill rules (commit this).
- **`.claude/skill-first/routing.md`** — the reminder + routing table injected each prompt (commit this).
- a `.gitignore` entry for **`.claude/skill-first/.skill-used`** (runtime state — do not commit).

## `gate-map.conf` format

First matching glob wins; order specific → general. Blank lines and `#` comments are ignored.

```
# <glob>|<skill>   — editing a file matching <glob> requires <skill> first
# @override|<skill> — <skill> may edit ANY governed file (repeatable)
# First match wins; order specific -> general.

@override|edit-or-create-endpoint
*/app/operations/base/*|edit-or-create-base-operation
*/app/operations/*|edit-or-create-action-operation
*/app/serializers/*|edit-or-create-serializer
```

Use `@override` for orchestrator-style skills that legitimately compose several
governed edits in one flow.

## Distribute to a team

Commit `.claude/skill-first/` in the target repo, then have teammates run the install
commands — or wire it into the repo's `.claude/settings.json` so it's automatic:

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
- The gate window is 5 minutes (`WINDOW` in `require-skill.sh`).
