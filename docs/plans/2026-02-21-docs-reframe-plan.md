# Documentation Reframe + Settings Patching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reframe README around .env protection, update agent instructions (CLAUDE.sample.md + hard-coded copy), and add Claude settings patching to onboard-claude.

**Architecture:** Three documentation files updated for consistent messaging, one code change to onboard-claude for settings patching. The CLAUDE.sample.md and `_claude_instructions()` in psst must always be identical.

**Tech Stack:** Bash, JSON (minimal manipulation for settings file)

---

### Task 1: Update CLAUDE.sample.md and `_claude_instructions()` with .env rules

The agent instructions need to reflect .env overrides and add .env to the never-read list. CLAUDE.sample.md and the hard-coded `_claude_instructions()` in `psst` must be kept in sync.

**Files:**
- Modify: `CLAUDE.sample.md`
- Modify: `psst:179-218` (`_claude_instructions` function)

**Step 1: Write the failing test**

Update the existing `test_onboard_claude_creates_new` test in `test-psst.sh` to also check for .env-related content. Add a new test before `# ── Run all tests`:

```bash
test_onboard_claude_includes_env_rules() {
    local out
    out=$("$PSST" onboard-claude 2>&1)
    local content
    content=$(cat CLAUDE.md)
    assert_contains "$content" "NEVER read .env"
    assert_contains "$content" "psst get -v"
    assert_contains "$content" "psst list"
    assert_contains "$content" ".env Override"
}
```

Add runner entry in the "onboard-claude" section:

```bash
run_test "includes .env rules"                test_onboard_claude_includes_env_rules
```

