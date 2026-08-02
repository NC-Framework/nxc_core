# Platform — nxc_core

**Target:** FiveM for GTA V Enhanced, Enhanced Cfx Server runtime.

Required by Master Design Document v0.4 section 38.3 and
[`PLATFORM_STANDARDS.md`](https://github.com/NC-Framework/nxc-core-governance/blob/main/standards/PLATFORM_STANDARDS.md).
All eight items are answered. **`None` is written where it applies** — an empty section is a claim that
someone looked and found nothing, and an absent section is not.

`nxc_core` is the framework spine: bootstrap validation, identifiers, service discovery, sessions, capabilities, state bag policy, connection lifecycle, routing buckets, persistence, migrations, and configuration.

---

### 1. Enhanced natives and platform APIs used

Confined to four server files. Everything in `shared/` remains pure Lua and runs under `wasmoon`, which is what keeps 128 tests platform-independent.

| Where | Uses |
| --- | --- |
| `server/startup.lua` | `IsDuplicityVersion`, `CreateThread`, `Wait`, `GetConvar`, `RegisterCommand`, `TriggerEvent` |
| `server/connection.lua` | `AddEventHandler` for `playerConnecting`, `playerJoining`, `playerDropped`; the `deferrals` object (`defer`, `update`, `done`); `GetNumPlayerIdentifiers`, `GetPlayerIdentifier`, `Player(source).state`, `DropPlayer` |
| `server/migrator.lua` | `GetNumResourceMetadata`, `GetResourceMetadata`, `LoadResourceFile` |
| `server/mariadb_provider.lua` | `exports.oxmysql` |

**Deferrals carry the one timing requirement.** The platform needs a tick between `defer()` and any later deferral call, so there is an explicit `Wait(0)`. Without it the handshake fails in a way that looks like a network problem.

**State bags are written in exactly one place**, `playerJoining`, carrying the session id and stage — not the account id, and no platform identifier. Every bag is client-visible.

### 2. Deprecated or compatibility-only natives used

**None.**

Specifically no Mumble voice natives: this resource does no voice, and `nxc_voice` targets the Enhanced server-side API rather than the deprecated client-side one (ADR-0017).

### 3. Game assets, archetypes, metadata, or data files required

**None.** Locale files only, which are resource data rather than game assets.

### 4. Voice, networking, state bag, entity, and routing bucket assumptions

**State bags:** `statebags.lua` defines the policy — every bag is client-visible, so registration refuses keys naming money, items, capabilities, or tokens. It defines the policy; it does not set bags.

**Routing buckets:** `buckets.lua` owns allocation for the whole framework. Bucket 0 is the shared world, 1 through 999 are reserved, and 1000 through 99999 are allocated dynamically. Resources request a bucket and are given an id; they never pick one. These ranges are a framework convention, not a platform limit.

**Networking:** `lifecycle.lua` is a stage machine over connection states and assumes nothing about the transport. The deferral and handshake layer in front of it now exists, in `server/connection.lua`, written against the Enhanced flow: `defer`, a tick, `update`, then `done` with either success or a reason the player can act on (R-1620).

**Correlation:** an id is issued at the first `playerConnecting` event and carried into the session, so one connection is one traceable story from handshake to disconnect (R-1621).

**Unverified beyond a single connection.** Queueing, deferral timeouts, and interrupted handshakes are PT-10 and have not been tested.

**Voice:** no involvement. Voice is `nxc_voice`, which does not exist yet.

### 5. Known Enhanced platform limitations

**None found, and the search has barely started.**

As of 2026-08-02 the resource loads, validates its environment, reaches MariaDB, applies its migrations, and registers itself on an Enhanced Cfx Server at build `b106-ea`. That is the startup path and nothing more.

**Not exercised:** more than one concurrent connection, routing bucket transitions, resource restart with players connected, reconnect recovery, or anything under load. The unit tests say the logic is correct; they say nothing about the platform.

One platform behaviour shaped the code and is worth recording: **a resource that throws inside a shared script still reports as `Started`**. There is no error state observable from outside, which is why startup keeps an explicit readiness flag and an `nxc_status` command rather than treating an absence of errors as evidence.

### 6. Minimum supported Cfx Server build

**Not pinned.** No build has been named — OD-020, blocker B-11. The manifest declares `UNPINNED`, which
fails `check-manifests.mjs` deliberately rather than passing with a plausible-looking number.

**The deployed build is recorded even though the minimum is not pinned.** `nxc_server_build` is a
required bootstrap value: the server refuses to start until the operator records the exact Cfx Server
build it runs (MDD v0.4 38.2). These are different things — a minimum is a compatibility claim, and a
recorded build is a fact about one deployment. The second is available now; the first needs a decision.

Bootstrap does **not** check whether the recorded build is an Enhanced build. A build number does not
carry its edition, and inventing a range to test against would be a fabricated fact that fails closed on
correct input. Proving the server is Enhanced is gate check P1-E02, on real hardware.

### 7. Asset conversion or validation requirements

**None.**

### 8. Optional Legacy compatibility layer

**None.**
