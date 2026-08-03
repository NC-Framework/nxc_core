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
--- Read from the manifest so the version is stated ONCE.
---
--- It used to be a literal here as well as in fxmanifest.lua, and they drifted:
--- the manifest said 0.2.0 while every log line and the startup banner said
--- 0.1.0. Two sources of truth for a version is one source of truth and one
--- rumour.
---
--- The fallback is for the test harness, where no natives exist. It is the only
--- place the literal can still be wrong, and there it cannot mislead an operator.
NxcCore.VERSION = (type(GetResourceMetadata) == 'function'
    and GetResourceMetadata(GetCurrentResourceName(), 'version', 0))
    or '0.0.0-test'

--- Contract version of the framework surface other resources depend on.
--- Incremented when a framework contract changes incompatibly.
NxcCore.CONTRACT_VERSION = 2

return NxcCore
