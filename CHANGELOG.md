# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

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
