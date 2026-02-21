# psst 🤫

Your secrets stay out of the AI context window. Period.

psst keeps sensitive values — API keys, database URLs, tokens — away from AI agents. It works two ways: as a transparent shield for your existing `.env` files, and as an encrypted vault for secrets that deserve stronger protection. Pure bash, zero dependencies beyond `openssl`.

## Why this exists

AI coding agents are powerful, but they read everything in their context. That includes `.env` files, configuration snippets pasted into chat, and anything else in the working directory. Once a secret enters the context window, it is logged, cached, and potentially echoed back.

psst eliminates that exposure. Secrets are encrypted at rest and injected into subprocesses at runtime. The agent writes commands; psst supplies the credentials. Values flow through the process environment, never through the conversation.

This project is a bash reimplementation of Michael Livashvili's [`psst`](https://github.com/Michaelliv/psst), which solves the same problem with a more feature-rich Node.js toolchain. This version trades those features for simplicity: a single shell script, no runtime dependencies, and identical behavior on any system with `bash` and `openssl`.

## Quick start

```bash
# Copy psst somewhere on your PATH
cp psst /usr/local/bin/
chmod +x /usr/local/bin/psst

# Initialize a vault in your project
cd your-project/
psst init

# Add secrets
psst set STRIPE_KEY            # interactive prompt (hidden input)
psst set DATABASE_URL

# Or import from an existing .env file
psst import .env
```

If your project already has a `.env` file, psst reads it automatically. No import step required — `psst run` and `psst SECRET -- cmd` resolve `.env` values on the fly.

## Usage

### For humans

```bash
psst init                       # Create vault in current directory
psst set <NAME> [--stdin]       # Add or update a secret
psst get [-v] <NAME>            # Retrieve a value (-v shows source)
psst get --vault-only <NAME>    # Retrieve from vault, ignoring .env
psst list                       # List all secrets with source annotations
psst rm <NAME>                  # Delete a secret
psst history <NAME>             # Show version history with masked values
psst import <file|--stdin>      # Import secrets from .env format
psst export                     # Export all vault secrets as .env format
psst onboard-claude             # Add psst instructions to CLAUDE.md
```

### For agents

Agents do not read secrets. They use them:

```bash
# Inject specific secrets into a command
psst STRIPE_KEY -- curl -H "Authorization: Bearer $STRIPE_KEY" https://api.stripe.com/v1/charges

# Inject all secrets (vault + .env) into a command
psst run ./deploy.sh
```

The agent writes the command. psst handles the secrets. The subprocess receives the real values; the agent sees only stdout/stderr and the exit code.

```
┌─────────────────────────────────────────────┐
│ Agent context                               │
│                                             │
│ > psst STRIPE_KEY -- curl ...               │
│ > [exit code 0]                             │
│                                             │
│ (no secret values here)                     │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│ psst                                        │
│                                             │
│ 1. Resolve STRIPE_KEY (.env or vault)       │
│ 2. Inject into subprocess environment       │
│ 3. Execute the command                      │
│ 4. Return exit code                         │
└─────────────────────────────────────────────┘
```

### .env override

If a `.env` file exists in the current directory, psst reads it automatically. Values from `.env` take precedence over vault secrets of the same name. No configuration needed — every resolution path (`psst run`, `psst SECRET -- cmd`, `psst get`) respects this layering.

Use `psst list` to see where each secret comes from:

```
$ psst list
API_KEY       (.env overrides vault)
DB_URL        (vault)
LOCAL_TOKEN   (.env)
```

Use `psst get -v` to check the source of a specific secret:

```
$ psst get -v API_KEY
psst: source: .env overrides vault
sk_live_abc123...
```

Use `psst get --vault-only` to bypass `.env` and read directly from the vault.

This layering lets you keep a `.env` file for local development while the vault holds production or shared credentials. psst ensures neither source leaks into the agent's context.

### Secret history

Every `psst set` appends rather than overwrites. Previous values are preserved automatically.

```bash
$ psst history STRIPE_KEY

History for STRIPE_KEY (3 version(s)):

  v1          2026-01-10T09:15:00Z  sk_l**************
  v2          2026-01-15T14:30:00Z  sk_l**************
  current     2026-02-20T11:00:00Z  sk_l**************
```

Values are masked in the output (first 4 characters visible). The full history lives in `.psst/secrets/STRIPE_KEY` as an append-only text file — one `timestamp<tab>encrypted_blob` per line. You can inspect or trim it manually if needed.

## How it works

Each project gets a `.psst/` directory:

```
.psst/
├── .key            # Pointer: contains the name of the key in ~/.ssh/
└── secrets/
    ├── STRIPE_KEY          # Encrypted, append-only
    └── DATABASE_URL        # One file per secret

~/.ssh/
└── .psst_a1b2c3d4e5f6    # Actual encryption key (per-project, chmod 600)
```

Secrets are encrypted with AES-256-CBC via `openssl`. Each project gets its own random 256-bit encryption key, stored in `~/.ssh/` alongside your SSH keys — not in the project directory. The `.psst/.key` file is just a pointer containing the key's filename, never the key material itself.

When a `.env` file is present, psst layers it on top of the vault. The resolution order is: `.env` wins over vault. This happens transparently during `get`, `run`, and selective injection (`SECRET -- cmd`).

`psst init` adds `.psst/` to your `.gitignore` automatically. The `onboard-claude` command patches `.claude/settings.json` to deny read access to `.env`, `.env.*`, and `.psst/**` — defense-in-depth that prevents the agent from reading secret files directly, even if it tries.

### Security model

The threat model is narrowly scoped: keep secrets out of AI agent context windows, terminal history, and version control.

**What it prevents:** secrets appearing in agent context, terminal scrollback, `.env` files committed to git, and subprocess stdout. The encryption key lives in `~/.ssh/`, not in the project directory, so it cannot be accidentally committed or read by an agent browsing project files. The `onboard-claude` command adds file-read restrictions to `.claude/settings.json`, blocking direct access to `.env` and `.psst/` even if the agent attempts it.

**What it doesn't prevent:** anyone with access to both `~/.ssh/.psst_*` and `.psst/secrets/` can decrypt your secrets. This is the same trust boundary as SSH keys — if an attacker has read access to your home directory, you have bigger problems.

**No keychain dependency** means there is no OS-level unlock gate on the encryption key. The tradeoff is simplicity and portability: the tool works identically on any system with bash and openssl, including headless CI runners, containers, and SSH sessions.

## Testing

The project includes 85 tests covering all commands, `.env` override behavior, and edge cases.

```bash
# Run with the included bash test runner (zero dependencies)
bash test-psst.sh
```

Tests are fully isolated — each test runs in its own temporary directory and cleans up after itself.

## Requirements

- `bash` (4.0+)
- `openssl`

That's it. Both ship with macOS and virtually every Linux distribution.

## Acknowledgments

This project is a bash reimplementation of [psst](https://github.com/Michaelliv/psst) by [Michael Livashvili](https://github.com/Michaelliv). The original is a more full-featured tool with keychain integration, secret tagging, environment management, and agent onboarding — worth checking out if you want those capabilities and don't mind the Node.js dependency.

## License

MIT
