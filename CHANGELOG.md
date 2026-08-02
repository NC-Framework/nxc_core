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
- 83 tests across 9 suites.
- A performance budget and a threat model.
