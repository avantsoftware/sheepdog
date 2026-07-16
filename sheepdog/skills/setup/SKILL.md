---
description: Scaffold the sheepdog configuration in the current project. Use when the user wants to set up, enable, or bootstrap the sheepdog gate for a repository — creates .claude/sheepdog/config.json and wires .gitignore. Not project-specific; it writes a starter config the user then customizes.
---

# Set up sheepdog for this project

The `sheepdog` plugin is a generic engine: three hooks that read **project-owned**
rules from `.claude/sheepdog/config.json`. The plugin ships no rules of its own.
This skill scaffolds that config for the current project.

Do the following, in order. Adapt paths/skills to what the project actually has —
do not blindly paste the examples.

## 1. Discover the project's skills and governed paths

- List the project's skills: look under `.claude/skills/*/SKILL.md` (and any plugin
  skills the user mentions). These are the skills the gate can require.
- Identify which directories should be gated (where hand-edits without a skill are a
  mistake). Ask the user if it isn't obvious. Common picks: source dirs with strong
  conventions, and test dirs.

## 2. Create `.claude/sheepdog/config.json`

One JSON file holds the whole gate: the authorization window, override skills, and
the ordered glob→skill rules. The routing table injected on every prompt is
GENERATED from `rules`, so the reminder and the gate can never drift apart.

Starter template (replace the example rule with this project's real globs and skill
names; drop the fields the project doesn't need):

```json
{
  "window": 300,
  "overrides": [],
  "rules": [
    { "glob": "*/path/to/governed/dir/*", "skill": "the-skill-for-that-dir", "desc": "optional label for the routing table" }
  ]
}
```

Field notes (JSON has no comments — explain choices to the user in chat instead):

- `window` — seconds a stamped skill stays valid (default 300; omit if default is fine).
- `overrides` — skills allowed to edit ANY governed path (orchestrator-style skills);
  omit if none.
- `rules` — **first matching glob wins**, so order specific → general. Globs use
  shell-case semantics: `*` matches any run of characters (including `/`), `?`
  matches exactly one. They match against the absolute file path.
- `reminder` (optional) — replaces the default preamble injected on every prompt.
- Unknown keys are rejected and the gate fails closed — typos can't silently
  disable enforcement.

## 3. Ignore the runtime stamp

The hooks write `.claude/sheepdog/.skill-used` at runtime (the "last skill invoked"
timestamp). It must not be committed. Add this line to the project's `.gitignore` if
missing:

```
.claude/sheepdog/.skill-used
```

Commit `config.json` (it is shared team rules); do not commit `.skill-used`.

## 4. Migrate a legacy config (only if present)

If `.claude/sheepdog/` contains the old `gate-map.conf` (and `routing.md`) format,
the hooks still honor it, but `config.json` supersedes both. Convert each
`<glob>|<skill>` line into a `rules` entry and each `@override|<skill>` line into
an `overrides` entry, then delete `gate-map.conf` and `routing.md`.

## 5. Activate

Tell the user the plugin must be enabled for the hooks to run, and that the hooks
need `jq` (preinstalled on macOS 15+; a standard package elsewhere). Warn that once
this project is governed, a missing jq or a broken config blocks ALL edits — the
gate fails closed rather than silently off:

```
/plugin marketplace add <path-to-marketplace>
/plugin install sheepdog@<marketplace-name>
/reload-plugins
```

Then verify: invoking a skill stamps `.claude/sheepdog/.skill-used`, and editing a
governed file without the matching skill is blocked with a message pointing at
`config.json`.
