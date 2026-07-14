#!/usr/bin/env bash
# UserPromptSubmit: inject this project's skill-first routing table into context
# on every prompt. The table is project-owned markdown; the plugin ships none.
# No file -> the plugin is a no-op for this project (nothing injected).
# Scaffold the file with /skill-first:setup.
ROUTING="$CLAUDE_PROJECT_DIR/.claude/skill-first/routing.md"
[ -f "$ROUTING" ] && cat "$ROUTING"
exit 0
