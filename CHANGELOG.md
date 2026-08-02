# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

## Unreleased

Initial foundation: startup lifecycle, identity, sessions, service discovery, and
capability resolution.

### Added

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
- 116 tests across 13 suites.
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
