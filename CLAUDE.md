# psst - Development Guide

psst is a single-file bash secret manager for AI agent workflows. Secrets are encrypted at rest and injected into subprocesses at runtime.

## Project Structure

```
psst              # The entire tool — single bash script (~480 lines)
test-psst.sh      # Pure bash test suite (57 tests)
psst.bats         # Bats-core test suite (parallel structure)
CLAUDE.sample.md  # Template for onboarding Claude in user projects
```

There are no dependencies beyond `bash` (4.0+) and `openssl`. Keep it that way.

## Running Tests

```bash
bash test-psst.sh
```

Always run the full suite before committing. Tests create isolated temp directories and clean up encryption keys from `~/.ssh/` in teardown.

## Architecture of the Script

The script has three sections in order:

1. **Globals** (lines 8-11): `PSST_DIR`, `SECRETS_DIR`, `KEY_REF`, `SSH_DIR`
2. **Helpers** (lines 14-119): Private functions prefixed with `_` (e.g., `_encrypt`, `_decrypt`, `_valid_name`, `_claude_instructions`)
3. **Commands** (lines 121+): Public command functions prefixed with `cmd_` (e.g., `cmd_init`, `cmd_set`, `cmd_onboard_claude`)
4. **Dispatch** (bottom): `main()` with a `case` statement mapping command names to `cmd_*` functions

## Adding a New Command

Follow this exact pattern:

1. **Add a `cmd_<name>()` function** in the Commands section, before `cmd_help()`
2. **Add a case entry** in `main()`: `<name>) shift; cmd_<name> "$@" ;;`
3. **Add a line to `cmd_help()`** with consistent formatting
4. **Add tests** to `test-psst.sh` — both test functions and `run_test` runner entries

### Test Pattern

```bash
# Test function (add before "# ── Run all tests" section)
test_my_feature() {
    init_vault                              # if vault needed
    set_secret "NAME" "value"               # if secrets needed
    local out rc
    out=$("$PSST" mycommand args 2>&1) && rc=0 || rc=$?
    assert_eq "$rc" "0"
    assert_contains "$out" "expected text"
}

# Runner entry (add in appropriate group)
run_test "description of test"    test_my_feature
```

**Test helpers available:** `init_vault`, `set_secret "NAME" "VALUE"`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_status`

## Conventions

- `die()` for fatal errors (prints to stderr, exits 1)
- `info()` for status messages (prints to stderr, no exit)
- `need_vault` at the top of any command that requires an initialized vault
- `_valid_name` to validate secret names before use
- Secret names match `^[A-Za-z_][A-Za-z0-9_]*$`
- Use `printf '%s\n'` over `echo` when outputting user-provided or multi-line content
- Heredocs with single-quoted delimiters (`<<'EOF'`) when content contains `$` variables that should not expand

## Cross-Platform Notes

- OpenSSL KDF: macOS LibreSSL lacks `-pbkdf2`, detected at runtime by `_openssl_kdf_flag()`
- `stat` permissions: `-c '%a'` on Linux, `-f '%Lp'` on macOS — tests use `stat -c ... 2>/dev/null || stat -f ...`
- `grep` flags: avoid flags that behave differently between GNU and BSD (e.g., `-P` is GNU-only)

## .env Override

When a `.env` file exists in the current working directory, its non-empty values override vault secrets:
- `psst get NAME` returns the .env value if present, vault value otherwise
- `psst get -v NAME` shows where the value came from (stderr)
- `psst get --vault-only NAME` ignores .env, reads vault directly
- `psst run` and `psst SECRET -- cmd` both respect .env overrides
- `psst list` shows source annotations: `(vault)`, `(.env)`, `(.env overrides vault)`
