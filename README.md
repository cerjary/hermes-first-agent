# Hermes First Agent

Private starter distribution for creating an organization's first Hermes **Company AI Advisor**.

## Version

`0.5.0 — Topology-Aware Installer & Lifecycle Hardening`

v0.5 keeps the focused Company AI Advisor introduced in v0.3 and the multi-platform lifecycle introduced in v0.4. The main change is operational: installation now inherits the already-working default Hermes LLM configuration, detects the host gateway topology, allocates a LINE port only when required, and uses non-destructive post-install verification.

---

# Product boundary

The First Agent is **not** a General Assistant, Agent Router, or Agent Builder.

It focuses on four capabilities:

1. Company Context
2. Prompt Advisor
3. AI Work Advisor
4. Agent Planning Advisor

The Agent design lives in `SOUL.md` and the four bundled Skills. v0.5 does not broaden that role.

---

# Compatibility contract

## Hermes baseline

v0.5 requires:

```text
Hermes Agent >= 0.21.0
```

The v0.5 compatibility logic is designed around the Hermes 0.21.x line, including both:

- older/per-profile gateway deployments such as Hermes 0.21.0
- host-level multiplex gateway deployments that are explicitly configured or already observable at runtime

v0.5 does not infer multiplex mode from the version number alone and does not migrate the host automatically.

`check-environment.sh` warns when the detected Hermes version is outside the 0.21.x compatibility line. Do not assume an unreleased Hermes `main` change is automatically certified just because it is newer.

## LLM prerequisite

Before installing the First Agent, the **default Hermes profile must already have a working LLM model/provider**.

Verify this first:

```bash
hermes chat -q "Reply only: OK"
```

The First Agent installer does **not** run a second Hermes provider setup wizard and does not ask the customer to enter the LLM API key again.

Instead, installation follows this rule:

```text
Inherit on install, independent after install.
```

The new First Agent receives the default profile's current model/provider configuration and the static provider credentials needed for that model. Root Hermes OAuth login state remains available according to Hermes' own profile authentication behavior.

The installer does **not** inherit the default profile's:

- SOUL
- Skills
- memories
- sessions
- LINE / Telegram / Weixin credentials
- messaging allowlists
- gateway routing

After installation, changing the default profile's model does not silently change the First Agent.

---

# First-Time Installation Checklist

Before running `install.sh`, prepare:

## 1. Hermes

- [ ] Hermes Agent 0.21.0 or later is installed
- [ ] Default profile has a model/provider configured
- [ ] `hermes chat -q "Reply only: OK"` works
- [ ] Git is installed
- [ ] curl is installed
- [ ] This repository is reachable from the installation host
- [ ] Hermes home is writable

Run:

```bash
bash check-environment.sh
```

A **FAIL** blocks installation. A **WARN** is shown for conditions that should be reviewed but are not automatically destructive, such as a non-clean `hermes doctor` result.

## 2. Tenant / Business information

Have these ready:

- [ ] Tenant display name
- [ ] Tenant code
- [ ] Whether the tenant has multiple businesses/products
- [ ] Business display name/code if applicable
- [ ] Company/business website, optional
- [ ] User department/role, optional

Naming:

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

## 3. Messaging Platforms

v0.5 supports:

- LINE
- Telegram
- WeChat / Weixin

```text
LINE ---------┐
Telegram -----┼----> one Company AI Advisor Profile
Weixin -------┘
```

**One Agent Profile, Many Messaging Platforms, Many Sessions.**

The platforms share the same Agent Profile, SOUL, Skills, durable Memory, and available tools. Each chat still has its own session/context.

---

# Messaging Platform Requirements

## LINE

Prepare:

- LINE Developers account
- Messaging API Channel
- Long-lived Channel Access Token
- Channel Secret
- Allowed LINE user ID(s), or explicitly accept temporary allow-all
- A public HTTPS URL when you are ready to connect LINE

The public HTTPS URL is optional during initial installation. This allows a test customer without a domain to install first and create a temporary tunnel afterward.

