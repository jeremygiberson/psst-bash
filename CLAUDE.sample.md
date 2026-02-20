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
