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
- 44 tests across 5 suites.
