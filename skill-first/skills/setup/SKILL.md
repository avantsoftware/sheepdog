---
description: Scaffold the skill-first configuration in the current project. Use when the user wants to set up, enable, or bootstrap the skill-first gate for a repository — creates .claude/skill-first/gate-map.conf and routing.md and wires .gitignore. Not project-specific; it writes starter files the user then customizes.
---

# Set up skill-first for this project

The `skill-first` plugin is a generic engine: three hooks that read **project-owned**
rules from `.claude/skill-first/`. The plugin ships no rules of its own. This skill
scaffolds those rules for the current project.

Do the following, in order. Adapt paths/skills to what the project actually has —
do not blindly paste the examples.

## 1. Discover the project's skills and governed paths

- List the project's skills: look under `.claude/skills/*/SKILL.md` (and any plugin
  skills the user mentions). These are the skills the gate can require.
- Identify which directories should be gated (where hand-edits without a skill are a
  mistake). Ask the user if it isn't obvious. Common picks: source dirs with strong
  conventions, and test dirs.

## 2. Create `.claude/skill-first/gate-map.conf`

Maps a file glob to the skill required before editing it. **First matching glob
wins**, so order specific → general. Lines starting with `#` and blank lines are
ignored. Use `@override|<skill>` to let an orchestrator-style skill edit any governed
file (repeatable).

Starter template (replace the examples with this project's real globs and skill
names):

```
# <glob>|<skill>   — editing a file matching <glob> requires <skill> first.
# @override|<skill> — <skill> may edit ANY governed file (e.g. an orchestrator).
# First match wins; order specific -> general.

# @override|my-orchestrator-skill

# */path/to/governed/dir/*|the-skill-for-that-dir
```

## 3. Create `.claude/skill-first/routing.md`

This markdown is injected into context on every prompt (via the UserPromptSubmit
hook). Keep it a short, imperative reminder plus the glob→skill routing table, so the
model reaches for the right skill before the gate has to block it. Starter template:

```
[skill-first] STOP. Before editing files in this project, invoke the matching skill
below via the Skill tool FIRST, then edit. Edits to governed paths are hook-gated:
the gate requires the EXACT matching skill for that file (not just any skill), valid
for 5 min after you invoke it.

Routing (what you're touching -> skill):
- <describe a governed path> -> <the-skill-for-it>
```

Fill the routing table so it mirrors `gate-map.conf`.

## 4. Ignore the runtime stamp

The hooks write `.claude/skill-first/.skill-used` at runtime (the "last skill invoked"
timestamp). It must not be committed. Add this line to the project's `.gitignore` if
missing:

```
.claude/skill-first/.skill-used
```

Commit `gate-map.conf` and `routing.md` (they are shared team rules); do not commit
`.skill-used`.

## 5. Activate

Tell the user the plugin must be enabled for the hooks to run:

```
/plugin marketplace add <path-to-marketplace>
/plugin install skill-first@<marketplace-name>
/reload-plugins
```

Then verify: invoking a skill stamps `.claude/skill-first/.skill-used`, and editing a
governed file without the matching skill is blocked with a message pointing at
`gate-map.conf`.
