--- Persistence, which now lives in nxc_lib.
---
--- Moved on 2026-08-03: every resource that owns tables needs it, and it was
--- already parameterised by owner, so nothing about it was ever specific to this
--- resource.
---
--- This alias exists so `NxcCore.Persistence` keeps working. nxc_core is
--- released and running, and ADR-0009 requires expand-and-contract rather than a
--- flag day: add the new location, keep the old one working, remove it in a
--- later major version once no consumer uses it.
---
--- **New code should use `Nxc.Persistence`.**

NxcCore.Persistence = Nxc.Persistence
return Nxc.Persistence
