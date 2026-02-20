# .env Override Feature Design

## Problem

psst currently only serves secrets from its encrypted vault. Many projects have per-user secrets stored in `.env` files. Users need a way to use `.env` values as overrides on top of vault secrets, so per-user configuration takes priority without modifying the shared vault.

## Approach

**Helper-based (Approach A):** Add a `_load_env_file()` helper that parses `.env` into a bash associative array, and a `_resolve_secret()` function that checks .env first, falls back to vault. All commands use `_resolve_secret()` instead of `_get_current()` directly.

Requires bash 4.0+ for associative arrays (already a project requirement).

## Design

### New Helpers

- **`_load_env_file()`** — Parses `.env` in `$PWD` into global associative array `_ENV_OVERRIDES`. Same parsing logic as `cmd_import` (skip comments/blanks, strip `export` prefix, strip quotes). Only loads non-empty values. No-op if `.env` doesn't exist.
- **`_resolve_secret(name)`** — Returns `_ENV_OVERRIDES[$name]` if non-empty, otherwise `_get_current "$name"`.
- **`_env_source(name)`** — Returns source label: `".env"`, `"vault"`, or `".env overrides vault"`.

### Modified Commands

| Command | Change |
|---------|--------|
| `cmd_get` | Use `_resolve_secret` instead of `_get_current`. Add `-v` flag (prints source to stderr). Add `--vault-only` flag (skips .env). |
| `cmd_run` | Load vault secrets first, then overlay non-empty .env entries. |
| `cmd_exec_with_secrets` | Use `_resolve_secret` for each requested secret. |
| `cmd_list` | Show all secrets from vault and .env with source annotations. |

### `cmd_list` Output

```
API_KEY       (.env overrides vault)
DB_URL        (vault)
LOCAL_TOKEN   (.env)
STRIPE_KEY    (vault)
```

### `cmd_get` Flags

- `psst get NAME` — resolved value (.env wins)
- `psst get -v NAME` — same, plus prints `psst: source: <label>` to stderr
- `psst get --vault-only NAME` — ignores .env, returns vault value

### `cmd_run` Behavior

1. Load all vault secrets into env_args
2. Parse .env file
3. For each non-empty .env entry, override or add to env_args
4. Execute subprocess with merged environment

### Edge Cases

- **No .env file:** Zero behavioral change from current behavior
- **Empty .env value:** Not treated as override (vault value used)
- **Secret in .env only:** Works for `get`, `run`, `SECRET -- cmd`
- **Secret in vault only:** Uses vault value as before
- **.env parsing:** Same rules as `cmd_import`

### .env Location

Always looks for `.env` in the current working directory (`$PWD`), consistent with standard tooling (Docker, Node, etc.).

### Vault Requirement

Vault must still be initialized (`need_vault` check). The .env feature extends vault behavior, it doesn't replace it.
