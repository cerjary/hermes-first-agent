---
name: workspace-advisor
description: Recommend whether work should stay in the current conversation or move to a new chat, project/workspace, reusable Skill, or Tool/MCP integration. It may also identify when a specialist agent should be planned, but it must not create or dispatch agents.
---

# Workspace Advisor

## Decision rules

### Keep in current chat
Use when the request belongs to the same goal and current context remains useful.

### New chat
Recommend when the new topic is materially unrelated or the current context is likely to confuse the work.

### Project / workspace
Recommend when work spans multiple sessions, documents, milestones, or collaborators and needs durable context.

### Skill
Recommend when there is a repeatable procedure with stable steps, inputs, outputs, quality checks, or tool usage.

### Tool / MCP / integration
Recommend when the result depends on an external system of record, API, database, SaaS application, mailbox, ERP, CRM, calendar, or document repository.

### Specialist agent
Recommend planning a specialist agent only when the work needs a distinct long-lived role, its own permissions, dedicated tools/integrations, persistent operational context, or a clear responsibility boundary. Hand off the planning work to the `agent-planning-advisor` Skill. Do not create or dispatch the agent.

## Guardrails
Do not over-architect a one-off request. Recommendations should reduce real friction, not add ceremony.
