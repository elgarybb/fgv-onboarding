# FGV Restaurantes

Existing restaurant workspace: Supabase authentication, guided onboarding, protected reservation engine and a visual floor plan. Static HTML/CSS/JavaScript deployed through GitHub Pages.

## Current release

- Shared desktop/mobile navigation and design primitives.
- Daily bookings summary, reservation search and customer history.
- Room layout with mouse/keyboard controls, touch pointer support and versioned autosave.
- Restaurant profile editing and compatible rule changes that preserve accepted reservations.
- Onboarding writes operational booking settings; actual table capacities must still be supplied.
- Server-controlled feature catalogue, with pilot access and unassigned commercial plan definitions. No pricing or billing is enabled.

## Source map

`index.html`: onboarding. `login.html`, `register.html`, `reset-password.html`: Supabase Auth.
`dashboard.html`: workspace shell. `workspace.js`: shared helpers, summary and customers.
`reservations.js`: reservation operations. `configuration.js`: restaurant profile.
`floor-plan.js`: visual room editor. `design-system.css`: shared visual primitives.

## Database changes

Migrations 001 and 002 were applied together on 2026-09-07. Migration 003 and migrations 004–005 were applied together on 2026-09-08. Never replay historical releases against that production database. Existing table identifiers and bookings are preserved.

Public pages use a publishable Supabase key. Server secrets must never be embedded in these files. Access is enforced by database policies and authorized functions; integration credentials remain server-side.

## Verification and limits

31 integration scenarios passed locally against PostgreSQL via PGlite for the 2026-09-08 release. Browser verification uses isolated fictional fixtures before checking the published app. Current workspace documentation records the exact production checks.

WhatsApp, n8n production hosting, live calls, external booking providers, payments and installable PWA are not activated in this release. External booking mode explicitly reports the missing connection. The room map represents layout, not live attendance or physical occupancy. One table is assigned per reservation.
