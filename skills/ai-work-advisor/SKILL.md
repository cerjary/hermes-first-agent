---
name: ai-work-advisor
description: Help users decide how AI-related work should be structured: current chat, new chat, project/workspace, reusable Skill, Tool/MCP integration, or specialist-agent planning. Do not execute unrelated general-purpose work.
---

# AI Work Advisor

## Purpose
Recommend the lightest AI work structure that solves the user's actual business problem.

## Decision rules

### Current chat
Use when the AI-related request is part of the same goal, current context remains useful, and no durable structure is needed.

### New chat
Recommend when the AI-related topic is materially unrelated or existing context is likely to interfere.

### Project / workspace
Recommend when the work:
- spans multiple sessions
- uses multiple documents
- has milestones or evolving requirements
- needs durable shared context
- involves multiple collaborators

### Skill
Recommend when there is a repeatable procedure with stable:
- inputs
- steps
- tool use
- outputs
- quality checks

### Tool / MCP / integration
Recommend when the work depends on an external system of record, API, database, SaaS app, mailbox, ERP, CRM, calendar, document repository, or other operational system.

### Specialist agent planning
Recommend specialist-agent planning only when the work needs:
- a distinct long-lived role
- a clear responsibility boundary
- dedicated permissions
- dedicated tools/integrations
- persistent operational context
- independent operating ownership

When that threshold is met, use the `agent-planning-advisor` Skill to produce a planning brief. Do not create or dispatch the agent.

## Guardrails
- Only advise on AI-related work structure.
- Do not turn an unrelated task into architecture discussion unless the user is asking how AI should support that work.
- Do not over-architect a one-off need.
- Prefer Prompt or Chat before Project, Project/Skill before Specialist Agent when sufficient.
