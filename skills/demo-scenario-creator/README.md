# Portable scenario-writing skill

Use [SKILL.md](SKILL.md) as instructions/context in Microsoft 365 Copilot Cowork.
No undocumented upload/import feature, manifest or proprietary frontmatter is
assumed. Where directory imports are unavailable, attach the Markdown, schema,
and [example](examples/scenario.yaml), and supply current logical user keys and
channel aliases explicitly.

Request a fictional narrative, then ask for final YAML only. Save that output
as UTF-8 `.yaml` and validate from the loader repository root:

```powershell
python -m demo_loader.cli .\scenario.yaml
# or
pwsh .\scripts\validate-scenario.ps1 -Scenario .\scenario.yaml
```

The validator checks JSON Schema, typed models, duplicate keys, dependencies,
recipients, placeholders and configured aliases. It makes no Graph calls and
does not send anything. Teams scenarios need a real resource mapping to pass
planning. The default example is email-only and safely dry-run.

The [bundled schema](schema/demo-scenario.schema.json) is generated from the same
Pydantic contract as the application. CI detects schema drift. See the
[scenario format](../../docs/scenario-format.md) and
[Teams limitation](../../docs/decisions.md).
