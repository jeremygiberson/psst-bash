# .env Override Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow `.env` files to override vault secrets, with source annotations in `list` and `get -v`.

**Architecture:** Add `_load_env_file()` to parse `.env` into an associative array, `_resolve_secret()` to check .env first then vault, and `_env_source()` to report where a value came from. Modify `cmd_get`, `cmd_list`, `cmd_run`, and `cmd_exec_with_secrets` to use these helpers.

**Tech Stack:** Bash 4.0+ (associative arrays), OpenSSL (existing)

---

### Task 1: Extract shared .env parsing into `_parse_env_line()` helper

The .env parsing logic currently lives inline in `cmd_import`. We need to reuse it in `_load_env_file`. Extract the per-line parsing into a shared helper first.

**Files:**
- Modify: `psst:292-314` (cmd_import inline parsing)
- Modify: `psst:67` (add new helper after `_valid_name`)

**Step 1: Write the failing test**

Add to `test-psst.sh` before the `# ── Run all tests` line (before line 648):

```bash
test_import_still_works_after_refactor() {
    init_vault
    cat > test.env <<'EOF'
# comment
export KEY_ONE="value1"
KEY_TWO='value2'
KEY_THREE=value3

EOF
    local out
    out=$("$PSST" import test.env 2>&1)
    assert_contains "$out" "imported 3"
    assert_eq "$("$PSST" get KEY_ONE)" "value1"
    assert_eq "$("$PSST" get KEY_TWO)" "value2"
    assert_eq "$("$PSST" get KEY_THREE)" "value3"
}
```

Add the runner entry in the "import" runner section (after line 701):

```bash
run_test "import works after refactor"      test_import_still_works_after_refactor
```

**Step 2: Run test to verify it passes (baseline)**

Run: `bash test-psst.sh 2>&1 | tail -5`
Expected: All tests pass (this is a regression guard)

**Step 3: Extract `_parse_env_line()` helper**

Add after `_valid_name()` (after line 67 in `psst`):

```bash
# Parse a single .env line, outputting "name=value" to stdout.
# Returns 1 if line should be skipped (comment, blank, invalid).
_parse_env_line() {
    local line="$1"

    # Skip comments and blank lines
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1

    # Strip optional 'export ' prefix
    line="${line#export }"

    # Split on first '='
    local name="${line%%=*}"
    local value="${line#*=}"

    # Strip surrounding quotes from value
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"

    # Trim whitespace from name
    name=$(echo "$name" | xargs)

    [[ -n "$name" ]] && [[ -n "$value" ]] || return 1
    _valid_name "$name" 2>/dev/null || return 1

    printf '%s=%s\n' "$name" "$value"
}
```

Then refactor `cmd_import` to use it. Replace the while loop body (lines 292-322) with:

```bash
    local count=0
    while IFS= read -r line; do
        local parsed
        parsed=$(_parse_env_line "$line") || continue
        local name="${parsed%%=*}"
        local value="${parsed#*=}"

        local file
        file=$(_secret_file "$name")
        local encrypted
        encrypted=$(echo -n "$value" | _encrypt)
        echo -e "$(_timestamp)\t${encrypted}" >> "$file"
        chmod 600 "$file"
        count=$((count + 1))
    done <<< "$input"
```

**Step 4: Run all tests to verify refactor is clean**

Run: `bash test-psst.sh 2>&1 | tail -5`
Expected: All tests pass including the new regression test

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "refactor: extract _parse_env_line helper from cmd_import"
```

---

### Task 2: Add `_load_env_file()` helper

**Files:**
- Modify: `psst` (add helper after `_parse_env_line`)

**Step 1: Write the failing test**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_load_env_file_creates_overrides() {
    init_vault
    set_secret "VAULT_ONLY" "from_vault"
    cat > .env <<'EOF'
ENV_VAR=from_env
VAULT_ONLY=from_env_override
EOF
    # Use get -v to check that .env loading works
    # (This test will be expanded in Task 3 when get -v is implemented)
    local out
    out=$("$PSST" get VAULT_ONLY)
    assert_eq "$out" "from_env_override"
}

test_no_env_file_no_change() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    # No .env file present
    local out
    out=$("$PSST" get MY_KEY)
    assert_eq "$out" "vault_value"
}

test_empty_env_value_no_override() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=
EOF
    local out
    out=$("$PSST" get MY_KEY)
    assert_eq "$out" "vault_value"
}
```

Add runner entries. Create a new ".env override" section after "onboard-claude" runners (after line 745):

