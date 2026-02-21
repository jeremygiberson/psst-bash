# Documentation Reframe + Settings Patching Design

## Problem

The README and agent instructions don't reflect the new .env override feature. The messaging needs to shift from "encrypted vault for AI agents" to a result-oriented narrative: psst keeps secrets out of AI context, whether they live in .env files or an encrypted vault. Additionally, onboard-claude should patch Claude Code settings to deny reading .env and .psst files as defense-in-depth.

## Approach

Unified rewrite: update README with new framing, update CLAUDE.sample.md and hard-coded `_claude_instructions()` in sync, and add settings patching to onboard-claude. All in one pass for a coherent narrative.

## Design

### 1. README.md Rewrite

- Reframe tagline: result-oriented, polished prose (HashiCorp Vault style)
- Position .env protection as a first-class use case alongside the vault
- Add .env Override section to Usage
- Update test count to 78
- Keep existing sections (Quick Start, How it works, Security model) with .env references where relevant

### 2. CLAUDE.sample.md + `_claude_instructions()` Update

Both updated in sync (identical content). Changes:
- Add .env override usage examples (`psst get -v`, `psst list` showing sources)
- Add .env to NEVER-read rules: "NEVER read .env files"
- Add `psst get -v NAME` as recommended way to check value source
- Keep existing rules about .psst/ and ~/.ssh/.psst_*

### 3. `onboard-claude` Settings Patching

After writing CLAUDE.md instructions, `onboard-claude` will also:
1. Create `.claude/settings.json` if needed
2. Add deny rules: `Read(.env)`, `Read(.env.*)`, `Read(.psst/**)`, `Read(~/.ssh/.psst_*)`
3. Skip if deny rules already present (idempotent)
4. Print caveat: defense-in-depth, not sole security mechanism
5. Use basic JSON construction (the settings file structure is simple)

### 4. Tests

- onboard-claude creates/patches .claude/settings.json with deny rules
- Idempotency (running twice doesn't duplicate deny rules)
- Updated CLAUDE.sample.md content matches _claude_instructions() output
