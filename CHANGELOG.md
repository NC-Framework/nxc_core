# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

## 0.3.0 - 2026-08-03

Contract version 2.

### Added

- An export surface. **nxc_core had none.** It owned sessions, accounts,
  characters, capabilities and identity, and exported not one of them, so no
  other resource could ask it anything at all. Every resource has its own Lua
  state, so `NxcCore.Sessions` is unreachable from outside however public it
  looks.

  Found while writing nxc_target, whose server-side authority check needs to ask
  "does this player hold this capability" and had nowhere to ask.

  `isReady`, `session`, `accountFor`, `characterFor`, `hasCapability`, and
  `capabilities`. Every one takes a connection and resolves from the server's own
  state; none accepts an account id, character id, or capability list from the
  caller.

- `session.capabilityGrants`, and `Sessions.setCapabilityGrants`. Capabilities
  were a pure module with nothing to apply them to: no session carried grants.

  **Nothing populates them yet** — employment, ranks, and organisation membership
  are later phases. The field exists so the shape is settled and a consumer
  asking about a capability gets a definite `false` rather than an error. That
  fails closed, which is the right direction: a gate refusing everything is
  visible immediately, one permitting everything is not visible at all.

## 0.2.2 - 2026-08-03

### Fixed

- `Identifiers` seeded its random source from `os.time`, which does not exist on
  the FiveM client. Same defect as nxc_lib's, in a second place, found by
  auditing for the pattern rather than by waiting for it to crash.

### Changed

- Requires nxc_lib v0.4.0.

## 0.2.1 — 2026-08-03

### Fixed

- `NxcCore.VERSION` is read from the manifest. It was stated twice and drifted:
  the manifest said 0.2.0 while the startup banner and every log line said
  0.1.0.

- The configuration registration diagnostic names what actually arrived instead
  of `reason=unknown`. An unexpected shape is the one case where the shape is
  the information, and the old message discarded it — on a real server it
  produced two log lines a tick apart, nxc_config reporting success and nxc_core
  reporting refusal, with neither saying why.

### Changed

- Requires nxc_lib contract 3, for `Nxc.plain`.

## Unreleased

Initial foundation: startup lifecycle, identity, sessions, service discovery, and
capability resolution.

### Fixed

- **`nxc_core` had no entry point.** It loaded twenty-eight modules of tested logic and
  ran none of it: bootstrap validation never executed, the persistence provider was never
  installed, and migrations never applied. The resource reported `Started` and did nothing,
  which is the failure mode hardest to notice because there is no error to read.


- **`nxc_core` could not start on a server.** It referenced `Nxc`, `nxc_lib`'s global,
  without loading `nxc_lib` into its own Lua state. Every FiveM resource has its own state,
  so declaring `nxc_lib` as a dependency ordered startup and shared no code at all. The
  resource deployed, reported as started, and died on the first line touching `Nxc`. The
  manifest now loads all fifteen `nxc_lib` modules through `@nxc_lib/shared/...`.

### Added

- A server entry point: validate the environment, reach the database, apply migrations,
  register the service, then open for connections. A failure at any step stops the
  framework with an explanation rather than degrading into a server that looks healthy and
  fails on the first player action.
- Connection lifecycle wired to the Enhanced deferral flow — identifiers resolved to an
  account, ban and whitelist evaluated, session created on join, cleanup driven from the
  drop event because a crashed client never runs a clean exit path.
- `nxc_core_accounts` find-or-create, made safe under concurrency by the unique constraint
  on (kind, value) rather than by an application check with a race in it.
- Platform identifier parsing, with `ip` deliberately excluded: an address is shared by a
  household and reassigned by a provider, so treating one as identity both merges strangers
  and separates the same person.
- An `nxc_status` console command reporting readiness, sessions, persistence, buckets, and
  effective configuration.
- 128 tests across 15 suites.


- Environment bootstrap validation that fails with a structured error naming every
  problem, not just the first.
- Time-ordered immutable identifiers using a Crockford base32 alphabet.
- Service registration and discovery, where an absent service is a condition
  rather than an error so optional dependencies can degrade.
- Sessions with multi-character support, resolving the actor from the session
  rather than from a request payload.
- Capability resolution across concurrent employments: grants union, denials win.
- State bag policy: registration refuses keys naming money, items, capabilities,
  or tokens, because every bag is client-visible.
- Connection lifecycle with an explicit transition table, connection checks, and
  a reconnect plan that always creates a new session.
- Routing bucket allocation owned centrally, with release on empty, on owner
  stop, and on disconnect sweep.
- A persistence provider interface that refuses cross-domain queries, including
  inside transactions, with an in-memory double for tests.
- A required `nxc_server_build` bootstrap value. Every deployment records the exact
  Cfx Server build it runs, so a platform regression can be attributed to a specific
  update rather than to whatever changed most recently.
- A performance budget and a threat model.
- Migration planning with content checksums, drift detection, and ordering.
- A configuration schema and runtime holder. Character limit, live character
  switching, reconnect grace, whitelist requirement, migration application, and
  log level are edited in game rather than in a file. Every setting has a value
  before nxc_config exists, an unknown key raises instead of returning nil, and a
  rejected edit leaves the running value in place.
- The first real migration: accounts, account identifiers, characters, and
  capability grants. Verified against MariaDB 12.3 — applies cleanly, cascades
  correctly, enforces its unique constraint, re-applies idempotently, and
  reverses fully.
- A MariaDB persistence provider backed by oxmysql.
- 93 tests across 10 suites.
