# Permissions

Permissions are `resource:action` strings; roles are named sets of them. `instance:*` is held only by the operator and `org:*` only by a company's org role — neither is reachable from a team role, whatever wildcard it grants. A resource's owner holds every team-tier permission on it (owner-ok), and a grant on one resource delegates the permission it names.

## Catalog

| Permission | Tier | Description |
|---|---|---|
| `*:*` | team | Everything at the team tier. Never reaches instance:* or org:*. |
| `*:read` | team | Read every team-visible resource; no AI spend, no mutation. |
| `audit:read` | team | Read the audit trail. |
| `chat:use` | team | Talk to the model: chat, the agent, translation, AI tools. Metered. |
| `documents:delete` | team | Delete text documents. |
| `documents:read` | team | Read text documents. |
| `documents:write` | team | Create and edit text documents. |
| `features:manage` | team | Turn features on and off for teams. |
| `files:delete` | team | Delete repository documents. |
| `files:manage` | team | Steward a document: change visibility, share and revoke. Owners hold it by owner-ok; a manage grant delegates it for one document. |
| `files:read` | team | Open, download and search repository documents; read provenance and the knowledge graph. |
| `files:write` | team | Upload documents and new versions. |
| `instance:*` | instance | Everything at the instance tier; the operator (superadmin). |
| `instance:manage` | instance | Instance administration: branding, localization policy, quotas, orgs, metrics. |
| `localization:manage` | team | Import and export catalogs, queue AI drafts, discard machine drafts. |
| `localization:read` | team | See the Localization Manager's coverage and messages. |
| `localization:review` | team | Approve or send back a colleague's translation (never one's own). |
| `localization:translate` | team | Submit translations. |
| `members:manage` | team | Add and remove team members and set their roles. |
| `memory:read` | team | Read the agent's memory. |
| `memory:write` | team | Write to the agent's memory. |
| `models:serve` | team | Register a model executor for the team. |
| `notes:delete` | team | Delete notes. |
| `notes:manage` | team | Share notes one does not own. |
| `notes:read` | team | Read notes. |
| `notes:write` | team | Create and edit notes. |
| `org:*` | org | Everything at the company tier. Never reaches instance:*. |
| `org:manage` | org | Administer the company: teams and members. Manages, does not read, team data (TEN-2a). |
| `org:read` | org | See the company, its teams, members and audit trail. |
| `quota:manage` | team | Set quotas. |
| `quota:read` | team | See quotas. |
| `research:use` | team | Use the research surfaces. |
| `roles:manage` | team | Create and edit team roles. |
| `roles:read` | team | See the team's roles and what they grant. |
| `settings:manage` | team | Team settings: tokens, feature flags, tool activation, the glossary, seeding, the audit trail. |
| `tasks:delete` | team | Delete tasks. |
| `tasks:read` | team | Read tasks. |
| `tasks:write` | team | Create and edit tasks. |
| `team:create` | team | Create a team in the company. |
| `team:delete` | team | Delete a team. |
| `team:read` | team | See a team in the company. |
| `team:write` | team | Rename a team in the company. |
| `tokens:manage` | team | Issue and revoke API tokens for the team. |
| `tools:invoke` | team | Call tools from the agent or a workflow step; each tool then checks its own permission. |
| `webhooks:manage` | team | Configure outbound webhooks. |
| `workflows:read` | team | See workflow definitions, runs and triggers. |
| `workflows:run` | team | Start and cancel runs. An S3 key needs this scope for its uploads to fire triggers. |
| `workflows:write` | team | Publish workflows and manage triggers. |

## Built-in roles

