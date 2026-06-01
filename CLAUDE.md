# FeedsBar — macOS client — project instructions

Repo: `gableend/feedsbar-client` ("Feedsbar Mac OS Client (thin)") · feeds.bar · Market Moat Labs (B2C)

> FeedsBar product = B2C real-time market signal layer. Multi-repo:
> **`feedsbar-client` (this — macOS app)** · `feedbar-edge-api` (Netlify API) · `feedbar-workers` (GCloud backend) · `FeedsBarWebsite` (site).

## What this is
The macOS client for FeedsBar — intentionally **thin**: rendering and interaction, with signal
data coming from the backend (`feedbar-workers` / `feedbar-edge-api`), not computed locally.

## Stack
Swift (~91%) + Shell. Xcode project under `FeedsBarClient/`. Helper scripts in `scripts/`.
Working backlog in `backlog.md`.

## Conventions for Claude
- Keep it **thin** — business logic and signal computation belong server-side, not in the client.
- Consume the edge/worker API contracts; if a response shape changes, update against the API
  repos rather than hardcoding.
- Build/test via Xcode (`xcodebuild`) / Swift Package tooling.
- `backlog.md` is the working task list — check it before starting feature work.

## Project memory
Append-only, dated. Stays with this repo.

### 2026-06-01
- CLAUDE.md seeded via Claude HQ setup. No README existed; details inferred from repo structure —
  verify and expand (esp. the client↔API contract and build steps).
