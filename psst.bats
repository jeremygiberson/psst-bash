#!/usr/bin/env bats

# psst test suite
# Requires: bats-core (https://github.com/bats-core/bats-core)
#
# Run:   bats test/psst.bats
# CI:    bats --tap test/psst.bats

PSST="$BATS_TEST_DIRNAME/../psst"

setup() {
    # Each test gets its own temporary working directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    # Clean up any psst keys created during this test
    for ref in "$TEST_DIR"/.psst/.key "$TEST_DIR"/*/.psst/.key; do
        if [[ -f "$ref" ]]; then
            local kn
            kn=$(cat "$ref" 2>/dev/null)
            [[ -n "$kn" ]] && rm -f "$HOME/.ssh/$kn"
        fi
    done
    rm -rf "$TEST_DIR"
}

# ── Helper ───────────────────────────────────────────────────────

init_vault() {
    run "$PSST" init
    [ "$status" -eq 0 ]
}

set_secret() {
    echo -n "$2" | "$PSST" set "$1" --stdin
}

# ── init ─────────────────────────────────────────────────────────

@test "init creates vault structure" {
    run "$PSST" init
    [ "$status" -eq 0 ]
    [ -d ".psst" ]
    [ -d ".psst/secrets" ]
    [ -f ".psst/.key" ]
    # .key should be a pointer to a key in ~/.ssh
    local key_name
    key_name=$(cat .psst/.key)
    [[ "$key_name" == .psst_* ]]
    [ -f "$HOME/.ssh/$key_name" ]
}

@test "init sets restrictive permissions" {
    init_vault

    # .psst dir: 700
    local dir_perms
    dir_perms=$(stat -c '%a' .psst 2>/dev/null || stat -f '%Lp' .psst)
    [ "$dir_perms" = "700" ]

    # .key pointer file: 600
    local ref_perms
    ref_perms=$(stat -c '%a' .psst/.key 2>/dev/null || stat -f '%Lp' .psst/.key)
    [ "$ref_perms" = "600" ]

    # Actual key in ~/.ssh: 600
    local key_name key_perms
    key_name=$(cat .psst/.key)
    key_perms=$(stat -c '%a' "$HOME/.ssh/$key_name" 2>/dev/null || stat -f '%Lp' "$HOME/.ssh/$key_name")
    [ "$key_perms" = "600" ]
}

@test "init is idempotent" {
    init_vault
    local key_before
    key_before=$(cat .psst/.key)

    run "$PSST" init
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]

    # Key should be unchanged
    local key_after
    key_after=$(cat .psst/.key)
    [ "$key_before" = "$key_after" ]
}

@test "init adds .psst/ to .gitignore in a git repo" {
    git init -q .
    init_vault

    [ -f ".gitignore" ]
    grep -qxF ".psst/" .gitignore
}

@test "init does not duplicate .gitignore entry" {
    git init -q .
    echo ".psst/" > .gitignore
    init_vault

    local count
    count=$(grep -cxF ".psst/" .gitignore)
    [ "$count" -eq 1 ]
}

# ── set / get roundtrip ─────────────────────────────────────────

@test "set and get roundtrip preserves value" {
    init_vault
    set_secret "API_KEY" "sk_live_test123"

    run "$PSST" get API_KEY
    [ "$status" -eq 0 ]
    [ "$output" = "sk_live_test123" ]
}

@test "set and get handles special characters" {
    init_vault
    set_secret "DB_URL" "postgres://user:p@ss=w0rd!&foo@host:5432/db?ssl=true"

    run "$PSST" get DB_URL
    [ "$status" -eq 0 ]
    [ "$output" = "postgres://user:p@ss=w0rd!&foo@host:5432/db?ssl=true" ]
}

@test "set and get handles long values" {
    init_vault
    local long_val
    long_val=$(head -c 2048 /dev/urandom | base64 | tr -d '\n')
    set_secret "LONG_SECRET" "$long_val"

    run "$PSST" get LONG_SECRET
    [ "$status" -eq 0 ]
    [ "$output" = "$long_val" ]
}

@test "set via stdin" {
    init_vault
    echo -n "stdin_value" | "$PSST" set MY_SECRET --stdin

    run "$PSST" get MY_SECRET
    [ "$output" = "stdin_value" ]
}

@test "set rejects empty value" {
    init_vault
    run bash -c 'echo -n "" | '"$PSST"' set EMPTY --stdin'
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty value"* ]]
}

@test "set rejects invalid names" {
    init_vault

    run bash -c 'echo -n "val" | '"$PSST"' set "BAD-NAME" --stdin'
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid secret name"* ]]

    run bash -c 'echo -n "val" | '"$PSST"' set "123start" --stdin'
    [ "$status" -ne 0 ]

    run bash -c 'echo -n "val" | '"$PSST"' set "has space" --stdin'
    [ "$status" -ne 0 ]
}

@test "set accepts underscores and numbers" {
    init_vault
    set_secret "MY_KEY_2" "value"
    set_secret "_PRIVATE" "value"

    run "$PSST" get MY_KEY_2
    [ "$status" -eq 0 ]

    run "$PSST" get _PRIVATE
    [ "$status" -eq 0 ]
}

@test "set updates preserve previous versions" {
    init_vault
    set_secret "KEY" "version1"
    set_secret "KEY" "version2"
    set_secret "KEY" "version3"

    # Current value is latest
    run "$PSST" get KEY
    [ "$output" = "version3" ]

    # File has 3 lines (versions)
    local lines
    lines=$(wc -l < .psst/secrets/KEY | tr -d ' ')
    [ "$lines" -eq 3 ]
}

# ── get errors ───────────────────────────────────────────────────

@test "get fails for nonexistent secret" {
    init_vault
    run "$PSST" get NOPE
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "get fails without vault" {
    run "$PSST" get ANYTHING
    [ "$status" -ne 0 ]
    [[ "$output" == *"no vault"* ]]
}

# ── list ─────────────────────────────────────────────────────────

@test "list shows nothing on empty vault" {
    init_vault
    run "$PSST" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"no secrets"* ]]
}

@test "list shows secret names alphabetically" {
    init_vault
    set_secret "ZEBRA" "z"
    set_secret "ALPHA" "a"
    set_secret "MIDDLE" "m"

    run "$PSST" list
    [ "$status" -eq 0 ]

    # Verify alphabetical order (filesystem ordering)
    local first_line
    first_line=$(echo "$output" | head -1)
    [ "$first_line" = "ALPHA" ]
}

@test "list shows version count for multi-version secrets" {
    init_vault
    set_secret "KEY" "v1"
    set_secret "KEY" "v2"
    set_secret "SINGLE" "only"

    run "$PSST" list
    [[ "$output" == *"KEY  (2 versions)"* ]]
    # SINGLE should not show version count
    [[ "$output" == *"SINGLE"* ]]
    [[ "$output" != *"SINGLE  ("* ]]
}

@test "ls is an alias for list" {
    init_vault
    set_secret "TEST" "val"

    run "$PSST" ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST"* ]]
}

# ── rm ───────────────────────────────────────────────────────────

@test "rm deletes a secret" {
    init_vault
    set_secret "DOOMED" "bye"

    run "$PSST" rm DOOMED
    [ "$status" -eq 0 ]
    [ ! -f ".psst/secrets/DOOMED" ]
}

@test "rm fails for nonexistent secret" {
    init_vault
    run "$PSST" rm NOPE
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# ── history ──────────────────────────────────────────────────────

@test "history shows all versions with masked values" {
    init_vault
    set_secret "KEY" "first_value"
    set_secret "KEY" "second_value"
    set_secret "KEY" "third_value"

    run "$PSST" history KEY
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 version(s)"* ]]
    [[ "$output" == *"v1"* ]]
    [[ "$output" == *"v2"* ]]
    [[ "$output" == *"current"* ]]
}

@test "history masks values showing only first 4 chars" {
    init_vault
    set_secret "KEY" "abcdefghij"

    run "$PSST" history KEY
    # Should show "abcd" followed by asterisks
    [[ "$output" == *"abcd"* ]]
    [[ "$output" == *"****"* ]]
    # Should NOT show the full value
    [[ "$output" != *"abcdefghij"* ]]
}

@test "history masks short values entirely" {
    init_vault
    set_secret "KEY" "abc"

    run "$PSST" history KEY
    [[ "$output" == *"****"* ]]
}

@test "history fails for nonexistent secret" {
    init_vault
    run "$PSST" history NOPE
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# ── import ───────────────────────────────────────────────────────

@test "import reads .env file" {
    init_vault
    cat > test.env <<'EOF'
KEY_ONE=value1
KEY_TWO=value2
EOF

    run "$PSST" import test.env
    [ "$status" -eq 0 ]
    [[ "$output" == *"imported 2"* ]]

    run "$PSST" get KEY_ONE
    [ "$output" = "value1" ]

    run "$PSST" get KEY_TWO
    [ "$output" = "value2" ]
}

@test "import handles double-quoted values" {
    init_vault
    echo 'MY_KEY="quoted value"' > test.env

    "$PSST" import test.env
    run "$PSST" get MY_KEY
    [ "$output" = "quoted value" ]
}

@test "import handles single-quoted values" {
    init_vault
    echo "MY_KEY='single quoted'" > test.env

    "$PSST" import test.env
    run "$PSST" get MY_KEY
    [ "$output" = "single quoted" ]
}

@test "import strips export prefix" {
    init_vault
    echo "export MY_KEY=exported_value" > test.env

    "$PSST" import test.env
    run "$PSST" get MY_KEY
    [ "$output" = "exported_value" ]
}

@test "import skips comments and blank lines" {
    init_vault
    cat > test.env <<'EOF'
# This is a comment
KEY_ONE=value1

  # Indented comment
KEY_TWO=value2

EOF

    run "$PSST" import test.env
    [[ "$output" == *"imported 2"* ]]
}

@test "import from stdin" {
    init_vault
    echo "STDIN_KEY=stdin_val" | "$PSST" import --stdin

    run "$PSST" get STDIN_KEY
    [ "$output" = "stdin_val" ]
}

@test "import fails on missing file" {
    init_vault
    run "$PSST" import nonexistent.env
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# ── export ───────────────────────────────────────────────────────

@test "export produces .env format" {
    init_vault
    set_secret "ALPHA_KEY" "aaa"
    set_secret "BETA_KEY" "bbb"

    run "$PSST" export
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALPHA_KEY=aaa"* ]]
    [[ "$output" == *"BETA_KEY=bbb"* ]]
}

@test "export uses current value when history exists" {
    init_vault
    set_secret "KEY" "old"
    set_secret "KEY" "new"

    run "$PSST" export
    [[ "$output" == *"KEY=new"* ]]
    [[ "$output" != *"KEY=old"* ]]
}

@test "import then export roundtrip" {
    init_vault
    cat > original.env <<'EOF'
AA_KEY=value_aa
BB_KEY=value_bb
CC_KEY=value_cc
EOF

    "$PSST" import original.env
    "$PSST" export > exported.env

    # Values should match (order may differ)
    while IFS='=' read -r key val; do
        run "$PSST" get "$key"
        [ "$output" = "$val" ]
    done < original.env
}

# ── run ──────────────────────────────────────────────────────────

@test "run injects all secrets into subprocess" {
    init_vault
    set_secret "SECRET_A" "aaa"
    set_secret "SECRET_B" "bbb"

    run "$PSST" run env
    [ "$status" -eq 0 ]
    [[ "$output" == *"SECRET_A=aaa"* ]]
    [[ "$output" == *"SECRET_B=bbb"* ]]
}

@test "run does not leak secrets to parent environment" {
    init_vault
    set_secret "LEAK_TEST" "should_not_leak"

    "$PSST" run true

    run env
    [[ "$output" != *"LEAK_TEST"* ]]
}

@test "run passes through exit code" {
    init_vault
    set_secret "X" "x"

    run "$PSST" run bash -c 'exit 42'
    [ "$status" -eq 42 ]
}

@test "run passes through stdout" {
    init_vault
    set_secret "MSG" "hello_from_secret"

    run "$PSST" run bash -c 'echo $MSG'
    [ "$output" = "hello_from_secret" ]
}

@test "run fails with no secrets" {
    init_vault
    run "$PSST" run echo hi
    [ "$status" -ne 0 ]
    [[ "$output" == *"no secrets"* ]]
}

@test "run fails with no command" {
    init_vault
    set_secret "X" "x"
    run "$PSST" run
    [ "$status" -ne 0 ]
}

# ── exec with specific secrets (-- syntax) ───────────────────────

@test "specific secrets injection via -- syntax" {
    init_vault
    set_secret "WANTED" "yes"
    set_secret "UNWANTED" "no"

    run "$PSST" WANTED -- env
    [ "$status" -eq 0 ]
    [[ "$output" == *"WANTED=yes"* ]]
    [[ "$output" != *"UNWANTED=no"* ]]
}

@test "multiple specific secrets via -- syntax" {
    init_vault
    set_secret "KEY_A" "aaa"
    set_secret "KEY_B" "bbb"
    set_secret "KEY_C" "ccc"

    run "$PSST" KEY_A KEY_C -- env
    [[ "$output" == *"KEY_A=aaa"* ]]
    [[ "$output" == *"KEY_C=ccc"* ]]
    [[ "$output" != *"KEY_B=bbb"* ]]
}

@test "-- syntax fails without separator" {
    init_vault
    set_secret "KEY" "val"

    run "$PSST" KEY env
    [ "$status" -ne 0 ]
}

@test "-- syntax fails with missing secret" {
    init_vault
    set_secret "EXISTS" "val"

    run "$PSST" EXISTS MISSING -- env
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "-- syntax passes through exit code" {
    init_vault
    set_secret "X" "x"

    run "$PSST" X -- bash -c 'exit 7'
    [ "$status" -eq 7 ]
}

# ── help ─────────────────────────────────────────────────────────

@test "help displays usage" {
    run "$PSST" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"psst init"* ]]
}

@test "no arguments shows help" {
    run "$PSST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "--help flag shows help" {
    run "$PSST" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

# ── edge cases ───────────────────────────────────────────────────

@test "different vaults are independent" {
    # Vault 1
    mkdir -p project_a && cd project_a
    "$PSST" init
    set_secret "KEY" "from_a"

    # Vault 2
    cd "$TEST_DIR"
    mkdir -p project_b && cd project_b
    "$PSST" init
    set_secret "KEY" "from_b"

    # Each vault has its own value
    cd "$TEST_DIR/project_a"
    run "$PSST" get KEY
    [ "$output" = "from_a" ]

    cd "$TEST_DIR/project_b"
    run "$PSST" get KEY
    [ "$output" = "from_b" ]
}

@test "secrets with equals signs in value" {
    init_vault
    set_secret "BASE64_TOKEN" "dGVzdA==something=="

    run "$PSST" get BASE64_TOKEN
    [ "$output" = "dGVzdA==something==" ]
}

@test "secrets with newline-like content" {
    init_vault
    # Value with literal backslash-n (not actual newline)
    set_secret "ESCAPED" 'line1\nline2'

    run "$PSST" get ESCAPED
    [ "$output" = 'line1\nline2' ]
}

# ── key storage ──────────────────────────────────────────────────

@test "key stored in ~/.ssh not project dir" {
    init_vault
    local key_name
    key_name=$(cat .psst/.key)
    [[ "$key_name" == .psst_* ]]
    [ -f "$HOME/.ssh/$key_name" ]
    # Pointer file should only contain the name, not key material
    local ref_size
    ref_size=$(wc -c < .psst/.key | tr -d ' ')
    [ "$ref_size" -lt 30 ]
}

@test "missing ssh key fails gracefully" {
    init_vault
    set_secret "KEY" "val"
    # Delete the actual key from ~/.ssh
    local key_name
    key_name=$(cat .psst/.key)
    rm "$HOME/.ssh/$key_name"
    # Operations should now fail
    run "$PSST" get KEY
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}
