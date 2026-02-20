#!/usr/bin/env bash
set -uo pipefail

# Quick test runner for psst — validates all test cases directly.
# In CI, use: bats test/psst.bats

PSST="$(cd "$(dirname "$0")" && pwd)/psst"
PASS=0 FAIL=0 ERRORS=()

# ── Helpers ──────────────────────────────────────────────────────

TEST_DIR=""

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    # Clean up any psst keys created during this test
    if [[ -f "$TEST_DIR/.psst/.key" ]]; then
        local key_name
        key_name=$(cat "$TEST_DIR/.psst/.key" 2>/dev/null)
        [[ -n "$key_name" ]] && rm -f "$HOME/.ssh/$key_name"
    fi
    # Also check subdirectories (for independent vaults test)
    for ref in "$TEST_DIR"/*/.psst/.key "$TEST_DIR"/.psst/.key; do
        if [[ -f "$ref" ]]; then
            local kn
            kn=$(cat "$ref" 2>/dev/null)
            [[ -n "$kn" ]] && rm -f "$HOME/.ssh/$kn"
        fi
    done
    cd /
    rm -rf "$TEST_DIR"
}

init_vault() {
    "$PSST" init >/dev/null 2>&1
}

set_secret() {
    echo -n "$2" | "$PSST" set "$1" --stdin 2>/dev/null
}

run_test() {
    local name="$1"
    shift
    setup
    local err_out
    if err_out=$("$@" 2>&1); then
        printf "  ✓ %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  ✗ %s\n" "$name"
        [[ -n "$err_out" ]] && printf "    %s\n" "$(echo "$err_out" | tail -3)"
        FAIL=$((FAIL + 1))
        ERRORS+=("$name")
    fi
    teardown
}

assert_eq() {
    if [[ "$1" != "$2" ]]; then
        echo "expected: '$2'" >&2
        echo "     got: '$1'" >&2
        return 1
    fi
}

assert_contains() {
    if [[ "$1" != *"$2"* ]]; then
        echo "expected output to contain: '$2'" >&2
        echo "                       got: '$1'" >&2
        return 1
    fi
}

assert_not_contains() {
    if [[ "$1" == *"$2"* ]]; then
        echo "expected output NOT to contain: '$2'" >&2
        return 1
    fi
}

assert_status() {
    if [[ "$1" -ne "$2" ]]; then
        echo "expected exit code $2, got $1" >&2
        return 1
    fi
}

# ── Tests ────────────────────────────────────────────────────────

test_init_creates_structure() {
    "$PSST" init >/dev/null 2>&1
    [[ -d ".psst" ]] && [[ -d ".psst/secrets" ]] && [[ -f ".psst/.key" ]]
    # .key should contain a reference name, not the actual key material
    local key_name
    key_name=$(cat .psst/.key)
    [[ "$key_name" == .psst_* ]]
    [[ -f "$HOME/.ssh/$key_name" ]]
}

test_init_permissions() {
    init_vault
    local dir_perms ref_perms
    dir_perms=$(stat -c '%a' .psst 2>/dev/null || stat -f '%Lp' .psst)
    ref_perms=$(stat -c '%a' .psst/.key 2>/dev/null || stat -f '%Lp' .psst/.key)
    assert_eq "$dir_perms" "700"
    assert_eq "$ref_perms" "600"
    # Actual key in ~/.ssh should be 600
    local key_name key_perms
    key_name=$(cat .psst/.key)
    key_perms=$(stat -c '%a' "$HOME/.ssh/$key_name" 2>/dev/null || stat -f '%Lp' "$HOME/.ssh/$key_name")
    assert_eq "$key_perms" "600"
}

test_init_idempotent() {
    init_vault
    local key_before key_after out
    key_before=$(cat .psst/.key)
    out=$("$PSST" init 2>&1)
    key_after=$(cat .psst/.key)
    assert_eq "$key_before" "$key_after"
    assert_contains "$out" "already exists"
}

test_init_gitignore() {
    git init -q .
    init_vault
    [[ -f ".gitignore" ]] && grep -qxF ".psst/" .gitignore
}

test_init_gitignore_no_duplicate() {
    git init -q .
    echo ".psst/" > .gitignore
    init_vault
    local count
    count=$(grep -cxF ".psst/" .gitignore)
    assert_eq "$count" "1"
}

test_set_get_roundtrip() {
    init_vault
    set_secret "API_KEY" "sk_live_test123"
    local out
    out=$("$PSST" get API_KEY)
    assert_eq "$out" "sk_live_test123"
}

test_special_characters() {
    init_vault
    set_secret "DB_URL" "postgres://user:p@ss=w0rd!&foo@host:5432/db?ssl=true"
    local out
    out=$("$PSST" get DB_URL)
    assert_eq "$out" "postgres://user:p@ss=w0rd!&foo@host:5432/db?ssl=true"
}

test_long_values() {
    init_vault
    local long_val
    long_val=$(head -c 2048 /dev/urandom | base64 | tr -d '\n')
    set_secret "LONG" "$long_val"
    local out
    out=$("$PSST" get LONG)
    assert_eq "$out" "$long_val"
}

test_set_stdin() {
    init_vault
    echo -n "stdin_value" | "$PSST" set MY_SECRET --stdin 2>/dev/null
    local out
    out=$("$PSST" get MY_SECRET)
    assert_eq "$out" "stdin_value"
}

test_set_rejects_empty() {
    init_vault
    local out rc
    out=$(echo -n "" | "$PSST" set EMPTY --stdin 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "empty value"
}

test_set_rejects_invalid_names() {
    init_vault
    local out rc

    out=$(echo -n "v" | "$PSST" set "BAD-NAME" --stdin 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "invalid secret name"

    out=$(echo -n "v" | "$PSST" set "123start" --stdin 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1

    out=$(echo -n "v" | "$PSST" set "has space" --stdin 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
}

test_set_accepts_underscores_numbers() {
    init_vault
    set_secret "MY_KEY_2" "value"
    set_secret "_PRIVATE" "value"
    "$PSST" get MY_KEY_2 >/dev/null
    "$PSST" get _PRIVATE >/dev/null
}

test_update_preserves_history() {
    init_vault
    set_secret "KEY" "version1"
    set_secret "KEY" "version2"
    set_secret "KEY" "version3"

    local out
    out=$("$PSST" get KEY)
    assert_eq "$out" "version3"

    local lines
    lines=$(wc -l < .psst/secrets/KEY | tr -d ' ')
    assert_eq "$lines" "3"
}

test_get_nonexistent() {
    init_vault
    local out rc
    out=$("$PSST" get NOPE 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_get_no_vault() {
    local out rc
    out=$("$PSST" get ANYTHING 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "no vault"
}

test_list_empty() {
    init_vault
    local out
    out=$("$PSST" list 2>&1)
    assert_contains "$out" "no secrets"
}

test_list_shows_names() {
    init_vault
    set_secret "ZEBRA" "z"
    set_secret "ALPHA" "a"

    local out
    out=$("$PSST" list)
    assert_contains "$out" "ALPHA"
    assert_contains "$out" "ZEBRA"

    # Alphabetical: ALPHA should come first
    local first
    first=$(echo "$out" | head -1)
    assert_eq "$first" "ALPHA"
}

test_list_version_count() {
    init_vault
    set_secret "KEY" "v1"
    set_secret "KEY" "v2"
    set_secret "SINGLE" "only"

    local out
    out=$("$PSST" list)
    assert_contains "$out" "KEY  (2 versions)"
    assert_not_contains "$out" "SINGLE  ("
}

test_ls_alias() {
    init_vault
    set_secret "TEST" "val"
    local out
    out=$("$PSST" ls)
    assert_contains "$out" "TEST"
}

test_rm() {
    init_vault
    set_secret "DOOMED" "bye"
    "$PSST" rm DOOMED 2>/dev/null
    [[ ! -f ".psst/secrets/DOOMED" ]]
}

test_rm_nonexistent() {
    init_vault
    local out rc
    out=$("$PSST" rm NOPE 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_history_versions() {
    init_vault
    set_secret "KEY" "first"
    set_secret "KEY" "second"
    set_secret "KEY" "third"

    local out
    out=$("$PSST" history KEY)
    assert_contains "$out" "3 version(s)"
    assert_contains "$out" "v1"
    assert_contains "$out" "v2"
    assert_contains "$out" "current"
}

test_history_masks_values() {
    init_vault
    set_secret "KEY" "abcdefghij"

    local out
    out=$("$PSST" history KEY)
    assert_contains "$out" "abcd"
    assert_contains "$out" "****"
    assert_not_contains "$out" "abcdefghij"
}

test_history_masks_short() {
    init_vault
    set_secret "KEY" "abc"

    local out
    out=$("$PSST" history KEY)
    assert_contains "$out" "****"
}

test_history_nonexistent() {
    init_vault
    local out rc
    out=$("$PSST" history NOPE 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_import_env_file() {
    init_vault
    cat > test.env <<'EOF'
KEY_ONE=value1
KEY_TWO=value2
EOF
    local out
    out=$("$PSST" import test.env 2>&1)
    assert_contains "$out" "imported 2"
    assert_eq "$("$PSST" get KEY_ONE)" "value1"
    assert_eq "$("$PSST" get KEY_TWO)" "value2"
}

test_import_double_quotes() {
    init_vault
    echo 'MY_KEY="quoted value"' > test.env
    "$PSST" import test.env 2>/dev/null
    assert_eq "$("$PSST" get MY_KEY)" "quoted value"
}

test_import_single_quotes() {
    init_vault
    echo "MY_KEY='single quoted'" > test.env
    "$PSST" import test.env 2>/dev/null
    assert_eq "$("$PSST" get MY_KEY)" "single quoted"
}

test_import_export_prefix() {
    init_vault
    echo "export MY_KEY=exported_value" > test.env
    "$PSST" import test.env 2>/dev/null
    assert_eq "$("$PSST" get MY_KEY)" "exported_value"
}

test_import_skips_comments() {
    init_vault
    cat > test.env <<'EOF'
# comment
KEY_ONE=value1

  # indented comment
KEY_TWO=value2

EOF
    local out
    out=$("$PSST" import test.env 2>&1)
    assert_contains "$out" "imported 2"
}

test_import_stdin() {
    init_vault
    echo "STDIN_KEY=stdin_val" | "$PSST" import --stdin 2>/dev/null
    assert_eq "$("$PSST" get STDIN_KEY)" "stdin_val"
}

test_import_missing_file() {
    init_vault
    local out rc
    out=$("$PSST" import nonexistent.env 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_export_format() {
    init_vault
    set_secret "ALPHA_KEY" "aaa"
    set_secret "BETA_KEY" "bbb"

    local out
    out=$("$PSST" export)
    assert_contains "$out" "ALPHA_KEY=aaa"
    assert_contains "$out" "BETA_KEY=bbb"
}

test_export_uses_current_value() {
    init_vault
    set_secret "KEY" "old"
    set_secret "KEY" "new"

    local out
    out=$("$PSST" export)
    assert_contains "$out" "KEY=new"
    assert_not_contains "$out" "KEY=old"
}

test_import_export_roundtrip() {
    init_vault
    cat > original.env <<'EOF'
AA_KEY=value_aa
BB_KEY=value_bb
CC_KEY=value_cc
EOF
    "$PSST" import original.env 2>/dev/null
    "$PSST" export > exported.env

    while IFS='=' read -r key val; do
        assert_eq "$("$PSST" get "$key")" "$val"
    done < original.env
}

test_run_injects_all() {
    init_vault
    set_secret "SECRET_A" "aaa"
    set_secret "SECRET_B" "bbb"

    local out
    out=$("$PSST" run env)
    assert_contains "$out" "SECRET_A=aaa"
    assert_contains "$out" "SECRET_B=bbb"
}

test_run_no_leak() {
    init_vault
    set_secret "LEAK_TEST" "should_not_leak"
    "$PSST" run true

    local out
    out=$(env)
    assert_not_contains "$out" "LEAK_TEST"
}

test_run_exit_code() {
    init_vault
    set_secret "X" "x"
    local rc
    "$PSST" run bash -c 'exit 42' && rc=0 || rc=$?
    assert_eq "$rc" "42"
}

test_run_stdout() {
    init_vault
    set_secret "MSG" "hello_from_secret"
    local out
    out=$("$PSST" run bash -c 'echo $MSG')
    assert_eq "$out" "hello_from_secret"
}

test_run_empty_vault() {
    init_vault
    local out rc
    out=$("$PSST" run echo hi 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "no secrets"
}

test_specific_injection() {
    init_vault
    set_secret "WANTED" "yes"
    set_secret "UNWANTED" "no"

    local out
    out=$("$PSST" WANTED -- env)
    assert_contains "$out" "WANTED=yes"
    assert_not_contains "$out" "UNWANTED=no"
}

test_multiple_specific() {
    init_vault
    set_secret "KEY_A" "aaa"
    set_secret "KEY_B" "bbb"
    set_secret "KEY_C" "ccc"

    local out
    out=$("$PSST" KEY_A KEY_C -- env)
    assert_contains "$out" "KEY_A=aaa"
    assert_contains "$out" "KEY_C=ccc"
    assert_not_contains "$out" "KEY_B=bbb"
}

test_specific_missing_separator() {
    init_vault
    set_secret "KEY" "val"
    local out rc
    out=$("$PSST" KEY env 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
}

test_specific_missing_secret() {
    init_vault
    set_secret "EXISTS" "val"
    local out rc
    out=$("$PSST" EXISTS MISSING -- env 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_specific_exit_code() {
    init_vault
    set_secret "X" "x"
    local rc
    "$PSST" X -- bash -c 'exit 7' && rc=0 || rc=$?
    assert_eq "$rc" "7"
}

test_help() {
    local out
    out=$("$PSST" help)
    assert_contains "$out" "Usage"
    assert_contains "$out" "psst init"
}

test_no_args_shows_help() {
    local out
    out=$("$PSST")
    assert_contains "$out" "Usage"
}

test_help_flag() {
    local out
    out=$("$PSST" --help)
    assert_contains "$out" "Usage"
}

test_independent_vaults() {
    mkdir -p project_a && cd project_a
    init_vault
    set_secret "KEY" "from_a"

    cd "$TEST_DIR"
    mkdir -p project_b && cd project_b
    init_vault
    set_secret "KEY" "from_b"

    assert_eq "$(cd "$TEST_DIR/project_a" && "$PSST" get KEY)" "from_a"
    assert_eq "$(cd "$TEST_DIR/project_b" && "$PSST" get KEY)" "from_b"
}

test_equals_in_value() {
    init_vault
    set_secret "BASE64" "dGVzdA==something=="
    assert_eq "$("$PSST" get BASE64)" "dGVzdA==something=="
}

test_escaped_content() {
    init_vault
    set_secret "ESCAPED" 'line1\nline2'
    assert_eq "$("$PSST" get ESCAPED)" 'line1\nline2'
}

test_key_stored_in_ssh_dir() {
    init_vault
    local key_name
    key_name=$(cat .psst/.key)
    # Key name should have psst prefix
    [[ "$key_name" == .psst_* ]]
    # Actual key material should be in ~/.ssh, not in .psst/
    [[ -f "$HOME/.ssh/$key_name" ]]
    # The .key file should only contain the name, not key material
    local ref_size
    ref_size=$(wc -c < .psst/.key | tr -d ' ')
    # A .psst_ + 16 hex chars + newline = ~23 bytes, way less than 64-byte key
    [[ "$ref_size" -lt 30 ]]
}

test_missing_ssh_key_fails() {
    init_vault
    set_secret "KEY" "val"
    # Delete the actual key from ~/.ssh
    local key_name
    key_name=$(cat .psst/.key)
    rm "$HOME/.ssh/$key_name"
    # Operations should now fail
    local out rc
    out=$("$PSST" get KEY 2>&1) && rc=0 || rc=$?
    assert_status "$rc" 1
    assert_contains "$out" "not found"
}

test_help_shows_onboard_claude() {
    local out
    out=$("$PSST" help)
    assert_contains "$out" "onboard-claude"
}

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
    assert_contains "$(cat CLAUDE.md)" "---"
    assert_contains "$out" "appended"
}

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

test_load_env_file_creates_overrides() {
    init_vault
    set_secret "VAULT_ONLY" "from_vault"
    cat > .env <<'EOF'
ENV_VAR=from_env
VAULT_ONLY=from_env_override
EOF
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

test_get_verbose_empty_env_shows_vault() {
    init_vault
    set_secret "MY_KEY" "vault_value"
    cat > .env <<'EOF'
MY_KEY=
EOF
    local out
    out=$("$PSST" get -v MY_KEY 2>&1)
    assert_contains "$out" "vault_value"
    assert_contains "$out" "source: vault"
}

# ── Run all tests ────────────────────────────────────────────────

echo "psst test suite"
echo "════════════════════════════════════════"
echo ""

echo "init"
run_test "creates vault structure"          test_init_creates_structure
run_test "sets restrictive permissions"     test_init_permissions
run_test "is idempotent"                    test_init_idempotent
run_test "adds .psst/ to .gitignore"        test_init_gitignore
run_test "no duplicate .gitignore entry"    test_init_gitignore_no_duplicate
echo ""

echo "set / get"
run_test "roundtrip preserves value"        test_set_get_roundtrip
run_test "handles special characters"       test_special_characters
run_test "handles long values"              test_long_values
run_test "set via stdin"                    test_set_stdin
run_test "rejects empty value"              test_set_rejects_empty
run_test "rejects invalid names"            test_set_rejects_invalid_names
run_test "accepts underscores and numbers"  test_set_accepts_underscores_numbers
run_test "updates preserve history"         test_update_preserves_history
run_test "get nonexistent fails"            test_get_nonexistent
run_test "get without vault fails"          test_get_no_vault
echo ""

echo "list"
run_test "empty vault"                      test_list_empty
run_test "shows names alphabetically"       test_list_shows_names
run_test "shows version count"              test_list_version_count
run_test "ls alias works"                   test_ls_alias
echo ""

echo "rm"
run_test "deletes secret"                   test_rm
run_test "nonexistent fails"                test_rm_nonexistent
echo ""

echo "history"
run_test "shows all versions"               test_history_versions
run_test "masks values"                     test_history_masks_values
run_test "masks short values"               test_history_masks_short
run_test "nonexistent fails"                test_history_nonexistent
echo ""

echo "import"
run_test "reads .env file"                  test_import_env_file
run_test "handles double quotes"            test_import_double_quotes
run_test "handles single quotes"            test_import_single_quotes
run_test "strips export prefix"             test_import_export_prefix
run_test "skips comments and blank lines"   test_import_skips_comments
run_test "from stdin"                       test_import_stdin
run_test "missing file fails"               test_import_missing_file
run_test "import works after refactor"      test_import_still_works_after_refactor
echo ""

echo "export"
run_test "produces .env format"             test_export_format
run_test "uses current value"               test_export_uses_current_value
run_test "import/export roundtrip"          test_import_export_roundtrip
echo ""

echo "run (all secrets)"
run_test "injects all secrets"              test_run_injects_all
run_test "no leak to parent env"            test_run_no_leak
run_test "passes exit code"                 test_run_exit_code
run_test "passes stdout"                    test_run_stdout
run_test "empty vault fails"                test_run_empty_vault
echo ""

echo "exec (specific secrets via --)"
run_test "injects specific secrets"         test_specific_injection
run_test "multiple specific secrets"        test_multiple_specific
run_test "missing separator fails"          test_specific_missing_separator
run_test "missing secret fails"             test_specific_missing_secret
run_test "passes exit code"                 test_specific_exit_code
echo ""

echo "help"
run_test "help shows usage"                 test_help
run_test "no args shows help"               test_no_args_shows_help
run_test "--help flag"                      test_help_flag
run_test "help shows onboard-claude"          test_help_shows_onboard_claude
echo ""

echo "edge cases"
run_test "independent vaults"               test_independent_vaults
run_test "equals signs in value"            test_equals_in_value
run_test "escaped content preserved"        test_escaped_content
run_test "key stored in ~/.ssh"             test_key_stored_in_ssh_dir
run_test "missing ssh key fails"            test_missing_ssh_key_fails
echo ""

echo "onboard-claude"
run_test "creates CLAUDE.md when missing"     test_onboard_claude_creates_new
run_test "skips if psst already present"      test_onboard_claude_already_has_psst
run_test "appends when claude CLI missing"    test_onboard_claude_appends_fallback
echo ""

echo ".env override"
run_test "env file overrides vault"           test_load_env_file_creates_overrides
run_test "no env file uses vault"             test_no_env_file_no_change
run_test "empty env value no override"        test_empty_env_value_no_override
run_test "get -v shows vault source"          test_get_verbose_shows_vault_source
run_test "get -v shows env override source"   test_get_verbose_shows_env_source
run_test "get -v shows env-only source"       test_get_verbose_env_only
run_test "get --vault-only skips env"         test_get_vault_only_flag
run_test "get -v empty env shows vault"       test_get_verbose_empty_env_shows_vault
echo ""

echo "════════════════════════════════════════"
echo "$PASS passed, $FAIL failed (of $((PASS + FAIL)))"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  ✗ $e"
    done
    exit 1
fi
