# Security policy

Use only isolated licensed CDX tenants and fictional data. Default delivery and
external-recipient overrides are off. Administrators must validate mailbox scope,
permissions, enterprise assignment and HTTPS before enabling delivery.

Do not publish vulnerabilities with exploitable details or tenant credentials.
Use the repository owner's private GitHub security reporting channel if enabled;
otherwise contact the owner privately before disclosure. Reports should contain
minimal reproduction, affected version and sanitized impact, never tokens,
passwords, confidential messages or full execution journals.

See [threat model](docs/threat-model.md), [permission matrix](docs/graph-permissions.md)
and [operations](docs/operations.md). CI scans Python source/dependencies;
container operating-system and Caddy advisories must also be reviewed at release.
This POC has not been certified for production use. No exactly-once delivery or
unattended multi-user Teams impersonation guarantee is made.
