# Contributing

Keep Graph contracts grounded in official v1.0 documentation. Do not add beta,
migration-message impersonation, password grants, arbitrary scenario code or broad
mailbox reads. Preserve fail-closed authentication and explicit mailbox scope.

Install development dependencies using [README](README.md#development-and-authentication).
Before a change: read the typed models, Graph interface and decisions. Add focused
tests for trust-boundary behavior, then run README validation commands.
Regenerate both schemas with `python -m demo_loader.cli --write-schema` after a
model change, and update bundled examples/skill and permissions documentation.

Use fictional data and runtime-generated synthetic IDs in tests. Do not commit
completed .env, azd state, real tenant IDs/mappings, credentials, tokens, journals,
TLS keys or callback URLs. Keep deployment/admin scripts noninteractive where
possible, explicitly check external-command failures and never print credentials.
Do not run live send tests against someone else's tenant.
