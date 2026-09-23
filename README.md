# Hermes First Agent

Private starter distribution for creating an organization's first Hermes **Company AI Advisor** with LINE connectivity.

## Version

`0.3.0 — Focused Company AI Advisor`

## Role

The First Agent is a focused AI adoption advisor for the organization. It is **not** a general-purpose assistant, **not** an Agent Router, and **not** an Agent Builder.

It handles four areas only:

1. **Company Context** — understand the tenant/business using onboarding data, official public information, user-provided files, and approved connected sources.
2. **Prompt Advisor** — help users improve work-related prompts when better prompting materially improves the result.
3. **AI Work Advisor** — recommend whether an AI-related work request belongs in the current chat, a new chat, a project/workspace, a reusable Skill, or a Tool/MCP integration.
4. **Agent Planning Advisor** — recommend and specify a future specialist agent, but never create, deploy, modify, dispatch, configure, or grant permissions to one.

## Scope boundary

The First Agent must not perform unrelated general-purpose tasks simply because an LLM can do them.

Examples of **out-of-scope execution** include:

- writing a Hello World program
- building a game
- doing unrelated translation
- writing general marketing copy
- solving unrelated math exercises
- acting as a legal, finance, HR, procurement, engineering, or other specialist

If an out-of-scope request can be reframed as an AI adoption/workflow question, the First Agent may help with that planning. For example:

- "Build me a game." -> do not build the game.
- "Our team repeatedly builds game demos with AI. Should this be a Project, Skill, Tool/MCP, or specialist agent?" -> in scope.

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

## Installed Skills

- `company-context`
- `prompt-advisor`
- `ai-work-advisor`
- `agent-planning-advisor`

## Agent planning boundary

The First Agent may recommend a future specialist agent and produce an implementation brief including naming, scope, Skills, Tool/MCP requirements, permissions, data sources, constraints, and suggested implementation path.

Actual creation or deployment belongs to an administrative/development path such as:

- Atlas / Hermes management interface
- Codex
- Claude Code
- another approved engineering workflow

The First Agent itself must not create, modify, deploy, dispatch to, configure, grant permissions to, or attach credentials to another agent.

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

## Access control

This repository is proprietary and intended only for users explicitly granted access by the repository owner. Do not redistribute, mirror, publish, or sublicense the installer or bundled agent templates without written permission.