**Step 2: Run test to verify it fails**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New test fails (current instructions don't mention .env rules)

**Step 3: Update CLAUDE.sample.md**

Replace the entire content of `CLAUDE.sample.md` with:

```markdown
# Secret Management (psst)

This project uses `psst` for secrets. Secrets are encrypted at rest and injected into subprocesses at runtime — they never appear in your context. If the project has a `.env` file, psst reads it automatically so those values stay out of your context too.

## Usage

```bash
psst SECRET -- command                  # inject one secret
psst SECRET_A SECRET_B -- command       # inject multiple
psst run command                        # inject all secrets (.env + vault)
psst list                               # see available secrets and their source
psst get -v NAME                        # check where a value comes from
```

## .env Override

If a `.env` file exists in the current directory, its non-empty values override vault secrets automatically. You don't need to do anything special — `psst run`, `psst SECRET -- cmd`, and `psst get` all respect `.env` overrides.

Use `psst list` to see where each secret comes from:
```
API_KEY       (.env overrides vault)
DB_URL        (vault)
LOCAL_TOKEN   (.env)
```

## Examples

```bash
psst STRIPE_KEY -- curl -H "Authorization: Bearer $STRIPE_KEY" https://api.stripe.com
psst AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY -- aws s3 ls
psst run ./deploy.sh
```

## Shell Gotcha

The `--` syntax splits args by shell rules. Pipes, semicolons, and multi-statement commands break. Workarounds:
- Wrap in bash: `psst TOKEN -- bash -c 'cmd1 | cmd2'`
- Pipe from file: `psst TOKEN -- psql -f query.sql`
- Use `psst run` when you need all secrets anyway

## Rules

- NEVER read secret values — no `psst get`, no `cat .psst/`, no `cat ~/.ssh/.psst_*`
- NEVER read `.env` files directly — psst handles `.env` for you
- NEVER ask the user to paste secrets into the conversation
- ALWAYS use `psst SECRET -- command` or `psst run command`
- If a secret is missing, tell the user: "Please run `psst set SECRET_NAME` to add it."
- If you're unsure what secrets exist, run `psst list`
```

**Step 4: Update `_claude_instructions()` in psst**

Replace lines 179-218 in `psst` with the same content wrapped in the function. The heredoc content between `CLAUDE_EOF` markers must be identical to `CLAUDE.sample.md`:

```bash
# Embedded CLAUDE.md instructions for psst usage
_claude_instructions() {
    cat <<'CLAUDE_EOF'
# Secret Management (psst)

This project uses `psst` for secrets. Secrets are encrypted at rest and injected into subprocesses at runtime — they never appear in your context. If the project has a `.env` file, psst reads it automatically so those values stay out of your context too.

## Usage

```bash
psst SECRET -- command                  # inject one secret
psst SECRET_A SECRET_B -- command       # inject multiple
psst run command                        # inject all secrets (.env + vault)
psst list                               # see available secrets and their source
psst get -v NAME                        # check where a value comes from
```

## .env Override

If a `.env` file exists in the current directory, its non-empty values override vault secrets automatically. You don't need to do anything special — `psst run`, `psst SECRET -- cmd`, and `psst get` all respect `.env` overrides.

Use `psst list` to see where each secret comes from:
```
API_KEY       (.env overrides vault)
DB_URL        (vault)
LOCAL_TOKEN   (.env)
```

## Examples

```bash
psst STRIPE_KEY -- curl -H "Authorization: Bearer $STRIPE_KEY" https://api.stripe.com
psst AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY -- aws s3 ls
psst run ./deploy.sh
```

## Shell Gotcha

The `--` syntax splits args by shell rules. Pipes, semicolons, and multi-statement commands break. Workarounds:
- Wrap in bash: `psst TOKEN -- bash -c 'cmd1 | cmd2'`
- Pipe from file: `psst TOKEN -- psql -f query.sql`
- Use `psst run` when you need all secrets anyway

## Rules

- NEVER read secret values — no `psst get`, no `cat .psst/`, no `cat ~/.ssh/.psst_*`
- NEVER read `.env` files directly — psst handles `.env` for you
- NEVER ask the user to paste secrets into the conversation
- ALWAYS use `psst SECRET -- command` or `psst run command`
- If a secret is missing, tell the user: "Please run `psst set SECRET_NAME` to add it."
- If you're unsure what secrets exist, run `psst list`
CLAUDE_EOF
}
```

**Step 5: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Step 6: Commit**

```bash
git add CLAUDE.sample.md psst test-psst.sh
git commit -m "docs: update agent instructions with .env override rules"
```

---

### Task 2: Add settings patching to `onboard-claude`

Add Claude Code settings patching to deny reading .env and .psst files.

**Files:**
- Modify: `psst:563-601` (`cmd_onboard_claude`)
- Modify: `test-psst.sh`

**Step 1: Write the failing tests**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_onboard_claude_creates_settings() {
    # onboard-claude should create .claude/settings.json with deny rules
    "$PSST" onboard-claude 2>/dev/null
    [[ -f ".claude/settings.json" ]]
    local content
    content=$(cat .claude/settings.json)
    assert_contains "$content" "Read(.env)"
    assert_contains "$content" "Read(.psst/**)"
}

test_onboard_claude_settings_idempotent() {
    # Running twice should not duplicate deny rules
    "$PSST" onboard-claude 2>/dev/null
    "$PSST" onboard-claude 2>/dev/null
    local content
    content=$(cat .claude/settings.json)
    # Count occurrences of Read(.env) — should be exactly 1
    local count
    count=$(grep -o 'Read(.env)' .claude/settings.json | wc -l | tr -d ' ')
    assert_eq "$count" "1"
}

test_onboard_claude_preserves_existing_settings() {
    # If .claude/settings.json already exists with other content, preserve it
    mkdir -p .claude
    cat > .claude/settings.json <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(npm test)"
    ]
  }
}
EOF
    "$PSST" onboard-claude 2>/dev/null
    local content
    content=$(cat .claude/settings.json)
    assert_contains "$content" "Bash(npm test)"
    assert_contains "$content" "Read(.env)"
}
```

Add runner entries in the "onboard-claude" section:

```bash
run_test "creates .claude/settings.json"      test_onboard_claude_creates_settings
run_test "settings patching idempotent"       test_onboard_claude_settings_idempotent
run_test "preserves existing settings"        test_onboard_claude_preserves_existing_settings
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail

