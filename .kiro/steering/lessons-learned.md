---
inclusion: auto
description: Project-specific patterns, preferences, and lessons learned over time (user-editable)
---

# Lessons Learned

This file captures project-specific patterns, coding preferences, common pitfalls, and architectural decisions that emerge during development. It serves as a workaround for continuous learning by allowing you to document patterns manually.

**How to use this file:**
1. The `extract-patterns` hook will suggest patterns after agent sessions
2. Review suggestions and add genuinely useful patterns below
3. Edit this file directly to capture team conventions
4. Keep it focused on project-specific insights, not general best practices

---

## Project-Specific Patterns

*Document patterns unique to this project that the team should follow.*

### Handover scripts: one file per resource type
Each AWS resource gathering command should live in its own separate `.ps1` file (e.g., `gather-aws-info.ps1`, `gather-server-specs.ps1`) rather than being combined into a monolithic script. This keeps scripts independently runnable, easier to debug, and allows the customer to execute only what they need.

### AWS CLI tag filtering: prefer PowerShell-side filtering over --filters
AWS CLI `--filters "Name=tag:Key,Values=..."` is case-sensitive and can return empty fields for terminated instances. Instead, fetch all instances with the tag value in the JMESPath query, then filter in PowerShell with `Where-Object`. This also enables showing available tag values when no match is found, making debugging easier for the user.

### Always exclude terminated instances in describe-instances queries
Add `Instances[?State.Name!='terminated'][]` to JMESPath queries (note the trailing `[]` to flatten). Terminated instances return incomplete data (missing tags, IPs) and pollute results. This applies to all scripts that query EC2 instances.

### JMESPath filter expressions require `[]` flatten after the filter
When using `[?condition]` in JMESPath, the result is a nested array. Always append `[]` to flatten: `Instances[?State.Name!='terminated'][].{...}` not `Instances[?State.Name!='terminated'].{...}`. Without flattening, `ConvertFrom-Json` returns objects wrapped in extra array layers, causing `Where-Object` to match nothing and CSV output to show empty values.

### Example: API Error Handling
```typescript
// Always use our custom ApiError class for consistent error responses
throw new ApiError(404, 'Resource not found', { resourceId });
```

---

## Code Style Preferences

*Document team preferences that go beyond standard linting rules.*

### Example: Import Organization
```typescript
// Group imports: external, internal, types
import { useState } from 'react';
import { Button } from '@/components/ui';
import type { User } from '@/types';
```

---

## Kiro Hooks

### `install.sh` is additive-only — it won't update existing installations
The installer skips any file that already exists in the target (`if [ ! -f ... ]`). Running it against a folder that already has `.kiro/` will not overwrite or update hooks, agents, or steering files. To push updates to an existing project, manually copy the changed files or remove the target files first before re-running the installer.

### README.md mirrors hook configurations — keep them in sync
The hooks table and Example 5 in README.md document the action type (`runCommand` vs `askAgent`) and behavior of each hook. When changing a hook's `then.type` or behavior, update both the hook file and the corresponding README entries to avoid misleading documentation.

### Prefer `askAgent` over `runCommand` for file-event hooks
`runCommand` hooks on `fileEdited` or `fileCreated` events spawn a new terminal session every time they fire, creating friction. Use `askAgent` instead so the agent handles the task inline. Reserve `runCommand` for `userTriggered` hooks where a manual, isolated terminal run is intentional (e.g., `quality-gate`).

### RDS MSSQL Enterprise: minimum instance class is db.t3.xlarge
Unlike Standard/Web/Express editions which support `db.t3.small` or `db.r5.large`, Enterprise Edition starts at `db.t3.xlarge` (4 vCPU, 16 GB RAM). Don't assume smaller classes will work — AWS will reject the `CreateDBInstance` call. Always reference [AWS docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.InstanceClasses.html) for edition-specific minimums.

### RDS Proxy for MSSQL uses engine_family = "SQLSERVER"
When configuring `terraform-aws-modules/rds-proxy/aws` for MSSQL, set `engine_family = "SQLSERVER"` (not `MSSQL`, not `SQL_SERVER`). This is a common typo that causes plan-time errors.

### Terraform module sources: terraform-aws-modules naming convention
Modules from the terraform-aws-modules org follow the pattern `terraform-aws-modules/<service>/aws` on the registry (e.g., `terraform-aws-modules/rds/aws`, `terraform-aws-modules/rds-proxy/aws`, `terraform-aws-modules/security-group/aws`). GitHub repos use hyphenated names like `terraform-aws-rds-proxy` but the registry source uses slashes.

---

## Common Pitfalls

*Document mistakes that have been made and how to avoid them.*

### Example: Database Transactions
- Always wrap multiple database operations in a transaction
- Remember to handle rollback on errors
- Don't forget to close connections in finally blocks

---

## Architecture Decisions

*Document key architectural decisions and their rationale.*

### Example: State Management
- **Decision**: Use Zustand for global state, React Context for component trees
- **Rationale**: Zustand provides better performance and simpler API than Redux
- **Trade-offs**: Less ecosystem tooling than Redux, but sufficient for our needs

---

## Notes

- Keep entries concise and actionable
- Remove patterns that are no longer relevant
- Update patterns as the project evolves
- Focus on what's unique to this project
