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

### RDS Proxy does NOT support SQL Server 2022 (version 16.00)
AWS RDS Proxy only supports SQL Server 2016 (`13.00`), 2017 (`14.00`), and 2019 (`15.00`). Attempting to register a SQL Server 2022 instance as a proxy target will fail with `InvalidParameterValue: Database engine SQLSERVER 16.00.x is not supported`. Always use version `15.00` (SQL Server 2019) when combining RDS MSSQL with RDS Proxy.

### MSSQL major_engine_version must be in "XX.00" format for option groups
AWS RDS Option Group API for SQL Server expects the major version as `16.00`, not `16`. Using `split(".", "16.00")[0]` strips the `.00` suffix and causes `InvalidParameterCombination: Cannot find major version 16 for sqlserver-ee`. Always hardcode or preserve the full `XX.00` format when passing `major_engine_version` to the RDS module.

### Lambda runtime preference: Node.js 22 with ESM (.mjs)
This project uses Node.js (`nodejs22.x`) for Lambda functions, not Python. Use `.mjs` extension for ES module syntax (`import`/`export`) — the Lambda runtime auto-detects it without needing `"type": "module"` in `package.json`. AWS SDK v3 (`@aws-sdk/client-*`) is bundled in `nodejs20.x`+, so no `package.json` or dependency installation is needed for SDK-only functions. Handler reference format: `filename.handler` maps to `export async function handler` in the `.mjs` file.

### NLB-to-RDS IP: DNS resolves at plan time, stale on failover
When using an NLB with `target_type = "ip"` pointing at an RDS instance, the IP is resolved from the RDS endpoint DNS at `terraform apply` time. If RDS fails over, the target group IP becomes stale until a re-apply. Always pair this pattern with a Lambda sync function (see `lambda_nlb_updater.tf`) — both event-driven (EventBridge RDS failover events) and periodic (every 5 minutes) to handle maintenance-window IP changes without failover events.

### NLB target group updates: always deregister before registering new IP
When updating NLB IP targets, deregister stale targets before registering the new one. Registering the new IP while old ones remain causes the NLB to round-robin across both, sending ~50% of connections to a dead target. The Lambda updater pattern handles this correctly: fetch current targets → deregister stale ones → register new IP.

### archive provider required for Lambda zip packaging in Terraform
Using `data "archive_file"` to package Lambda source code requires declaring `hashicorp/archive ~> 2.0` in `required_providers`. This is easy to miss since it doesn't produce a visible error until `terraform init`. Always add it alongside Lambda resources. Note: when using `terraform-aws-modules/lambda/aws` with `source_path`, the module handles packaging internally — `hashicorp/archive` is NOT needed in that case.

### Circular dependency between terraform-aws-modules/lambda and terraform-aws-modules/eventbridge
When using both modules together, `allowed_triggers` in the Lambda module references EventBridge rule ARNs, while EventBridge `targets` reference the Lambda ARN — creating a cycle Terraform cannot resolve. **Fix:** omit `allowed_triggers` from the Lambda module entirely, and use standalone `aws_lambda_permission` resources instead. These only need the Lambda function name (from Lambda module) and rule ARN (from EventBridge module), breaking the cycle cleanly. Add a comment in the code explaining why `allowed_triggers` is intentionally absent.

### IAM for Lambda log groups: skip logs:CreateLogGroup when Terraform manages the group
If `aws_cloudwatch_log_group` is explicitly created in Terraform, remove `logs:CreateLogGroup` from the Lambda IAM policy. The group already exists at deploy time, and granting `CreateLogGroup` is unnecessary permission. Keep only `logs:CreateLogStream` and `logs:PutLogEvents` scoped to the specific log group ARN.

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