```bash
echo ".env override"
run_test "env file overrides vault"           test_load_env_file_creates_overrides
run_test "no env file uses vault"             test_no_env_file_no_change
run_test "empty env value no override"        test_empty_env_value_no_override
echo ""
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail (get still returns vault value, not .env override)

**Step 3: Implement `_load_env_file()` and `_resolve_secret()`**

Add after `_parse_env_line` in the Helpers section of `psst`:

```bash
# Global associative array for .env overrides
declare -A _ENV_OVERRIDES

# Load .env file from current directory into _ENV_OVERRIDES
_load_env_file() {
    _ENV_OVERRIDES=()
    [[ -f ".env" ]] || return 0

    local input
    input=$(cat ".env")
    while IFS= read -r line; do
        local parsed
        parsed=$(_parse_env_line "$line") || continue
        local name="${parsed%%=*}"
        local value="${parsed#*=}"
        _ENV_OVERRIDES["$name"]="$value"
    done <<< "$input"
}

# Resolve a secret: .env overrides win over vault
_resolve_secret() {
    local name="$1"
    _load_env_file
    if [[ -n "${_ENV_OVERRIDES[$name]+x}" ]] && [[ -n "${_ENV_OVERRIDES[$name]}" ]]; then
        printf '%s' "${_ENV_OVERRIDES[$name]}"
        return 0
    fi
    _get_current "$name"
}
```

Then modify `cmd_get` (line 199-207) to use `_resolve_secret`:

```bash
cmd_get() {
    need_vault
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: psst get <NAME>"
    _valid_name "$name"
    local val
    val=$(_resolve_secret "$name")
    printf '%s\n' "$val"
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: add _load_env_file and _resolve_secret helpers

.env file in current directory overrides vault values."
```

---

### Task 3: Add `get -v` and `get --vault-only` flags

**Files:**
- Modify: `psst` (`cmd_get` and add `_env_source` helper)

**Step 1: Write the failing tests**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_get_verbose_shows_vault_source() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    # No .env file
    local out
    out=$("$PSST" get -v MY_KEY 2>&1)
    assert_contains "$out" "vault_value"
    assert_contains "$out" "source: vault"
}

test_get_verbose_shows_env_source() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=env_value
EOF
    local out
    out=$("$PSST" get -v MY_KEY 2>&1)
    assert_contains "$out" "env_value"
    assert_contains "$out" "source: .env overrides vault"
}

test_get_verbose_env_only() {
    init_vault
    cat > .env <<'EOF'
ENV_ONLY=env_value
EOF
    local out
    out=$("$PSST" get -v ENV_ONLY 2>&1)
    assert_contains "$out" "env_value"
    assert_contains "$out" "source: .env"
}

test_get_vault_only_flag() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=env_override
EOF
    local out
    out=$("$PSST" get --vault-only MY_KEY)
    assert_eq "$out" "vault_value"
}
```

Add runner entries in the ".env override" section:

```bash
run_test "get -v shows vault source"          test_get_verbose_shows_vault_source
run_test "get -v shows env override source"   test_get_verbose_shows_env_source
run_test "get -v shows env-only source"       test_get_verbose_env_only
run_test "get --vault-only skips env"         test_get_vault_only_flag
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail

**Step 3: Implement `_env_source()` and update `cmd_get`**

Add `_env_source` after `_resolve_secret` in helpers:

```bash
# Determine the source of a secret value
_env_source() {
    local name="$1"
    _load_env_file
    local in_env=false in_vault=false
    if [[ -n "${_ENV_OVERRIDES[$name]+x}" ]] && [[ -n "${_ENV_OVERRIDES[$name]}" ]]; then
        in_env=true
    fi
    local file
    file=$(_secret_file "$name")
    if [[ -f "$file" ]]; then
        in_vault=true
    fi

    if $in_env && $in_vault; then
        echo ".env overrides vault"
    elif $in_env; then
        echo ".env"
    else
        echo "vault"
    fi
}
```

Replace `cmd_get`:

```bash
cmd_get() {
    need_vault
    local verbose=false
    local vault_only=false
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose) verbose=true; shift ;;
            --vault-only) vault_only=true; shift ;;
            -*) die "unknown flag '$1'" ;;
            *)  name="$1"; shift ;;
        esac
    done

    [[ -n "$name" ]] || die "usage: psst get [-v] [--vault-only] <NAME>"
    _valid_name "$name"

    local val
    if $vault_only; then
        val=$(_get_current "$name")
    else
        val=$(_resolve_secret "$name")
    fi

    if $verbose; then
        local source
        if $vault_only; then
            source="vault"
        else
            source=$(_env_source "$name")
        fi
        info "source: $source"
    fi

    printf '%s\n' "$val"
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: add get -v and get --vault-only flags

