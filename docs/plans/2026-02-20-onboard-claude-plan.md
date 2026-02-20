# `psst onboard-claude` Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `psst onboard-claude` command that installs psst usage instructions into a project's CLAUDE.md, using Claude CLI for intelligent merging when the file already exists.

**Architecture:** New `_claude_instructions()` helper returns the embedded CLAUDE.sample.md content as a heredoc. New `cmd_onboard_claude()` branches on whether CLAUDE.md exists: creates it directly if not, invokes `claude -p` with `@CLAUDE.md` reference if so, falls back to append if `claude` CLI is missing.

**Tech Stack:** Bash, Claude CLI (optional runtime dependency for merge path)

---

### Task 1: Add `_claude_instructions()` helper

**Files:**
- Modify: `psst` (insert after `_get_current()` at line 78, before the Commands section at line 80)

**Step 1: Write the `_claude_instructions()` function**

Add after line 78 (`}` closing `_get_current`) and before line 80 (`# ── Commands`):

```bash
# Embedded CLAUDE.md instructions for psst usage
_claude_instructions() {
    cat <<'CLAUDE_EOF'
# Secret Management (psst)

This project uses `psst` for secrets. Secrets are encrypted at rest and injected into subprocesses at runtime — they never appear in your context.

## Usage

```bash
psst SECRET -- command                  # inject one secret
psst SECRET_A SECRET_B -- command       # inject multiple
psst run command                        # inject all vault secrets
psst list                               # see available secrets
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
- NEVER ask the user to paste secrets into the conversation
- ALWAYS use `psst SECRET -- command` or `psst run command`
- If a secret is missing, tell the user: "Please run `psst set SECRET_NAME` to add it."
- If you're unsure what secrets exist, run `psst list`
CLAUDE_EOF
}
```

**Step 2: Verify the script still parses**

Run: `bash -n psst`
Expected: no output (clean parse)

**Step 3: Commit**

```bash
git add psst
git commit -m "feat: add _claude_instructions() helper with embedded content"
```

---

### Task 2: Add `cmd_onboard_claude()` command function

**Files:**
- Modify: `psst` (insert before `cmd_help()`, after the last command function `cmd_exec_with_secrets()`)

**Step 1: Write the test functions**

Add to `test-psst.sh` before the `# ── Run all tests` section:

```bash
test_onboard_claude_creates_new() {
    # Should create CLAUDE.md when it doesn't exist
    local out
    out=$("$PSST" onboard-claude 2>&1)
    [[ -f "CLAUDE.md" ]]
    assert_contains "$(cat CLAUDE.md)" "Secret Management (psst)"
    assert_contains "$(cat CLAUDE.md)" "psst SECRET -- command"
    assert_contains "$(cat CLAUDE.md)" "NEVER read secret values"
    assert_contains "$out" "created CLAUDE.md"
}

test_onboard_claude_already_has_psst() {
    # Should detect existing psst instructions and skip
    "$PSST" onboard-claude 2>/dev/null
    local out
    out=$("$PSST" onboard-claude 2>&1)
    assert_contains "$out" "already contains"
}

test_onboard_claude_appends_fallback() {
    # When CLAUDE.md exists and claude CLI is not available,
    # should append with separator
    echo "# My Project" > CLAUDE.md
    echo "" >> CLAUDE.md
    echo "Some existing instructions." >> CLAUDE.md
    # Use PATH manipulation to ensure 'claude' is not found
    local out
    out=$(PATH="/usr/bin:/bin" "$PSST" onboard-claude 2>&1)
    assert_contains "$(cat CLAUDE.md)" "# My Project"
    assert_contains "$(cat CLAUDE.md)" "Some existing instructions."
    assert_contains "$(cat CLAUDE.md)" "Secret Management (psst)"
}
```

**Step 2: Add test runner entries**

Add a new section to the test runner at the bottom of `test-psst.sh`, before the summary:

