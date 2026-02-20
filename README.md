# psst 🤫

A local secret manager for AI agent workflows — in pure bash.

Secrets are encrypted at rest and injected into subprocesses at runtime, so your agent can *use* secrets without ever *seeing* them. No secret values in the context window. No secret values in terminal history. No dependencies beyond `bash` and `openssl`.

## Why this exists

This project is inspired by Michael Livashvili's excellent [`psst`](https://github.com/Michaelliv/psst), which solves the same core problem: keeping secrets out of your AI agent's context. That project is a polished, feature-rich tool built on Node.js (via Bun), with keychain integration, secret tagging, environments, git hook scanning, and an agent onboarding command.

This fork reimplements the idea as a single bash script with zero external dependencies. The motivation is simple: not every developer has Node.js installed, but every developer on macOS or Linux has `bash` and `openssl`. If you're already living in a terminal — especially when working with CLI-based agents like Claude Code — adding a Node.js dependency for secret management feels like overkill. A ~380 line shell script that uses only tools already on your system fits the workflow more naturally.

This version intentionally omits features from the original that didn't fit the "keep it minimal" goal: OS keychain integration, environment namespacing, secret tagging, git pre-commit hooks, and output redaction. What remains is the core value proposition — encrypted local secrets, subprocess injection, append-only history — and nothing else.

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

## Usage

### For humans

```bash
psst set <name>                 # Add/update a secret (interactive)
psst set <name> --stdin         # Pipe a value in
psst get <name>                 # Retrieve a value (debugging only)
psst list                       # List all secret names
psst rm <name>                  # Delete a secret
psst history <name>             # Show version history with masked values
psst import <file>              # Import from a .env file
psst import --stdin             # Import from stdin
psst export                     # Export all secrets in .env format
```

### For agents

Agents don't read secrets — they use them:

```bash
# Inject specific secrets into a command
psst STRIPE_KEY -- curl -H "Authorization: Bearer $STRIPE_KEY" https://api.stripe.com/v1/charges

# Inject all vault secrets into a command
psst run ./deploy.sh
```

The agent writes the command. `psst` handles the secrets. The subprocess gets the real values; the agent only sees stdout/stderr and the exit code.

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
│ 1. Decrypt STRIPE_KEY from .psst/secrets/   │
│ 2. Inject into subprocess environment       │
│ 3. Execute the command                      │
│ 4. Return exit code                         │
└─────────────────────────────────────────────┘
```

### Secret history

Every `psst set` appends rather than overwrites. Previous values are preserved automatically.

```bash
$ psst history STRIPE_KEY

History for STRIPE_KEY (3 version(s)):

  v1          2026-01-10T09:15:00Z  sk_l**************
  v2          2026-01-15T14:30:00Z  sk_l**************
  current     2026-02-20T11:00:00Z  sk_l**************
```

Values are masked in the output (first 4 characters visible). The full history lives in `.psst/secrets/STRIPE_KEY` as a simple append-only text file — one `timestamp<tab>encrypted_blob` per line. You can inspect or trim it manually if needed.

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

This means the encryption key is never at risk of being committed to git, read by an AI agent browsing project files, or exposed in a directory listing of your project. It has the same security posture as your SSH keys.

Each secret is stored as a timestamped, encrypted line — the latest line is the current value, older lines are history.

`psst init` will add `.psst/` to your `.gitignore` automatically if you're in a git repository.

### Security model

This is a practical tool, not a vault. The threat model is narrowly scoped:

**What it prevents:** secrets appearing in agent context windows, terminal history, `.env` files checked into git, and subprocess stdout. The encryption key lives in `~/.ssh/`, not in the project directory, so it can't be accidentally committed or read by an agent browsing your project files.

**What it doesn't prevent:** anyone with access to both `~/.ssh/.psst_*` and `.psst/secrets/` can decrypt your secrets. This is the same trust boundary as SSH keys — if an attacker has read access to your home directory, you have bigger problems.

**No keychain dependency** means there's no OS-level unlock gate on the encryption key. The tradeoff is simplicity and portability: the tool works identically on any system with bash and openssl, including headless CI runners, containers, and SSH sessions.

## Testing

The project includes a test suite with 53 cases covering all commands and edge cases.

```bash
# Run with the included bash test runner (zero dependencies)
bash test-psst.sh

# Or with bats-core if available
bats test/psst.bats
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
