# Design: `psst onboard-claude` command

**Date:** 2026-02-20

## Purpose

Add a command to psst that installs psst usage instructions into a project's `CLAUDE.md`, giving Claude Code the context it needs to use psst correctly.

## Behavior

`psst onboard-claude` adds psst usage instructions to `./CLAUDE.md` in the current directory.

### Path 1: No CLAUDE.md exists

Write the embedded psst instructions directly as `./CLAUDE.md`. No AI needed.

### Path 2: CLAUDE.md already exists

Invoke `claude -p` with a prompt that uses the `@CLAUDE.md` reference to let Claude load and edit the file directly:

```
claude -p "Below are instructions for using the psst command. Please integrate these instructions (unmodified) directly into the existing @CLAUDE.md file where the instructions make the most sense contextually within the document.

<psst-instructions>
...embedded content...
</psst-instructions>"
```

Claude determines the best placement within the existing document and edits the file in place.

**Fallback:** If `claude` CLI is not found on PATH, fall back to appending the instructions with a separator and print a warning suggesting the user review placement.

## Implementation details

### Embedded content

The CLAUDE.sample.md content is stored as a heredoc in a function `_claude_instructions()` that echoes the text. Keeps it in one place, easy to update, zero external dependencies.

### Command structure

- New function: `cmd_onboard_claude()`
- New dispatch entry in `main()`: `onboard-claude)`
- New help text entry in `cmd_help()`
- New helper: `_claude_instructions()` returning the embedded instructions

### Fallback append format

When Claude CLI is unavailable and CLAUDE.md exists:

```markdown
...existing content...

---

# Secret Management (psst)
...psst instructions...
```

Plus a stderr warning: `psst: claude CLI not found. Instructions appended to end of CLAUDE.md — you may want to reorganize.`

## Non-goals

- No support for targeting a different file path (current directory only)
- No `psst init` dependency (onboard-claude works independently of vault setup)
- No interactive mode or confirmation prompts
