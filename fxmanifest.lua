fx_version 'cerulean'
game 'gta5'

-- Platform target. MDD v0.4 section 38.3 requires every resource to declare its
-- Enhanced compatibility in its manifest; ADR-0016 records the decision.
--
-- These are first-party metadata keys rather than CitizenFX directives. An
-- arbitrary top-level key becomes resource metadata readable through
-- GetResourceMetadata, so the mechanism is supported; whether the platform
-- offers an official directive for this has not been verified, and is open as
-- OD-021 rather than assumed either way.
--
-- nxc_min_server_build is the Enhanced Cfx Server build this was first deployed
-- against, reported as `b106-ea` on 2026-08-02. OD-020 and blocker B-11 closed.
--
-- NOT expressed as a `/server:106` dependency constraint, which is the mechanism
-- the platform enforces. That constraint compares build numbers, and Legacy
-- numbers them far HIGHER — around 25770 — so `/server:106` passes trivially on
-- Legacy and guards nothing. It is added when a resource actually needs a
-- specific Enhanced build, where it would buy something.
nxc_platform 'gta5_enhanced'
nxc_min_server_build '106'
nxc_legacy_compatibility 'none'

author 'The Nexus Core Framework team'
description 'The Nexus Core framework spine: lifecycle, identity, sessions, permissions, shared state, and service discovery.'
version '0.3.0'

-- EVERY RESOURCE HAS ITS OWN LUA STATE. A global set by nxc_lib is not visible
-- here; `Nxc` simply does not exist in this resource unless nxc_lib's modules are
-- loaded INTO it. Declaring nxc_lib as a dependency controls start order and
-- nothing else — it does not share code.
--
-- The `@resource/path` form loads another resource's file into this state, which
-- is how a shared library is actually shared. Listed in load order, before this
-- resource's own modules, exactly as they load inside nxc_lib.
--
-- Enumerated rather than globbed so that adding a module to nxc_lib is a
-- deliberate act here too, and because load order is dependency order rather
-- than alphabetical. check-manifests.mjs fails if this list drifts from
-- nxc_lib's shared directory.
--
-- Each resource gets its OWN COPY of nxc_lib's state. Rate-limit buckets, logger
-- configuration, and registered locales in this resource are separate from
-- nxc_lib's own. That is correct for primitives, which are pure; anything needing
-- genuinely shared state must cross the boundary through an export instead.
shared_scripts {
    '@nxc_lib/shared/namespace.lua',
    '@nxc_lib/shared/result.lua',
    '@nxc_lib/shared/errors.lua',
    '@nxc_lib/shared/correlation.lua',
    '@nxc_lib/shared/time.lua',
    '@nxc_lib/shared/serialize.lua',
    '@nxc_lib/shared/validate.lua',
    '@nxc_lib/shared/envelope.lua',
    '@nxc_lib/shared/ratelimit.lua',
    '@nxc_lib/shared/cancel.lua',
    '@nxc_lib/shared/logger.lua',
    '@nxc_lib/shared/locale.lua',
    '@nxc_lib/shared/permissions.lua',
    '@nxc_lib/shared/health.lua',
    '@nxc_lib/shared/persistence.lua',
    '@nxc_lib/shared/migrations.lua',
    '@nxc_lib/shared/config_schema.lua',

    'shared/namespace.lua',
    'shared/identifiers.lua',
    'shared/bootstrap.lua',
    'shared/services.lua',
    'shared/sessions.lua',
    'shared/capabilities.lua',
    'shared/statebags.lua',
    'shared/lifecycle.lua',
    'shared/buckets.lua',
    'shared/persistence.lua',
    'shared/migrations.lua',
    'shared/config_schema.lua',
    'shared/config.lua',
    'shared/platform_identity.lua',
    'shared/accounts.lua',
    'shared/tokens.lua',
}

files {
    'locales/*.json',
}

server_scripts {
    'server/mariadb_provider.lua',
    'server/migrator.lua',
    'server/connection.lua',
    'server/config_client.lua',
    'server/startup.lua',
    'server/api.lua',
}

-- Migrations are ENUMERATED, not discovered. A resource cannot list its own
-- directory at runtime, and it should not: a .sql file appearing in a folder
-- must not silently become a schema change. Adding one is an edit here.
--
-- Order is the order they apply in.
nxc_migration 'migrations/0001_accounts_and_characters.sql'
nxc_migration 'migrations/0002_drop_ban_columns.sql'

-- No client block yet: nothing client-side is implemented. It is added when
-- the client directory gains files.

dependencies {
    'nxc_lib',
    'oxmysql',
}
