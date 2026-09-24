# Hermes First Agent

Private starter distribution for creating an organization's first Hermes **Company AI Advisor**.

## Version

`0.4.0 — Multi-Gateway & Lifecycle`

The First Agent remains the focused Company AI Advisor defined in v0.3. This release adds safer installation, multiple messaging gateways, update/uninstall lifecycle support, and a first-time installation checklist.

---

# First-Time Installation Checklist

Before running `install.sh`, complete the following.

## 1. Hermes environment

- [ ] Hermes Agent is installed.
- [ ] At least one LLM provider/model is configured.
- [ ] `hermes doctor` passes without blocking errors.
- [ ] Git is installed.
- [ ] curl is installed.
- [ ] You have write access to the Hermes home directory.
- [ ] You have access to this private GitHub repository.

Recommended first step:

```bash
bash check-environment.sh
```

The installer runs this check again automatically. Any **FAIL** stops installation.

## 2. Prepare Tenant / Business information

Have these ready:

- [ ] Tenant display name
- [ ] Tenant code
- [ ] Whether the tenant has multiple businesses/products
- [ ] Business display name and business code, if applicable
- [ ] Company/business website, optional
- [ ] User department/role, optional

The installer generates the Agent ID automatically.

```text
Single business:
<tenant>-ai-advisor

Multi business:
<tenant>-<business>-ai-advisor
```

Examples:

```text
acme-ai-advisor
skg-soocker-ai-advisor
```

## 3. Choose at least one Messaging Gateway

v0.4 supports:

- [ ] LINE
- [ ] Telegram
- [ ] WeChat / Weixin

You may select one or multiple gateways.

```text
LINE ---------┐
Telegram -----┼----> one Company AI Advisor profile
Weixin -------┘
```

**One Agent, Many Gateways, Many Sessions.**

The gateways share the same Agent profile, SOUL, Skills, durable Memory, and tools. Each messaging conversation still has its own session/context.

## 4. If you choose LINE

Prepare:

- [ ] LINE Developers account
- [ ] Messaging API Channel
- [ ] Long-lived Channel Access Token
- [ ] Channel Secret
- [ ] Allowed LINE user ID(s), or explicitly accept temporary allow-all
- [ ] Public HTTPS base URL / tunnel

The installer validates the Channel Access Token before creating the profile.

LINE webhook path:

```text
/line/webhook
```

Example:

```text
https://agent.example.com/line/webhook
```

## 5. If you choose Telegram

Prepare:

- [ ] Telegram account
- [ ] Bot created through BotFather
- [ ] Telegram Bot Token
- [ ] Allowed Telegram numeric user ID(s), or explicitly accept temporary allow-all

The installer validates the Bot Token through Telegram `getMe` before creating the profile.

Telegram normally uses long polling, so a public HTTPS webhook is not required.

## 6. If you choose WeChat / Weixin

Prepare:

- [ ] Personal WeChat account
- [ ] Mobile phone with WeChat available for QR-code login

The installer uses Hermes native:

```bash
hermes -p <agent-id> gateway setup
```

Select **Weixin** when prompted and scan the QR code.

---

# Installation

Clone the private repository:

```bash
git clone git@github.com:cerjary/hermes-first-agent.git
cd hermes-first-agent
```

Run the environment check:

```bash
bash check-environment.sh
```

Then install:

```bash
bash install.sh
```

## Install flow

```text
Environment Preflight
        ↓
Tenant / Business input
        ↓
Gateway selection
        ↓
Credential validation
        ↓
Installation Plan
        ↓
User confirmation
        ↓
Create Hermes Profile
        ↓
Write SOUL / Skills / Memory / Gateway config
        ↓
Weixin native QR setup, if selected
        ↓
Hermes doctor
        ↓
Agent smoke test
```

If a fatal error occurs after the profile is created, the installer attempts to remove the newly created profile so that a partial First Agent is not left behind.

Existing profiles are never overwritten automatically.

---

# What is installed

The profile receives:

- `SOUL.md`
- `company-context`
- `prompt-advisor`
- `ai-work-advisor`
- `agent-planning-advisor`
- Tenant/Business seed memory
- Selected gateway configuration
- Gateway credentials in the profile's private `.env`
- `FIRST_AGENT.yaml` installation manifest

Example manifest:

