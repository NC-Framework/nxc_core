--- nxc_core — the framework spine.
---
--- Lifecycle, identity, session, permission interfaces, state policy, service
--- discovery, and framework-level contracts.
---
--- nxc_core is deliberately small. Inventory, banking, jobs, vehicles,
--- properties, police, and medical logic are excluded by design: everything
--- depends on this resource, so every addition widens the blast radius of a
--- change and slows the restart cycle for unrelated work.
---
--- Every framework that became a monolith did so one reasonable exception at a
--- time, and the pressure is always local and always plausible.

NxcCore = NxcCore or {}

NxcCore.RESOURCE = 'nxc_core'
NxcCore.VERSION = '0.1.0'

--- Contract version of the framework surface other resources depend on.
--- Incremented when a framework contract changes incompatibly.
NxcCore.CONTRACT_VERSION = 1

return NxcCore