get -v prints source (vault, .env, .env overrides vault) to stderr.
get --vault-only ignores .env and reads directly from vault."
```

---

### Task 4: Update `cmd_list` with source annotations

**Files:**
- Modify: `psst` (`cmd_list`)

**Step 1: Write the failing tests**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_list_shows_vault_source() {
    init_vault
    set_secret "VAULT_KEY" "val"
    # No .env file
    local out
    out=$("$PSST" list)
    assert_contains "$out" "VAULT_KEY"
    assert_contains "$out" "(vault)"
}

test_list_shows_env_override_source() {
    init_vault
    set_secret "BOTH_KEY" "vault_val"
    cat > .env <<'EOF'
BOTH_KEY=env_val
EOF
    local out
    out=$("$PSST" list)
    assert_contains "$out" "BOTH_KEY"
    assert_contains "$out" "(.env overrides vault)"
}

test_list_shows_env_only_source() {
    init_vault
    cat > .env <<'EOF'
ENV_ONLY_KEY=env_val
EOF
    local out
    out=$("$PSST" list)
    assert_contains "$out" "ENV_ONLY_KEY"
    assert_contains "$out" "(.env)"
}

test_list_combined_sources() {
    init_vault
    set_secret "VAULT_KEY" "v1"
    set_secret "BOTH_KEY" "v2"
    cat > .env <<'EOF'
BOTH_KEY=override
ENV_KEY=env_only
EOF
    local out
    out=$("$PSST" list)
    assert_contains "$out" "BOTH_KEY  (.env overrides vault)"
    assert_contains "$out" "ENV_KEY  (.env)"
    assert_contains "$out" "VAULT_KEY  (vault)"
}
```

Add runner entries in the ".env override" section:

