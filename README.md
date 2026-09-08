# FGV Restaurantes

Existing restaurant workspace: Supabase authentication, guided onboarding, protected reservation engine and a visual floor plan. Static HTML/CSS/JavaScript deployed through GitHub Pages.

## Current release

- Shared desktop/mobile navigation, onboarding and authentication design, with remembered light/dark appearance and an illustrative three-scene demo.
- Daily bookings summary, reservation search and customer history.
- Multiple rooms, table placement, movable walls/bar/text and versioned autosave. Explicit combinations preserve physical table allocations.
- Restaurant profile editing and compatible rule changes that preserve accepted reservations.
- Onboarding writes operational booking settings; actual table capacities must still be supplied.
- Server-controlled feature catalogue, with pilot access and unassigned commercial plan definitions. No pricing or billing is enabled.

## Source map

`index.html`: onboarding. `login.html`, `register.html`, `reset-password.html`: Supabase Auth.
`dashboard.html`: workspace shell. `workspace.js`: shared helpers, summary and customers.
`reservations.js`: reservation operations. `configuration.js`: restaurant profile.
`floor-plan.js`: visual room editor. `design-system.css`: shared visual primitives.

## Database changes

Migrations 001 and 002 were applied together on 2026-09-07. Migrations 003–005 were applied together on 2026-09-08; migration 006 followed to synchronize the legacy onboarding city with profile edits. Migrations 007–010 were applied later on September 8 for rooms, architecture, combined tables and channel setup. Never replay historical releases against that production database. Existing table identifiers and bookings are preserved.

Public pages use a publishable Supabase key. Server secrets must never be embedded in these files. Access is enforced by database policies and authorized functions; integration credentials remain server-side.

## Verification and limits

49 integration scenarios passed locally against PostgreSQL via PGlite for the 2026-09-08 release. Browser verification uses isolated fictional fixtures before checking the published app. Current workspace documentation records the exact production checks.

WhatsApp, n8n production hosting, live calls, external booking providers, payments and installable PWA are not activated in this release. External booking mode explicitly reports the missing connection. The room map represents layout, not live attendance or physical occupancy. Explicit table combinations allocate and block every member table for the booking interval.

## Commercial preparation

Básico, Pro and Business are draft feature definitions with server checks for room editing, combinations and channel requests. Guided setup stores a phone number as pending authorization; it does not connect Meta or a telephony provider. Prices, quotas, payment, provider authorization, the conversational agent, advanced operations monitoring, and an operational multi-location interface remain pending. Existing combinations remain available to the engine after a plan downgrade; removing or changing them requires the entitlement, so downgrades need an explicit configuration review before commercial use.

## Administration update

Migration 011 adds a superadmin-only directory, private commercial accounts, revision checks, audit history and retry-safe sales onboarding. Dedicated navigation provides overview, restaurants, commercial clients, setup operations and plan counts. Sales status does not alter booking operations or charge customers. Creating a restaurant grants access only to its creator; contact email is informational and client account linking remains a separate pending step. Operational alerts reflect configuration, not live provider telemetry.