### LINE port behavior

v0.5 does not blindly assume port `8646` is available.

For a **standalone/per-profile gateway**, the installer:

1. starts checking from Hermes' LINE base port `8646`
2. finds the first free TCP port
3. writes it as `LINE_PORT`
4. prints the selected port at the end of installation

Example on a busy Hermes host:

```text
8646 ... occupied
8647 ... occupied
...
8662 ... available

LINE local port: 8662
```

For a **multiplex secondary profile**, the First Agent does not bind its own LINE port. It uses the host gateway listener and the profile-scoped path:

```text
/p/<agent-id>/line/webhook
```

The installer detects the topology and prints the correct result.

### Testing LINE without a domain

For standalone mode, after installation you can use a Cloudflare Quick Tunnel, for example:

```bash
cloudflared tunnel --url http://localhost:<selected-line-port>
```

Then configure LINE Developers with the generated HTTPS hostname plus:

```text
/line/webhook
```

Quick Tunnel is for testing. Production should use a stable managed HTTPS endpoint.

## Telegram

Prepare:

- Telegram account
- Bot created through BotFather
- Telegram Bot Token
- Allowed Telegram numeric user ID(s), or explicit temporary allow-all

Hermes normally uses Telegram long polling, so no inbound listener port or public webhook URL is required.

## WeChat / Weixin

Prepare:

- WeChat mobile app
- phone available to scan the QR login

The installer uses Hermes native setup:

```bash
hermes -p <agent-id> gateway setup
```

Important:

- Hermes Weixin uses Tencent iLink bot identity
- Weixin is **not WeCom**
- DM/pairing is the primary supported usage pattern
- ordinary WeChat group behavior may be limited by the iLink platform
- prefer pairing or an allowlist rather than open access

Weixin normally uses long polling and does not require LINE-style port allocation.

> WeCom is not included in v0.5. If it is added later, callback-based standalone WeCom deployments will need the same class of port-collision handling as LINE.

---

# Gateway Topology

Hermes 0.21.x spans two operational patterns. v0.5 detects them conservatively rather than forcing a migration. On Hermes builds that support multiplexing, v0.5 uses the shared host topology only when the default profile explicitly enables multiplexing or a running host gateway already records served named profiles. Otherwise it uses Hermes standalone compatibility mode for the new First Agent.

## Standalone / per-profile

Typical older or existing multi-agent fleet:

```text
Agent A Profile ----> Agent A Gateway process
Agent B Profile ----> Agent B Gateway process
First Agent --------> First Agent Gateway process
```

The First Agent gets its own gateway. LINE needs its own free local port.

## Host multiplex

Newer topology:

```text
                 Host Gateway
                     │
        ┌────────────┼────────────┐
        ↓            ↓            ↓
     Profile A    Profile B    First Agent
```

The host gateway serves named profiles. Secondary profiles do not install their own gateway process and LINE uses the host listener with a profile-scoped path.

For LINE specifically, v0.5 verifies that the default profile already has a shared HTTP listener (`api_server` or `webhook`) configured. If no shared listener exists, the installer does **not** modify the default profile; it falls back to Hermes standalone compatibility mode for the First Agent and allocates a dedicated LINE port instead.

## Existing fleet safety

v0.5 does **not** automatically migrate an existing gateway fleet.

If the installed Hermes supports multiplexing but the machine already has named per-profile gateway processes/services, the installer uses the Hermes standalone compatibility path for the new First Agent. It also uses that conservative path when multiplex support exists but the host is not yet explicitly/observably multiplexing. This avoids changing the default profile or disrupting existing bots during First Agent installation.

---

# Installation

Clone the repository:

```bash
git clone https://github.com/cerjary/hermes-first-agent.git
cd hermes-first-agent
```

Run:

```bash
bash check-environment.sh
bash install.sh
```

## Install flow

