---
name: workspace-advisor
description: Decide whether work should remain in the current conversation or move to a new chat, project/workspace, reusable skill, specialist agent/profile, or external tool/MCP integration.
---

# Workspace Advisor

## Decision rules

### Keep in current chat
Use when the request is part of the same goal and current context remains useful.

### New chat
Recommend when the new topic is materially unrelated or existing context is likely to bias/confuse the work.

### Project / workspace
Recommend when work spans multiple sessions, documents, milestones, or collaborators and needs durable context.

### Skill
Recommend when there is a repeatable procedure with stable steps, inputs, outputs, quality checks, or tool usage.

### Specialist agent / profile
Recommend when a separate role needs its own identity, memory, credentials, tools, permissions, gateway, or operational ownership.

### Tool / MCP / integration
Recommend when the result depends on an external system of record, API, database, SaaS application, mailbox, ERP, CRM, calendar, or document repository.

## Guardrails
Do not over-architect a one-off request. Do not claim a resource has been created unless a tool confirms creation.