```bash
echo "onboard-claude"
run_test "creates CLAUDE.md when missing"     test_onboard_claude_creates_new
run_test "skips if psst already present"      test_onboard_claude_already_has_psst
run_test "appends when claude CLI missing"    test_onboard_claude_appends_fallback
echo ""
```

**Step 3: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -20`
Expected: 3 new tests FAIL (command doesn't exist yet)

**Step 4: Write `cmd_onboard_claude()`**

Add to `psst` before `cmd_help()`:

```bash
cmd_onboard_claude() {
    local claude_md="CLAUDE.md"
    local instructions
    instructions=$(_claude_instructions)

    # Case 1: No CLAUDE.md — create it directly
    if [[ ! -f "$claude_md" ]]; then
        echo "$instructions" > "$claude_md"
        info "created $claude_md with psst instructions"
        return 0
    fi

    # Check if psst instructions already present
    if grep -q "Secret Management (psst)" "$claude_md" 2>/dev/null; then
        info "$claude_md already contains psst instructions"
        return 0
    fi

    # Case 2: CLAUDE.md exists — try Claude CLI for smart merge
    if command -v claude &>/dev/null; then
        info "using Claude to integrate psst instructions into existing $claude_md"
        claude -p "Below are instructions for using the psst command. Please integrate these instructions (unmodified) directly into the existing @$claude_md file where the instructions make the most sense contextually within the document.

<psst-instructions>
${instructions}
</psst-instructions>"
        info "psst instructions integrated into $claude_md"
        return 0
    fi

    # Case 3: Fallback — append with separator
    {
        echo ""
        echo "---"
        echo ""
        echo "$instructions"
    } >> "$claude_md"
    info "claude CLI not found. Instructions appended to end of $claude_md — you may want to reorganize."
}
```

**Step 5: Run tests to verify they pass**

Run: `bash test-psst.sh 2>&1 | tail -20`
Expected: All tests PASS including the 3 new onboard-claude tests

**Step 6: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: add onboard-claude command with tests"
```

---

### Task 3: Wire up dispatch and help text

**Files:**
- Modify: `psst` (main dispatch and cmd_help)

**Step 1: Write the test**

Add to `test-psst.sh` test functions:

```bash
test_help_shows_onboard_claude() {
    local out
    out=$("$PSST" help)
    assert_contains "$out" "onboard-claude"
}
```

Add to the runner in the "help" section:

```bash
run_test "help shows onboard-claude"          test_help_shows_onboard_claude
```

**Step 2: Run test to verify it fails**

Run: `bash test-psst.sh 2>&1 | grep "onboard"`
Expected: FAIL

**Step 3: Add dispatch entry in `main()`**

In the `case` block in `main()`, add before the `help` case:

```bash
        onboard-claude) shift; cmd_onboard_claude "$@" ;;
```

**Step 4: Add help text**

In `cmd_help()`, add a line after the `psst run` entry:

```
  psst onboard-claude              Add psst instructions to CLAUDE.md
```

**Step 5: Run all tests**

Run: `bash test-psst.sh`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: wire onboard-claude into dispatch and help"
```

---

### Task 4: Manual smoke test

**Step 1: Test fresh CLAUDE.md creation**

```bash
cd "$(mktemp -d)" && /Users/jeremygiberson/gitprojects/psst-bash/psst onboard-claude
cat CLAUDE.md
```

Expected: CLAUDE.md created with full psst instructions

**Step 2: Test idempotency**

```bash
/Users/jeremygiberson/gitprojects/psst-bash/psst onboard-claude
```

Expected: "already contains psst instructions" message

**Step 3: Test append fallback**

```bash
cd "$(mktemp -d)"
echo -e "# My Project\n\nBuild instructions here." > CLAUDE.md
PATH="/usr/bin:/bin" /Users/jeremygiberson/gitprojects/psst-bash/psst onboard-claude
cat CLAUDE.md
```

Expected: Original content preserved, psst instructions appended after `---` separator, warning about reorganizing

**Step 4: Commit any fixes if needed, then final commit**

```bash
git add psst test-psst.sh
git commit -m "feat: psst onboard-claude command complete"
```