**Step 3: Add `_patch_claude_settings()` helper and call from `cmd_onboard_claude`**

Add a new helper function in the Helpers section of `psst`, after `_claude_instructions()` and before the `# ── Commands` marker:

```bash
# Patch .claude/settings.json with deny rules for sensitive files
_patch_claude_settings() {
    local settings_dir=".claude"
    local settings_file="$settings_dir/settings.json"

    local -a deny_rules=(
        'Read(.env)'
        'Read(.env.*)'
        'Read(.psst/**)'
    )

    mkdir -p "$settings_dir"

    # Check if settings file exists and already has our deny rules
    if [[ -f "$settings_file" ]]; then
        if grep -q 'Read(.psst/\*\*)' "$settings_file" 2>/dev/null; then
            info "claude settings already contain psst deny rules"
            return 0
        fi
    fi

    if [[ -f "$settings_file" ]]; then
        # File exists — need to merge deny rules into existing structure
        # Check if permissions.deny already exists
        if grep -q '"deny"' "$settings_file" 2>/dev/null; then
            # Append our rules to existing deny array
            # Find the deny array closing bracket and insert before it
            local deny_entries=""
            for rule in "${deny_rules[@]}"; do
                deny_entries="${deny_entries}      \"${rule}\",\n"
            done
            # Remove trailing comma+newline, add newline
            deny_entries=$(printf '%b' "$deny_entries" | sed '$ s/,$//')

            # Insert before the closing ] of the deny array
            local tmp
            tmp=$(mktemp)
            awk -v rules="$deny_entries" '
                /\"deny\"/ { in_deny=1 }
                in_deny && /\]/ {
                    # Print comma after last existing entry if needed
                    sub(/\]/, ",\n" rules "\n    ]")
                    in_deny=0
                }
                { print }
            ' "$settings_file" > "$tmp"
            mv "$tmp" "$settings_file"
        elif grep -q '"permissions"' "$settings_file" 2>/dev/null; then
            # permissions exists but no deny — add deny array
            local tmp
            tmp=$(mktemp)
            awk '
                /\"permissions\"/ && /\{/ {
                    print
                    print "    \"deny\": ["
                    print "      \"Read(.env)\","
                    print "      \"Read(.env.*)\","
                    print "      \"Read(.psst/**)\""
                    print "    ],"
                    next
                }
                { print }
            ' "$settings_file" > "$tmp"
            mv "$tmp" "$settings_file"
        else
            # No permissions key — add it
            local tmp
            tmp=$(mktemp)
            awk '
                /^\{/ && !done {
                    print
                    print "  \"permissions\": {"
                    print "    \"deny\": ["
                    print "      \"Read(.env)\","
                    print "      \"Read(.env.*)\","
                    print "      \"Read(.psst/**)\""
                    print "    ]"
                    print "  },"
                    done=1
                    next
                }
                { print }
            ' "$settings_file" > "$tmp"
            mv "$tmp" "$settings_file"
        fi
    else
        # No settings file — create fresh
        cat > "$settings_file" <<'SETTINGS_EOF'
{
  "permissions": {
    "deny": [
      "Read(.env)",
      "Read(.env.*)",
      "Read(.psst/**)"
    ]
  }
}
SETTINGS_EOF
    fi

    info "added file restrictions to .claude/settings.json (defense-in-depth)"
}
```

Then add a call to `_patch_claude_settings` at the end of `cmd_onboard_claude`. Find the three return points in `cmd_onboard_claude` (Cases 1, 2, 3) and refactor so that settings patching happens after CLAUDE.md is handled, regardless of which case was taken. The simplest approach: remove the `return 0` statements from Cases 1-3 and add `_patch_claude_settings` at the end of the function:

Replace `cmd_onboard_claude` with:

```bash
cmd_onboard_claude() {
    local claude_md="CLAUDE.md"
    local instructions
    instructions=$(_claude_instructions)

    # Case 1: No CLAUDE.md — create it directly
    if [[ ! -f "$claude_md" ]]; then
        printf '%s\n' "$instructions" > "$claude_md"
        info "created $claude_md with psst instructions"
    elif grep -q "Secret Management (psst)" "$claude_md" 2>/dev/null; then
        # Already has psst instructions
        info "$claude_md already contains psst instructions"
    elif command -v claude &>/dev/null; then
        # Case 2: CLAUDE.md exists — try Claude CLI for smart merge
        info "using Claude to integrate psst instructions into existing $claude_md"
        claude -p "Below are instructions for using the psst command. Please integrate these instructions (unmodified) directly into the existing @$claude_md file where the instructions make the most sense contextually within the document.

<psst-instructions>
${instructions}
</psst-instructions>"
        info "psst instructions integrated into $claude_md"
    else
        # Case 3: Fallback — append with separator
        {
            echo ""
            echo "---"
            echo ""
            printf '%s\n' "$instructions"
        } >> "$claude_md"
        info "claude CLI not found. Instructions appended to end of $claude_md — you may want to reorganize."
    fi

    # Always patch Claude settings
    _patch_claude_settings
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: onboard-claude patches .claude/settings.json with deny rules

Adds Read deny rules for .env, .env.*, and .psst/** as defense-in-depth.
Settings patching is idempotent and preserves existing settings content."
```

---

### Task 3: Rewrite README.md

Reframe the README with result-oriented messaging, .env protection as first-class, polished prose.

**Files:**
- Modify: `README.md`

**Step 1: No test needed** (pure documentation)

**Step 2: Rewrite README.md**

Replace the entire content of `README.md`. Key changes:
- Reframe tagline: focus on keeping secrets out of AI context, not the vault mechanism
- Position .env protection alongside vault as dual modes
- Add .env Override section to Usage
- Update test count from 53 to 78
- Keep existing architecture/security sections with .env references added
- Polish prose to be result-oriented (HashiCorp Vault style)

The new README should follow this structure:

```
# psst

[Result-oriented tagline - secrets stay out of AI context]

[Elevator pitch: .env protection + encrypted vault, pure bash]

## Why this exists
[Updated to position .env protection as first-class. Keep attribution to original psst.]

## Quick start
[Same as current but add: creating a .env for per-user overrides]

## Usage
### For humans
[Updated command list with new flags]

### For agents
[Same subprocess injection explanation]

### .env Override
[New section: how .env files work with psst]

### Secret history
[Same as current]

## How it works
[Same architecture + mention .env override layer]

### Security model
[Same + .env note + mention settings patching]

## Testing
[Update test count to 78]

## Requirements
[Same]

## Acknowledgments
[Same]

## License
[Same]
```

The implementer should write polished, result-oriented prose. The tone should be confident and precise — similar to HashiCorp Vault documentation. Avoid marketing fluff. Lead with what the tool does for you, not how it works internally.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: reframe README around .env protection and secret isolation"
```

---

### Task 4: Final validation

**Step 1: Run the full test suite**

Run: `bash test-psst.sh`
Expected: All tests pass

**Step 2: Verify CLAUDE.sample.md matches `_claude_instructions()` output**

Run: `diff <(bash psst onboard-claude-dump 2>/dev/null || true) CLAUDE.sample.md` — actually, simpler approach: manually compare. The content between the `CLAUDE_EOF` heredoc markers in `psst` should be identical to `CLAUDE.sample.md`.

A quick sanity check:
```bash
# Extract _claude_instructions output and compare to CLAUDE.sample.md
diff <(sed -n '/^_claude_instructions/,/^CLAUDE_EOF/p' psst | head -n -1 | tail -n +3) CLAUDE.sample.md
```

Expected: No differences (or whitespace-only)

**Step 3: Verify .claude/settings.json deny rules work**

```bash
cd /tmp && mkdir psst-settings-test && cd psst-settings-test
/path/to/psst init
/path/to/psst onboard-claude
cat .claude/settings.json
# Should show deny rules for .env, .env.*, .psst/**
cd / && rm -rf /tmp/psst-settings-test
```

**Step 4: Commit any final fixups if needed**

```bash
git add -A
git commit -m "chore: final validation fixups"
```