```text
Environment Preflight
        ↓
Verify default LLM works
        ↓
Detect Gateway topology
        ↓
Tenant / Business input
        ↓
Messaging Platform selection
        ↓
Credential validation
        ↓
LINE port allocation when required
        ↓
Installation Plan
        ↓
User confirmation
        ↓
Create Hermes Profile
        ↓
Inherit default LLM model/provider safely
        ↓
Write SOUL / Skills / Memory / Platform config
        ↓
Write FIRST_AGENT.yaml
        ↓
Core installation committed
        ↓
Weixin QR setup, if selected
        ↓
Hermes doctor + First Agent LLM smoke test
        ↓
Install/start persistent Gateway service
        ↓
Verify Gateway is running
```

### Transaction behavior

A failure during **core profile creation/configuration** triggers rollback of the new profile.

A failure during **post-install verification** does **not** delete the profile. The installer keeps the profile and reports what must be fixed.

This is intentional: a transient `doctor` warning or a failed smoke test must not erase an already-created Agent or completed messaging setup.

### Reinstalling the same Agent ID

Hermes 0.21.x may retain an internal deletion marker after `profile delete`. If v0.5 detects that marker while the real profile no longer exists, it requires the explicit text:

```text
REINSTALL
```

before clearing that exact marker and reusing the Agent ID.

---

# What is installed

The Profile receives:

- `SOUL.md`
- `company-context`
- `prompt-advisor`
- `ai-work-advisor`
- `agent-planning-advisor`
- install-time inherited LLM model/provider configuration
- selected static LLM provider credentials from the default profile
- Tenant/Business seed memory
- selected messaging platform configuration
- platform credentials in the profile's private `.env`
- `FIRST_AGENT.yaml` lifecycle manifest

Example:

```yaml
source: cerjary/hermes-first-agent
version: 0.5.2
agent_id: acme-ai-advisor
display_name: ACME AI Advisor
tenant_code: acme
business_code: none
installed_at: 2026-09-24T08:00:00Z
gateway_topology: standalone
gateways:
  - telegram
```

The manifest is written with a YAML serializer rather than shell string interpolation, so special characters in display names do not corrupt the file.

No gateway secrets are stored in `FIRST_AGENT.yaml`.

---

# Starting / Operating the Gateway

The installer automatically reconciles the gateway after the Agent profile and LLM smoke test succeed. On supported Linux/macOS hosts, the normal result is a persistent background service that is started immediately; users do not need to run a separate gateway command.

A gateway setup/start failure is treated as a post-install warning. The Agent profile, credentials, and completed onboarding are kept so the gateway can be repaired without reinstalling the Agent.

## Standalone/per-profile

The installer uses the equivalent of:

```bash
hermes -p <agent-id> gateway install --start-now --start-on-login
```

For `standalone-compat`, the installer also uses Hermes' explicit force/compatibility path when required.

Check status:

```bash
hermes -p <agent-id> gateway status
```

For LINE the webhook path remains:

```text
/line/webhook
```

## Multiplex host gateway

The installer does **not** create a second named-profile gateway. If the host multiplexer is already running, it is left in place. If it is not running, the installer attempts to install/start the host gateway service.

Check status:

```bash
hermes gateway status
```

For secondary LINE profiles:

```text
/p/<agent-id>/line/webhook
```

This avoids duplicate Telegram pollers and LINE listener conflicts.


---

# Sessions and Memory

A LINE message and a Telegram message can reach the same First Agent Profile without becoming one continuous live conversation.

```text
Same Profile / SOUL / Skills / durable Memory    YES
Same conversation Session                         NO
```

Use durable Memory for organization context that should survive conversations. Use Sessions for the working context of a particular chat.

---

# Update

Run:

```bash
bash update.sh
```

The updater:

1. validates the Agent ID
2. validates `FIRST_AGENT.yaml` source and `agent_id`
3. pulls the latest First Agent repository with `git pull --ff-only`
4. runs the **new release's** environment preflight
5. runs `hermes profile update <agent-id> --yes`
6. safely updates the manifest version

Hermes distribution update preserves user-owned state such as `.env`, memories, sessions, credentials, and `config.yaml` by default.

That means:

- LLM inheritance happens at install time
- later changes to the default profile's model are **not** silently propagated
- future releases that require a config migration must implement that migration explicitly rather than assuming `profile update` replaces config

---

# Uninstall

Run:

```bash
bash uninstall.sh
```

The script:

- discovers installed profiles created by `cerjary/hermes-first-agent`
- lists only profiles whose `FIRST_AGENT.yaml` source and `agent_id` are valid
- lets the user select the First Agent by number; the user does not need to remember the Agent ID
- shows the selected display name, Agent ID, and installed version before deletion
- requires an explicit yes/no confirmation before permanent deletion
- does not list or delete the default profile or unrelated Hermes profiles

Optional profile exports are stored under:

```text
~/.hermes/backups/first-agent/
```

with restrictive permissions.

Hermes profile export excludes `.env` and `auth.json`, but the archive can contain memories, sessions, USER.md, and other sensitive business context. Treat it as sensitive data.

---

# Security Defaults

- The repository may be public, but it must never contain customer/runtime secrets.
- Do not commit `.env`, tokens, API keys, OAuth state, private keys, or profile exports.
- LINE and Telegram validation sends secrets to curl through stdin config so tokens are not placed in the normal process argument list.
- LLM inheritance copies only model/provider configuration and recognized LLM provider credential keys; it does not copy messaging credentials from the default profile.
- Prefer per-platform allowlists.
- Enabling temporary allow-all requires typing the exact phrase `ALLOW ALL`.
- Installer rollback is limited to the newly owned profile target.
- Uninstall validates both source identity and Agent ID.

## Tool least privilege

Hermes messaging platform presets can expose powerful tools, including terminal/file capabilities. The First Agent's SOUL limits its role behaviorally, but SOUL is not an operating-system sandbox.

Before customer deployment:

```bash
hermes -p <agent-id> tools
```

review the enabled tools/toolsets and remove capabilities the Company AI Advisor does not need. This is especially important if any platform is intentionally configured for broad access.

---

# Troubleshooting

## Environment check fails

```bash
bash check-environment.sh
```

Fix all **FAIL** items before retrying.

## Default Hermes works but First Agent LLM smoke test fails

The profile is intentionally kept.

Check:

```bash
hermes -p <agent-id> doctor
hermes -p <agent-id> chat -q "Reply only: OK"
```

Then inspect the named profile's model/provider configuration. Do not re-enter messaging credentials unless the platform check itself failed.

## LINE port conflict

In standalone mode, v0.5 finds a free port automatically. If a port becomes occupied after installation, update `LINE_PORT` in the profile `.env` and restart that profile's gateway.

In multiplex mode, secondary profiles do not own a LINE listener port; inspect the host gateway instead.

## LINE has no public URL yet

For standalone testing:

```bash
cloudflared tunnel --url http://localhost:<line-port>
```

Use the generated HTTPS hostname plus `/line/webhook` in LINE Developers.

## Weixin QR setup fails

The profile is kept. Retry:

```bash
hermes -p <agent-id> gateway setup
```

## Profile was previously deleted

Run `install.sh` again. If Hermes left a deletion marker, v0.5 will detect it and require explicit `REINSTALL` confirmation.

---

# Direct Hermes Distribution Install

The repository remains a valid Hermes Profile Distribution:

```bash
hermes profile install git@github.com:cerjary/hermes-first-agent.git --name acme-ai-advisor --alias
```

However, direct install bypasses First Agent-specific onboarding and lifecycle behavior, including:

- Tenant / Business seed context
- selective default-LLM inheritance
- messaging credential validation
- gateway topology detection
- LINE port allocation
- lifecycle manifest generation
- hardened verification/rollback behavior

For normal deployment, use:

```bash
bash install.sh
```

---

# Naming

Standard pattern:

```text
<tenant>[-<business>]-<domain>-<role>
```

See `NAMING.md`.

---

# Access Control

This repository is proprietary and intended only for users explicitly granted access by the repository owner. Do not redistribute, mirror, publish, or sublicense the installer or bundled Agent templates without written permission.
