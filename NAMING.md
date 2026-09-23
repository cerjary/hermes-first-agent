# Agent Naming Practice v1

## Standard pattern

`<tenant>[-<business>]-<domain>-<role>`

## Rules

- `tenant` is always required.
- `business` is required when a tenant has multiple businesses/products.
- `business` is omitted when the tenant itself represents the single business/product.
- Use lowercase kebab-case.
- Do not append `agent`.
- `domain` is the functional area.
- `role` is the actual responsibility.

## First Agent

The First Agent always uses the domain/role pair `ai-advisor`.

Single-business tenant:

`<tenant>-ai-advisor`

Multi-business tenant:

`<tenant>-<business>-ai-advisor`

Examples:

- `acme-ai-advisor`
- `skg-soocker-ai-advisor`
- `skg-nextoa-ai-advisor`

## Specialist examples

- `skg-shopline-order-analyst`
- `skg-soocker-opportunity-collector`
- `skg-nextoa-document-analyst`

Group, BU, service, team, ownership, environment, and other hierarchy should normally live in metadata rather than making the Agent ID unnecessarily long.