| Role | Tier | Grants |
|---|---|---|
| Owner (`owner`) | team | `*:*` |
| Admin (`admin`) | team | `members:manage`, `tokens:manage`, `webhooks:manage`, `settings:manage`, `models:serve`, `roles:read`, `audit:read`, `chat:use`, `tools:invoke`, `research:use`, `documents:read`, `documents:write`, `documents:delete`, `notes:read`, `notes:write`, `notes:delete`, `tasks:read`, `tasks:write`, `tasks:delete`, `memory:read`, `memory:write`, `files:read`, `files:write`, `files:delete`, `files:manage`, `localization:read`, `localization:translate`, `localization:review`, `localization:manage`, `workflows:read`, `workflows:write`, `workflows:run` |
| Member (`member`) | team | `chat:use`, `tools:invoke`, `research:use`, `documents:read`, `documents:write`, `notes:read`, `notes:write`, `tasks:read`, `tasks:write`, `memory:read`, `memory:write`, `files:read`, `files:write`, `files:delete`, `localization:read`, `localization:translate`, `workflows:read`, `workflows:run` |
| Viewer (`viewer`) | team | `*:read` |
| Organization Owner (`org_owner`) | org | `org:*`, `team:read`, `team:write`, `team:create`, `team:delete`, `members:manage`, `roles:manage`, `roles:read`, `quota:manage`, `quota:read`, `settings:manage`, `features:manage`, `tokens:manage`, `audit:read`, `workflows:read` |
| Organization Admin (`org_admin`) | org | `org:read`, `org:manage`, `team:read`, `team:write`, `team:create`, `members:manage`, `roles:manage`, `roles:read`, `quota:manage`, `quota:read`, `settings:manage`, `features:manage`, `tokens:manage`, `audit:read`, `workflows:read` |

## Role matrix

Which built-in role covers which permission (wildcards expanded).

| Permission | owner | admin | member | viewer | org_owner | org_admin |
|---|---|---|---|---|---|---|
| `audit:read` | ✓ | ✓ |  | ✓ | ✓ | ✓ |
| `chat:use` | ✓ | ✓ | ✓ |  |  |  |
| `documents:delete` | ✓ | ✓ |  |  |  |  |
| `documents:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `documents:write` | ✓ | ✓ | ✓ |  |  |  |
| `features:manage` | ✓ |  |  |  | ✓ | ✓ |
| `files:delete` | ✓ | ✓ | ✓ |  |  |  |
| `files:manage` | ✓ | ✓ |  |  |  |  |
| `files:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `files:write` | ✓ | ✓ | ✓ |  |  |  |
| `instance:manage` |  |  |  |  |  |  |
| `localization:manage` | ✓ | ✓ |  |  |  |  |
| `localization:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `localization:review` | ✓ | ✓ |  |  |  |  |
| `localization:translate` | ✓ | ✓ | ✓ |  |  |  |
| `members:manage` | ✓ | ✓ |  |  | ✓ | ✓ |
| `memory:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `memory:write` | ✓ | ✓ | ✓ |  |  |  |
| `models:serve` | ✓ | ✓ |  |  |  |  |
| `notes:delete` | ✓ | ✓ |  |  |  |  |
| `notes:manage` | ✓ |  |  |  |  |  |
| `notes:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `notes:write` | ✓ | ✓ | ✓ |  |  |  |
| `org:manage` |  |  |  |  | ✓ | ✓ |
| `org:read` |  |  |  |  | ✓ | ✓ |
| `quota:manage` | ✓ |  |  |  | ✓ | ✓ |
| `quota:read` | ✓ |  |  | ✓ | ✓ | ✓ |
| `research:use` | ✓ | ✓ | ✓ |  |  |  |
| `roles:manage` | ✓ |  |  |  | ✓ | ✓ |
| `roles:read` | ✓ | ✓ |  | ✓ | ✓ | ✓ |
| `settings:manage` | ✓ | ✓ |  |  | ✓ | ✓ |
| `tasks:delete` | ✓ | ✓ |  |  |  |  |
| `tasks:read` | ✓ | ✓ | ✓ | ✓ |  |  |
| `tasks:write` | ✓ | ✓ | ✓ |  |  |  |
| `team:create` | ✓ |  |  |  | ✓ | ✓ |
| `team:delete` | ✓ |  |  |  | ✓ |  |
| `team:read` | ✓ |  |  | ✓ | ✓ | ✓ |
| `team:write` | ✓ |  |  |  | ✓ | ✓ |
| `tokens:manage` | ✓ | ✓ |  |  | ✓ | ✓ |
| `tools:invoke` | ✓ | ✓ | ✓ |  |  |  |
| `webhooks:manage` | ✓ | ✓ |  |  |  |  |
| `workflows:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `workflows:run` | ✓ | ✓ | ✓ |  |  |  |
| `workflows:write` | ✓ | ✓ |  |  |  |  |

