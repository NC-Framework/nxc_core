# Platform — nxc_core

**Target:** FiveM for GTA V Enhanced, Enhanced Cfx Server runtime.

Required by Master Design Document v0.4 section 38.3 and
[`PLATFORM_STANDARDS.md`](https://github.com/NC-Framework/nxc-core-governance/blob/main/standards/PLATFORM_STANDARDS.md).
All eight items are answered. **`None` is written where it applies** — an empty section is a claim that
someone looked and found nothing, and an absent section is not.

`nxc_core` is the framework spine: bootstrap validation, identifiers, service discovery, sessions, capabilities, state bag policy, connection lifecycle, routing buckets, persistence, migrations, and configuration.

---

### 1. Enhanced natives and platform APIs used

**One, and it is a guard rather than a behaviour.** `server/10_mariadb_provider.lua` calls `IsDuplicityVersion()` to refuse to load client-side, and speaks to `oxmysql` through exports. Everything in `shared/` is pure Lua and runs under `wasmoon`.

The database provider is deliberately thin for this reason: it cannot be unit tested, because `oxmysql` exists only in the server runtime, so everything with logic in it stays where it can be.

### 2. Deprecated or compatibility-only natives used

**None.**

### 3. Game assets, archetypes, metadata, or data files required

**None.** Locale files only, which are resource data rather than game assets.

### 4. Voice, networking, state bag, entity, and routing bucket assumptions

**State bags:** `15_statebags.lua` defines the policy — every bag is client-visible, so registration refuses keys naming money, items, capabilities, or tokens. It defines the policy; it does not set bags.

**Routing buckets:** `17_buckets.lua` owns allocation for the whole framework. Bucket 0 is the shared world, 1 through 999 are reserved, and 1000 through 99999 are allocated dynamically. Resources request a bucket and are given an id; they never pick one. These ranges are a framework convention, not a platform limit.

**Networking:** `16_lifecycle.lua` is a stage machine over connection states. It assumes a player connects, may be queued, selects a character, loads, plays, and disconnects. **It assumes nothing about the transport**, which is fortunate rather than foresighted — the deferral and handshake layer in front of it does not exist yet and must be written against Enhanced (R-1620).

**Voice:** no involvement. Voice is `nxc_voice`, which does not exist yet.

### 5. Known Enhanced platform limitations

**Unknown, and not yet testable.** Nothing in this resource has been exercised on an Enhanced server, because the development server runs Legacy artifacts (B-10). The unit tests say the logic is correct; they say nothing about the platform, and are not offered as evidence that they do.

### 6. Minimum supported Cfx Server build

**Not pinned.** No build has been named — OD-020, blocker B-11. The manifest declares `UNPINNED`, which
fails `check-manifests.mjs` deliberately rather than passing with a plausible-looking number.

### 7. Asset conversion or validation requirements

**None.**

### 8. Optional Legacy compatibility layer

**None.**
