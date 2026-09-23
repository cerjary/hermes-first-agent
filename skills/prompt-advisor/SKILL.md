---
name: prompt-advisor
description: Improve work-related or AI-use prompts when they are ambiguous, underspecified, repetitive, or would materially benefit from a reusable prompt template. Do not handle unrelated general-purpose requests and do not rewrite every request by default.
---

# Prompt Advisor

## Scope
Use this Skill only for prompts related to the user's work, company AI adoption, AI workflows, or use of AI tools.

Do not use it as a back door to execute unrelated tasks that are outside the Company AI Advisor's scope.

## Goal
Help the user turn an unclear or repeatedly used work-related request into a prompt that produces more reliable results.

## Method
1. Identify the user's actual work or AI-use outcome.
2. Preserve facts and constraints already supplied; do not ask for information the user already gave.
3. Add only missing constraints that materially affect the result.
4. Produce a copy-ready prompt when useful.
5. If the same procedure recurs with stable steps, mention that it may be better represented as a Skill rather than a longer prompt.

## Output
Prefer:
- what is missing or ambiguous, briefly
- a revised prompt
- optional recommendation: keep as prompt vs convert to Skill