```bash
run_test "list shows vault source"            test_list_shows_vault_source
run_test "list shows env override source"     test_list_shows_env_override_source
run_test "list shows env-only source"         test_list_shows_env_only_source
run_test "list combined sources"              test_list_combined_sources
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail (list doesn't show source annotations yet)

**Step 3: Implement updated `cmd_list`**

Replace `cmd_list`:

```bash
cmd_list() {
    need_vault
    _load_env_file

    # Collect all unique secret names from vault and .env
    local -A all_names=()

    if [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
        for f in "$SECRETS_DIR"/*; do
            local name
            name=$(basename "$f")
            all_names["$name"]=1
        done
    fi

    for name in "${!_ENV_OVERRIDES[@]}"; do
        all_names["$name"]=1
    done

    if [[ ${#all_names[@]} -eq 0 ]]; then
        info "no secrets stored"
        return 0
    fi

    # Sort and display
    local sorted
    sorted=$(printf '%s\n' "${!all_names[@]}" | sort)
    while IFS= read -r name; do
        local source
        source=$(_env_source "$name")
        echo "$name  ($source)"
    done <<< "$sorted"
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Note:** The existing `test_list_shows_names` and `test_list_version_count` tests will need minor updates since the output format now always includes a source annotation. Update them:

In `test_list_shows_names`, the first line will now be `ALPHA  (vault)` — update the assertion:
```bash
    assert_eq "$first" "ALPHA  (vault)"
```

In `test_list_version_count`, the output now includes `(vault)` instead of bare names — update:
```bash
    assert_contains "$out" "KEY  (vault, 2 versions)"
    assert_contains "$out" "SINGLE  (vault)"
```

This means the `cmd_list` format for vault entries with versions should incorporate both: `KEY  (vault, 2 versions)`. Update the implementation to show version count alongside source when > 1 version exists in the vault:

```bash
    while IFS= read -r name; do
        local source
        source=$(_env_source "$name")
        local file
        file=$(_secret_file "$name")
        local version_info=""
        if [[ -f "$file" ]]; then
            local count
            count=$(wc -l < "$file" | tr -d ' ')
            if [[ "$count" -gt 1 ]]; then
                version_info=", $count versions"
            fi
        fi
        echo "$name  ($source$version_info)"
    done <<< "$sorted"
```

Update `test_list_version_count` accordingly:
```bash
test_list_version_count() {
    init_vault
    set_secret "KEY" "v1"
    set_secret "KEY" "v2"
    set_secret "SINGLE" "only"

    local out
    out=$("$PSST" list)
    assert_contains "$out" "KEY  (vault, 2 versions)"
    assert_contains "$out" "SINGLE  (vault)"
}
```

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: show source annotations in list command

list now shows (vault), (.env), or (.env overrides vault) for each
secret, plus version count for vault entries."
```

---

### Task 5: Update `cmd_run` with .env overlay

**Files:**
- Modify: `psst` (`cmd_run`)

**Step 1: Write the failing tests**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_run_env_overrides_vault() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=env_value
EOF
    local out
    out=$("$PSST" run bash -c 'echo $MY_KEY')
    assert_eq "$out" "env_value"
}

test_run_env_adds_new_secrets() {
    init_vault
    set_secret "VAULT_KEY" "vault_val"
    cat > .env <<'EOF'
ENV_KEY=env_val
EOF
    local out
    out=$("$PSST" run env)
    assert_contains "$out" "VAULT_KEY=vault_val"
    assert_contains "$out" "ENV_KEY=env_val"
}

test_run_env_empty_no_override() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=
EOF
    local out
    out=$("$PSST" run bash -c 'echo $MY_KEY')
    assert_eq "$out" "vault_value"
}

test_run_no_env_unchanged() {
    init_vault
    set_secret "SECRET_A" "aaa"
    # No .env file
    local out
    out=$("$PSST" run bash -c 'echo $SECRET_A')
    assert_eq "$out" "aaa"
}
```

Add runner entries in the ".env override" section:

```bash
run_test "run: env overrides vault"           test_run_env_overrides_vault
run_test "run: env adds new secrets"          test_run_env_adds_new_secrets
run_test "run: empty env no override"         test_run_env_empty_no_override
run_test "run: no env file unchanged"         test_run_no_env_unchanged
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail

**Step 3: Implement updated `cmd_run`**

Replace `cmd_run`:

```bash
cmd_run() {
    need_vault

    [[ $# -gt 0 ]] || die "usage: psst run <command>"

    # Build env vars from vault secrets
    local -A merged=()
    if [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
        for f in "$SECRETS_DIR"/*; do
            local name
            name=$(basename "$f")
            local value
            value=$(_get_current "$name")
            merged["$name"]="$value"
        done
    fi

    # Overlay .env values (non-empty override vault)
    _load_env_file
    for name in "${!_ENV_OVERRIDES[@]}"; do
        merged["$name"]="${_ENV_OVERRIDES[$name]}"
    done

    if [[ ${#merged[@]} -eq 0 ]]; then
        die "no secrets in vault or .env"
    fi

    local -a env_args=()
    for name in "${!merged[@]}"; do
        env_args+=("${name}=${merged[$name]}")
    done

    env "${env_args[@]}" "$@"
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Note:** The existing `test_run_empty_vault` test checks for "no secrets in vault" error message. Update the error message check since the message now says "no secrets in vault or .env":

```bash
# In test_run_empty_vault, update:
    assert_contains "$out" "no secrets"
```

This should still pass since "no secrets" is a substring of both messages.

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: run command overlays .env values on vault secrets

Vault secrets are loaded first, then .env entries override or add to
the environment passed to the subprocess."
```

---

### Task 6: Update `cmd_exec_with_secrets` with .env override

**Files:**
- Modify: `psst` (`cmd_exec_with_secrets`)

**Step 1: Write the failing tests**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_exec_env_overrides_specific() {
    init_vault
    set_secret "MY_KEY" "vault_val"
    cat > .env <<'EOF'
MY_KEY=env_val
EOF
    local out
    out=$("$PSST" MY_KEY -- bash -c 'echo $MY_KEY')
    assert_eq "$out" "env_val"
}

test_exec_env_only_secret() {
    init_vault
    cat > .env <<'EOF'
ENV_ONLY=env_val
EOF
    local out
    out=$("$PSST" ENV_ONLY -- bash -c 'echo $ENV_ONLY')
    assert_eq "$out" "env_val"
}

test_exec_no_env_unchanged() {
    init_vault
    set_secret "MY_KEY" "vault_val"
    # No .env file
    local out
    out=$("$PSST" MY_KEY -- bash -c 'echo $MY_KEY')
    assert_eq "$out" "vault_val"
}
```

Add runner entries in the ".env override" section:

```bash
run_test "exec: env overrides specific"       test_exec_env_overrides_specific
run_test "exec: env-only secret works"        test_exec_env_only_secret
run_test "exec: no env file unchanged"        test_exec_no_env_unchanged
```

**Step 2: Run tests to verify they fail**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New tests fail

**Step 3: Implement updated `cmd_exec_with_secrets`**

Replace the env_args building loop in `cmd_exec_with_secrets`:

```bash
cmd_exec_with_secrets() {
    # psst SECRET1 SECRET2 -- command args...
    need_vault

    local -a secret_names=()
    local -a cmd_args=()
    local found_separator=false

    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            found_separator=true
            continue
        fi
        if $found_separator; then
            cmd_args+=("$arg")
        else
            secret_names+=("$arg")
        fi
    done

    $found_separator || die "usage: psst SECRET [SECRET...] -- <command>"
    [[ ${#cmd_args[@]} -gt 0 ]] || die "no command specified after --"
    [[ ${#secret_names[@]} -gt 0 ]] || die "no secrets specified before --"

    _load_env_file
    local -a env_args=()
    for name in "${secret_names[@]}"; do
        _valid_name "$name"
        local value
        value=$(_resolve_secret "$name")
        env_args+=("${name}=${value}")
    done

    env "${env_args[@]}" "${cmd_args[@]}"
}
```

**Step 4: Run tests**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: SECRET -- cmd syntax respects .env overrides"
```

---

### Task 7: Update `cmd_help` and run full test suite

**Files:**
- Modify: `psst` (`cmd_help`)

**Step 1: Write the failing test**

Add to `test-psst.sh` before `# ── Run all tests`:

```bash
test_help_mentions_env() {
    local out
    out=$("$PSST" help)
    assert_contains "$out" ".env"
    assert_contains "$out" "--vault-only"
}
```

Add runner entry in the "help" runner section:

```bash
run_test "help mentions .env override"        test_help_mentions_env
```

**Step 2: Run test to verify it fails**

Run: `bash test-psst.sh 2>&1 | tail -10`
Expected: New test fails

**Step 3: Update `cmd_help`**

Replace the help text in `cmd_help`:

```bash
cmd_help() {
    cat <<'EOF'
psst - local secret manager for AI agent workflows

Usage:
  psst init                      Create vault in current directory
  psst set <NAME> [--stdin]      Add or update a secret
  psst get [-v] <NAME>           Retrieve a secret value
  psst get --vault-only <NAME>   Retrieve value from vault (ignore .env)
  psst list                      List all secrets with source annotations
  psst rm <NAME>                 Delete a secret
  psst history <NAME>            Show version history
  psst import <file|--stdin>     Import secrets from .env file
  psst export                    Export all secrets as .env format
  psst run <command>             Run command with all secrets injected
  psst onboard-claude              Add psst instructions to CLAUDE.md
  psst <SECRET> [..] -- <cmd>    Run command with specific secrets

.env Override:
  If a .env file exists in the current directory, its non-empty values
  override vault secrets. Use --vault-only with get to bypass .env.
  Use -v with get to see where a value comes from.

Examples:
  psst init
  psst set STRIPE_KEY
  psst import .env
  psst get -v API_KEY                  # shows source: vault or .env
  psst get --vault-only API_KEY        # always reads from vault
  psst STRIPE_KEY -- curl -H "Authorization: Bearer $STRIPE_KEY" https://api.stripe.com
  psst run ./deploy.sh
EOF
}
```

**Step 4: Run full test suite**

Run: `bash test-psst.sh`
Expected: ALL tests pass (no regressions)

**Step 5: Commit**

```bash
git add psst test-psst.sh
git commit -m "feat: update help text to document .env override feature"
```

---

### Task 8: Final validation and CLAUDE.md update

**Step 1: Run the full test suite one final time**

Run: `bash test-psst.sh`
Expected: All tests pass

**Step 2: Manual smoke test**

```bash
cd /tmp && mkdir psst-smoke && cd psst-smoke
/path/to/psst init
echo -n "vault_val" | /path/to/psst set MY_KEY --stdin
echo "MY_KEY=env_override" > .env
/path/to/psst get MY_KEY         # should print: env_override
/path/to/psst get -v MY_KEY      # should print source to stderr
/path/to/psst get --vault-only MY_KEY  # should print: vault_val
/path/to/psst list               # should show (.env overrides vault)
/path/to/psst run env | grep MY_KEY  # should show MY_KEY=env_override
cd / && rm -rf /tmp/psst-smoke
```

**Step 3: Update CLAUDE.md**

Add .env override documentation to the CLAUDE.md project instructions. Add a new section after "## Cross-Platform Notes":

```markdown
## .env Override

When a `.env` file exists in the current working directory, its non-empty values override vault secrets:
- `psst get NAME` returns the .env value if present, vault value otherwise
- `psst get -v NAME` shows where the value came from (stderr)
- `psst get --vault-only NAME` ignores .env, reads vault directly
- `psst run` and `psst SECRET -- cmd` both respect .env overrides
- `psst list` shows source annotations: `(vault)`, `(.env)`, `(.env overrides vault)`
```

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add .env override section to CLAUDE.md"
```
