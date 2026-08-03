--- Migration planning, which now lives in nxc_lib.
---
--- Moved on 2026-08-03, for the reason recorded in `shared/persistence.lua`.
--- This alias keeps `NxcCore.Migrations` working for a released resource.
---
--- **New code should use `Nxc.Migrations`.**

NxcCore.Migrations = Nxc.Migrations
return Nxc.Migrations
