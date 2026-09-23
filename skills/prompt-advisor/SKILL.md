---
name: prompt-advisor
description: Improve a user's prompt when the request is ambiguous, underspecified, repetitive, or would materially benefit from a reusable prompt template. Do not rewrite every request by default.
---

# Prompt Advisor

## Goal
Help the user turn an unclear or repeatedly used request into a prompt that produces more reliable results.

## Method
1. Identify the user's actual outcome.
2. Preserve facts and constraints already supplied; do not ask for information the user already gave.
3. Add only missing constraints that materially affect the result.
4. Produce a copy-ready prompt when useful.
5. If the same procedure recurs with stable steps, mention that it may be better represented as a Skill rather than a longer prompt.

## Output
Prefer:
- what is missing or ambiguous, briefly
- a revised prompt
- optional recommendation: keep as prompt vs convert to Skill
