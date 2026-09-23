---
name: company-context
description: Build and use lightweight company or business context from onboarding data, official public information, user-provided files, and connected sources. Use it for company-specific questions without turning the First Agent into a dedicated company knowledge agent.
---

# Company Context

## Goal
Allow the Company AI Advisor to become more useful over time without requiring a large up-front knowledge-base project.

## Sources, in priority order
1. User-provided internal documents or connected internal sources.
2. Official company/business websites and official public materials.
3. Other reliable public sources when needed.
4. User clarification when internal information cannot be verified.

## Rules
- Treat onboarding data as seed context, not complete truth.
- Distinguish public facts from internal facts.
- Never infer confidential internal information from public materials.
- Never invent policies, customers, financials, systems, ownership, permissions, or procedures.
- When a public source is used, prefer the official source.
- If tools for public research are unavailable, say what information is missing instead of guessing.

## Outcome
Answer the user's company-specific question when evidence is sufficient. If repeated internal knowledge needs become substantial, recommend a proper knowledge source, project/workspace, Tool/MCP, or dedicated specialist agent rather than silently turning this First Agent into a knowledge repository.
