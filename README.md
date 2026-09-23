# Hermes First Agent

Private starter distribution for creating a company's first Hermes agent with LINE connectivity and a lightweight AI-advisor role.

## What it creates

- One isolated Hermes profile per company
- LINE Messaging API enabled
- Secrets stored only in the installed profile's `.env`
- Company/user seed context stored in Hermes memory
- Generic `SOUL.md` for professional answers and AI adoption guidance
- `prompt-advisor` skill
- `workspace-advisor` skill for deciding between current chat, new chat, project/workspace, skill, specialist agent, or Tool/MCP

## Prerequisite

Hermes Agent must already be installed and configured with an LLM provider.

Official Hermes currently supports LINE as a bundled platform and profiles as installable git distributions.

## Private GitHub installation

Recommended: keep this repository **Private** and grant read access only to approved GitHub users.

### Option A — SSH

First verify the user can clone the private repository with their SSH key, then:

```bash
git clone git@github.com:cerjary/hermes-first-agent.git
cd hermes-first-agent
bash install.sh
```

### Option B — GitHub CLI

```bash
gh auth login
gh repo clone cerjary/hermes-first-agent
cd hermes-first-agent
bash install.sh
```

The installer asks for:

1. Company name
2. Company website (optional)
3. Department / role (optional)
4. Company ID / profile name
5. Agent display name
6. LINE Channel Access Token
7. LINE Channel Secret
8. LINE allowed user IDs (recommended)
9. Public HTTPS URL (optional during initial setup)

LINE secrets are written to:

```text
~/.hermes/profiles/<profile>/.env
```

with file mode `600`. They are never stored in this repository.

## Direct Hermes distribution install

The repo is also a valid Hermes Profile Distribution:

```bash
hermes profile install git@github.com:cerjary/hermes-first-agent.git --name company-xx-agent --alias
```

For the company-specific onboarding flow and LINE credential prompts, use `bash install.sh` rather than the raw distribution install.

## LINE webhook

Hermes LINE's default webhook listener is port `8646` and the webhook path is:

```text
/line/webhook
```

For production, expose the gateway using a fixed HTTPS hostname (for example a named Cloudflare Tunnel or reverse proxy), then set this in LINE Developers Console:

```text
https://YOUR-HOST/line/webhook
```

## Security model

- Keep the GitHub repository private.
- Give only approved users read access.
- Prefer SSH keys or GitHub CLI authentication; do not embed GitHub PATs in install commands or scripts.
- Never commit `.env`, LINE tokens, provider API keys, OAuth files, or `auth.json`.
- Prefer `LINE_ALLOWED_USERS`; use `LINE_ALLOW_ALL_USERS=true` only temporarily during setup.
- Each customer/agent uses its own Hermes profile.

## Updating

Distribution-owned files can be refreshed with:

```bash
hermes profile update <profile-name>
```

Hermes keeps user-owned state such as `.env`, memories, sessions, and credentials separate from the distribution update.

## Version

`0.1.0` — starter MVP.

## Access control

This repository is proprietary and intended only for users explicitly granted access by the repository owner. Do not redistribute, mirror, publish, or sublicense the installer or bundled agent templates without written permission.

For customer installation, grant the customer's GitHub account **Read** access to this private repository. The customer can then authenticate with SSH or `gh auth login`, clone the repo, and run the installer. Removing repository access prevents future clones and profile updates from this source, but it does not remotely delete files already installed on the customer's machine.
