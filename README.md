# Hermes First Agent

Private starter distribution for creating an organization's first Hermes **Company AI Advisor** with LINE connectivity.

## Role

The First Agent is intentionally not an Agent Router and not an Agent Builder.

It provides four practical capabilities:

- General Assistant — answer useful day-to-day questions directly.
- Prompt Advisor — improve prompts when doing so materially helps.
- Workspace Advisor — recommend current chat vs new chat vs project/workspace vs Skill vs Tool/MCP.
- Agent Planning Advisor — recommend and specify a future specialist agent, but never create, deploy, modify, dispatch, or grant permissions to one.

It can also build lightweight company context over time from onboarding data, official public information, user-provided documents, and connected sources. It is not intended to become a dedicated company knowledge agent.

## Naming practice

Standard Agent ID:

```text
<tenant>[-<business>]-<domain>-<role>
```

For the First Agent:

```text
Single-business tenant: <tenant>-ai-advisor
Multi-business tenant:  <tenant>-<business>-ai-advisor
```

Examples:

```text
acme-ai-advisor
skg-soocker-ai-advisor
skg-nextoa-ai-advisor
skg-shopline-order-analyst
skg-soocker-opportunity-collector
```

See `NAMING.md` for the complete practice.

## What the installer asks

1. Tenant display name.
2. Tenant code.
3. Whether the tenant has multiple businesses/products.
4. Business/product display name and code, only when needed.
5. Website (optional).
6. User department/role (optional).
7. LINE Channel Access Token.
8. LINE Channel Secret.
9. LINE allowed user IDs (recommended).
10. Public HTTPS URL (optional during initial setup).

The Agent ID and display name are generated automatically from the naming practice. The installer does not ask the user to invent an Agent ID.

## Example

Single-business company:

```text
Tenant display name: Acme
Tenant code: acme
Multiple businesses/products? No

Agent ID: acme-ai-advisor
Display name: Acme AI Advisor
```

Multi-business group:

```text
Tenant display name: Soocker Group
Tenant code: skg
Multiple businesses/products? Yes
Business display name: Soocker
Business code: soocker

Agent ID: skg-soocker-ai-advisor
Display name: Soocker AI Advisor
```

## Prerequisite

Hermes Agent must already be installed and configured with an LLM provider.

## Private GitHub installation

Keep this repository **Private** and grant read access only to approved GitHub users.

### SSH

```bash
git clone git@github.com:cerjary/hermes-first-agent.git
cd hermes-first-agent
bash install.sh
```

### GitHub CLI

```bash
gh auth login
gh repo clone cerjary/hermes-first-agent
cd hermes-first-agent
bash install.sh
```

## Installed skills

- `company-context`
- `prompt-advisor`
- `workspace-advisor`
- `agent-planning-advisor`

## Agent planning boundary

The First Agent may recommend a future specialist agent and produce a build specification including naming, scope, Skills, Tool/MCP requirements, permissions, data sources, and constraints.

Actual creation or deployment belongs to an administrative/development path such as:

- Atlas / Hermes management interface
- Codex
- Claude Code
- another approved engineering workflow

The First Agent itself must not create, modify, deploy, route to, grant permissions to, or attach credentials to another agent.

## LINE credential storage

LINE secrets are written to:

```text
~/.hermes/profiles/<agent-id>/.env
```

with file mode `600`. They are never stored in this repository.

## Direct Hermes distribution install

The repository remains a valid Hermes Profile Distribution. For example:

```bash
hermes profile install git@github.com:cerjary/hermes-first-agent.git --name acme-ai-advisor --alias
```

For the normal onboarding and naming flow, use `bash install.sh` instead.

## LINE webhook

Default listener port: `8646`

Webhook path:

```text
/line/webhook
```

For production, expose the gateway using a fixed HTTPS hostname and configure LINE Developers Console with:

```text
https://YOUR-HOST/line/webhook
```

## Security model

- Keep the repository private.
- Grant repository access only to approved users.
- Prefer SSH keys or GitHub CLI authentication; do not embed GitHub PATs in scripts.
- Never commit `.env`, LINE tokens, provider API keys, OAuth files, or `auth.json`.
- Prefer `LINE_ALLOWED_USERS`; use `LINE_ALLOW_ALL_USERS=true` only temporarily during setup.
- Use least-privilege permissions when planning future specialist agents.

## Updating

```bash
hermes profile update <agent-id>
```

Hermes keeps user-owned state such as `.env`, memories, sessions, and credentials separate from distribution-owned files.

## Version

`0.2.0`

## Access control

This repository is proprietary and intended only for users explicitly granted access by the repository owner. Do not redistribute, mirror, publish, or sublicense the installer or bundled agent templates without written permission.