```yaml
source: cerjary/hermes-first-agent
version: 0.4.0
agent_id: skg-soocker-ai-advisor
tenant_code: skg
business_code: soocker
gateways:
  - line
  - telegram
```

The manifest contains lifecycle metadata only. It does **not** contain gateway secrets.

---

# Same Agent, different Sessions

A LINE message and a Telegram message may reach the same Agent, but they are not automatically one continuous conversation.

```text
Same Profile / SOUL / Skills / Memory     YES
Same Gateway session history              NO
```

Use durable Memory for long-term organization context.

Use Sessions for the working context of a particular conversation.

Hermes manages context compression for long sessions, but users should still use `/new` when a task or topic is complete.

---

# Start the Gateway

Interactive:

```bash
hermes -p <agent-id> gateway
```

Persistent service:

```bash
hermes -p <agent-id> gateway install
```

For LINE, configure the LINE Developers Console webhook using:

```text
https://YOUR-HOST/line/webhook
```

---

# Update an installed First Agent

Use:

```bash
bash update.sh
```

The script:

1. verifies the target is a First Agent profile
2. runs the environment check
3. updates the local repository with `git pull --ff-only`
4. runs `hermes profile update <agent-id> --yes`
5. updates the First Agent manifest version

Hermes profile update preserves user-owned state such as `.env`, memories, sessions, and credentials.

Gateway configuration is also preserved unless explicitly replaced.

---

# Uninstall / Clean Removal

Use:

```bash
bash uninstall.sh
```

The script refuses to delete profiles that do not contain a matching First Agent manifest.

Before deletion you can choose:

1. delete directly
2. export the profile first
3. cancel

Permanent deletion requires typing the exact Agent ID.

Hermes profile deletion removes the profile data, gateway service, shell alias, memories, sessions, Skills, config, and profile credentials while preserving Hermes itself and all other profiles.

> Profile export does not include every secret/credential. Use a full Hermes backup strategy when credential recovery is required.

---

# Agent scope

The First Agent is a focused **Company AI Advisor**, not a general-purpose assistant.

It handles:

1. Company Context
2. Prompt Advisor
3. AI Work Advisor
4. Agent Planning Advisor

It does not directly execute unrelated work such as building games, general application development, unrelated translation, homework, or domain-specialist work.

It is not an Agent Router and not an Agent Builder.

---

# Naming practice

Standard pattern:

```text
<tenant>[-<business>]-<domain>-<role>
```

See `NAMING.md`.

---

# Security defaults

- Keep this repository private.
- Do not commit `.env`, access tokens, API keys, OAuth files, or `auth.json`.
- Prefer per-platform allowlists.
- Treat allow-all as temporary development configuration.
- Secrets are entered without terminal echo where practical.
- Install manifests never contain gateway secrets.
- The uninstall script refuses to delete unrelated Hermes profiles.
- Future specialist-agent recommendations should follow least privilege.

---

# Troubleshooting

## Environment check fails

Run:

```bash
bash check-environment.sh
```

Fix every **FAIL** item before retrying.

## Profile already exists

The installer intentionally stops instead of overwriting it.

Use one of:

```bash
bash update.sh
bash uninstall.sh
```

## LINE token validation fails

Confirm the token belongs to the intended LINE Messaging API channel and has not expired or been revoked.

## Telegram token validation fails

Confirm the BotFather token and regenerate it if necessary.

## Weixin QR login fails

Retry the Hermes native setup for the installed profile:

```bash
hermes -p <agent-id> gateway setup
```

## Gateway is installed but not responding

Check:

```bash
hermes -p <agent-id> doctor
hermes -p <agent-id> gateway
```

Then verify the selected platform's credentials, allowlist, and external webhook/network requirements.

---

# Direct Hermes distribution install

The repository remains a valid Hermes Profile Distribution:

```bash
hermes profile install git@github.com:cerjary/hermes-first-agent.git --name acme-ai-advisor --alias
```

However, the raw command bypasses the First Agent onboarding, gateway selection, credential validation, install manifest, and lifecycle preflight.

For normal customer installation, use:

```bash
bash install.sh
```

---

# Access control

This repository is proprietary and intended only for users explicitly granted access by the repository owner. Do not redistribute, mirror, publish, or sublicense the installer or bundled agent templates without written permission.
