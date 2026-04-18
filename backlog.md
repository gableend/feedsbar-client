# FeedsBar — Functionality Backlog

Running list of candidate features, ordered loosely by priority. Each entry
has a one-line value statement, effort estimate, and a rough sketch of what
needs to change — enough to pick one off the top when you have a working
block and land it without re-deriving the design.

Priority items are flagged **P1** and sit above the Later section.

---

## P1 — committed (next functional pass)

These five raise the product's ceiling as a thing you can leave on all day
without losing the calm-ambient identity. Small, independent, buildable in
~2h each.

### 1. Mark-as-read across sessions
**Value:** ticker never repeats yesterday's stories; freshness without churn.
**Effort:** ~2h, client-only.
**How:**
- Add a `readItemIDs: Set<String>` on `FeedStore`, persisted to UserDefaults
  under `feedstore.readItemIDs.v1` (CSV-encoded for simplicity, bounded to
  ~2k most-recent ids to cap plist size).
- Mark read when a user clicks a ticker row / orb phrase. Expose
  `markRead(_:)` on the store.
- Filter inside `refreshItemsOnly` / `refreshAll` after server response:
  `items = items.filter { !readItemIDs.contains($0.stableId) }`.
- TTL cleanup on app boot: drop ids older than 30 days by diffing against
  `publishedAt`.
- Settings toggle: "Hide already-read items" (default on).
- No server changes.

### 2. Keyword mute + keyword follow
**Value:** strip crypto / specific teams / a politician's name from the
signal layer without nuking whole feeds.
**Effort:** ~2h, client-only.
**How:**
- Two `@AppStorage` CSV strings: `keywordMutes`, `keywordFollows`.
- Preferences tab: two text fields (tag-style entry or comma-separated).
- Apply in the same post-filter pass as mark-as-read:
  - mute: drop items whose `displayTitle.lowercased()` contains any muted term.
  - follow: tag matching items so the ticker can style them (subtle accent
    color or bold) without filtering anything out.
- Case-insensitive, whole-word-ish via `.contains(" \(term) ")` with
  leading/trailing space padding on the haystack to avoid partial matches
  without regex overhead.

### 3. Focus mode — click an orb pins ticker to that topic
**Value:** natural curiosity path. "What's driving HORMUZ CRISIS EMERGES?"
**Effort:** ~3h, client-only (we already have `top_items` per orb).
**How:**
- Click on the orb circle itself (not the phrase — that still opens the
  article) → sets `store.focusedTopicID: String?` with a 5-minute timer.
- While set, ticker filters items to those whose `source.category.slug`
  matches the topic's feed categories (mapping already exists via
  `topic_categories` on the server; manifest doesn't currently expose it
  so we use the topic's `top_items` array directly for now — it's 5-10
  items and refreshes every tick).
- Auto-clear after timer expires OR on any feed toggle / bundle activate.
- Visual: dim the non-focused orbs to 30%, keep the focused one bright
  with a "pinned · 4m remaining" badge next to its phrases.
- Clicking the same orb again exits focus mode.

### 4. Velocity-driven orb glow
**Value:** the most on-brand signal cue — "something is moving here"
without sound, badge, or alert. Uses data we already compute.
**Effort:** ~1h server (expose `velocity_per_hour` on the orbs endpoint,
it's already computed and stored), ~1h client (map magnitude → glow).
**How:**
- Server: `rpc_orbs_v1` already has `velocity` in its jsonb shape but the
  worker sets both `per_hour` and `ui` to null. Thread
  `os.velocity` / `os.velocity_per_hour` through (the `orb_snapshots`
  table stores `velocity` — the capped UI value).
- Edge API: already passes through the velocity object, no change.
- Client: `Orb.velocity: Double?` decoded; in `SignalRotationOrb`'s glow
  dot, modulate opacity + blur radius by `min(abs(velocity) / 1.0, 1.0)`
  so idle topics sit quiet and hot topics pulse gently.
- No timer-based animation — the pulse comes naturally from orb rotation
  every 10s. Keep it calm.

### 5. Per-feed frequency cap in the ticker
**Value:** prevents a chatty feed (Reddit bursts, ESPN game day) from
dominating. Fair attention allocation without user configuration.
**Effort:** ~1h server-only.
**How:**
- In `rpc_items_batch_v1`, after the LATERAL per-feed top-N, apply a
  rolling-hour fairness filter: for each feed, keep at most N items from
  the last 60 minutes in the returned set. Suggested N=3.
- Parameterise as `p_max_per_feed_per_hour` with a sensible default so
  the knob exists if we ever want to tune.
- Client requires no change.

---

## Later — worth building, not yet prioritised

### 6. Keyboard shortcuts on the ticker
Space = pause, ← → = cycle orbs, ⌘↩ = open currently-visible item.
Accessory-app niceties. ~2h client.

### 7. Right-click on a ticker item → Copy Link / Open / Share
Removes "did you see this?" friction. `.contextMenu` on `TickerRow`,
reuses existing sharing infrastructure (NSSharingServicePicker).

### 8. Reading-time estimate per item
Small grey monospace "2 MIN" next to source label. Server estimates from
content length at ingest (word-count / 220 wpm), stores in `items.extra`
jsonb. Nudges weight without demanding. Ingest + DB change + client
rendering.

### 9. Natural-language search across last 30 days
"Show me things about Iran" / "AI regulation". Reuses existing OpenAI
infra. Needs a new endpoint + search UI. Candidate for a "search" tab.

### 10. Cloud sync of feed selection + mute lists
Keyed by the license key once Phase 4 lands. Stores disabledIDs +
keyword lists server-side so a second Mac sees the same signal layer.
Adds real server state we don't currently carry — non-trivial.

### 11. Weekly digest email
Opt-in. Uses Buttondown (already wired). Summarises top orbs per day of
the week. Extends the product into the inbox for a calmer mode where
even opening the app feels like work.

---

## Parked / explicitly not doing

- **Notification badges** or red dots — violates calm ethos.
- **Sound alerts** on breaking news — same.
- **Mobile / iPad companion** — scope creep; focus on being the best
  ambient Mac ticker.
- **Comments / social features** — out of character for the product.
- **Dark mode toggle** — the ticker is black on purpose.
