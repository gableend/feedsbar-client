# FeedsBar — machine portability checklist

Written 2026-07-08, before sending the old MacBook Pro (2018, A1990) for battery service.
Covers standing the full FeedsBar multi-repo project up on a fresh Mac with Xcode.

## Status when this was written

All four repos were **clean and fully pushed** to GitHub (`gableend/*`) — no uncommitted work,
no unpushed commits. The macOS client is a plain Xcode project with **zero Swift Package
dependencies** (self-contained). The only code-signing identity on the old machine was a
regenerable "Apple Development" cert — nothing irreplaceable to back up.

| Repo | Role | Deps |
|---|---|---|
| `feedsbar-client` | macOS app (Swift/Xcode) | none (self-contained) |
| `feedbar-edge-api` | Netlify API | npm |
| `feedbar-workers` | GCloud backend | npm |
| `FeedsBarWebsite` | Marketing site | Bun |

## Setup on the new machine

### 1. GitHub access (do this first — gates everything)
Remotes are SSH (`git@github.com:`). Generate an SSH key on the new Mac and add it to GitHub, then:
```bash
mkdir -p ~/ClaudeHQ/dev/mml/feedsbar && cd $_
for r in feedsbar-client feedbar-edge-api feedbar-workers FeedsBarWebsite; do
  git clone git@github.com:gableend/$r.git
done
```

### 2. Xcode (for the client)
- Requires **macOS 14+** (client targets macOS 14.0).
- Sign in with your Apple ID → Xcode auto-generates a fresh Apple Development cert, so
  **Automatic**-signing targets build immediately.
- ⚠️ The project references two teams (`4GQV963UQ3`, `HKFGXYWVCQ`) and one target uses **Manual**
  signing. Make sure the Apple ID is a member of the right team, or switch that target to
  Automatic + your personal team for local dev.
- Bundle id: `com.graemechard.FeedsBarClient`.

### 3. Toolchains + dependencies
```bash
cd feedbar-edge-api && npm install && cd ..
cd feedbar-workers  && npm install && cd ..
# install Bun first (https://bun.sh), then:
cd FeedsBarWebsite  && bun install && cd ..
```

### 4. Local secrets (git-ignored — won't come down with the clone)
- `FeedsBarWebsite/.env` → `VITE_BUTTONDOWN_API_KEY` — value lives in the **Netlify dashboard**
  (site → environment variables). Only secret needed to run the site locally.
- Backend secrets (Netlify / GCloud) live in their dashboards — only needed to run/deploy the
  backends locally, not to build the app.

## Nothing to rescue from the old machine
Code is all on GitHub; the only Keychain cert was a regenerable dev cert. Safe to wipe/service.
