--- Applies pending migrations at startup.
---
--- The planning — ordering, checksums, drift detection — is in
--- `shared/19_migrations.lua` and is fully tested. This file is the part that
--- cannot be: reading files from the resource and talking to a database.
---
--- **Migrations are enumerated in `fxmanifest.lua`, not discovered.** A resource
--- cannot list its own directory at runtime, and more importantly it should not:
--- a file that appears in a folder should not silently become a schema change.
--- Adding a migration is an edit to the manifest.

if not IsDuplicityVersion() then return end

local Migrator = {}

local RESOURCE = NxcCore.RESOURCE
local TABLE = 'nxc_migrations'

--- Migration files declared by the manifest, in declared order.
---
---@return { filename: string, sql: string }[]|nil, string|nil
local function readDeclared()
    local count = GetNumResourceMetadata(RESOURCE, 'nxc_migration')
    local files = {}
    for i = 0, count - 1 do
        local path = GetResourceMetadata(RESOURCE, 'nxc_migration', i)
        local sql = LoadResourceFile(RESOURCE, path)
        if not sql then
            return nil, ('manifest declares migration %s, which does not exist'):format(path)
        end
        files[#files + 1] = { filename = path:match('([^/]+)$') or path, sql = sql }
    end
    return files, nil
end

--- Rows already recorded as applied, FOR THIS RESOURCE ONLY.
---
--- `nxc_migrations` is shared by every resource that migrates — that is why it
--- carries a `resource` column and a unique key on (resource, migration). Reading
--- the whole table would mean nxc_core treating another resource's migrations as
--- its own: their filenames would look applied-ahead, and a filename both
--- resources happened to use would look like checksum drift and refuse to start.
---
--- Reads the bootstrap table the deployment recipe creates. Its absence is a
--- deployment fault rather than a migration fault, and is reported as such —
--- the two have different fixes and conflating them costs an hour.
---
---@param db table
---@return table[]|nil, string|nil
local function readApplied(db)
    local ok, rows = pcall(function()
        return db.query(
            ('SELECT migration, checksum FROM `%s` WHERE resource = ? ORDER BY id'):format(TABLE),
            { RESOURCE })
    end)
    if not ok then
        return nil, ('cannot read `%s`: %s. The deployment recipe creates this table; '):format(
            TABLE, tostring(rows)) .. 'a server deployed without it was not deployed by the recipe'
    end
    return rows or {}, nil
end

--- Apply every pending migration, in order.
---
--- **The run stops at the first failure.** Continuing past a failed migration
--- would apply later statements against a schema that is not what they were
--- written for, and the second failure would be far less informative than the
--- first.
---
--- **A MIGRATION IS NOT WRAPPED IN A TRANSACTION, AND WRAPPING IT WOULD BE A
--- LIE.** MySQL and MariaDB implicitly commit before and after every DDL
--- statement, so `CREATE TABLE` inside a transaction commits regardless and
--- cannot be rolled back. Sending these through `transaction()` would produce
--- code that looks atomic, reads as atomic in review, and silently is not — the
--- worst of the three options.
---
--- What makes partial application survivable instead is that **migration DDL
--- must be idempotent**: every statement uses `IF NOT EXISTS` or its equivalent,
--- so a migration that fails halfway can simply be run again. The record row is
--- written only after every statement in the file has succeeded, so a partial
--- application leaves the migration unrecorded and therefore still pending,
--- which is the state that makes retrying correct.
---
--- MIGRATION_STANDARDS requires the idempotency. This function depends on it.
---
--- **Takes the RAW provider, not a scoped one, and that is deliberate.** The
--- ownership guard in `Persistence.scoped` refuses any statement naming a table
--- outside this resource's prefix, and `nxc_migrations` has no prefix — it is
--- framework infrastructure created by the deployment recipe, shared by every
--- resource that migrates. The guard exists to stop one domain reading or
--- writing another's runtime data; schema evolution is a different activity with
--- a different owner, and routing it through the guard would mean weakening the
--- guard for everyone.
---
---@param db table  the raw provider: query, execute, transaction
---@return NxcResult
function Migrator.run(db)
    local files, readErr = readDeclared()
    if not files then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_MIGRATION_MISSING', readErr, { resource = RESOURCE }))
    end
    if #files == 0 then
        return Nxc.Result.ok({ applied = {}, pending = 0 })
    end

    local planned = NxcCore.Migrations.plan(files)
    if not planned.ok then return planned end

    local applied, appliedErr = readApplied(db)
    if not applied then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_MIGRATION_TABLE_MISSING', appliedErr,
            { resource = RESOURCE, retryable = false }))
    end

    local plan = NxcCore.Migrations.pending(planned.value, applied)
    if not plan.ok then return plan end

    for _, name in ipairs(plan.value.appliedAhead) do
        Nxc.Logger.warn('migration.ahead', {
            migration = name,
            detail = 'applied in the database with no file here; this checkout is behind',
        })
    end

    local done = {}
    for _, migration in ipairs(plan.value.pending) do
        Nxc.Logger.info('migration.applying', { migration = migration.filename })

        local statements = NxcCore.Migrations.statements(migration.sql)
        local completed = 0

        local ok, err = pcall(function()
            for _, statement in ipairs(statements) do
                db.execute(statement, {})
                completed = completed + 1
            end
        end)

        if not ok then
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CORE_MIGRATION_FAILED',
                ('Migration %s failed at statement %d of %d, and the run stopped.')
                    :format(migration.filename, completed + 1, #statements),
                {
                    resource = RESOURCE,
                    details = {
                        migration = migration.filename,
                        reason = tostring(err),
                        statementsApplied = completed,
                        statementsTotal = #statements,
                        -- Not recorded as applied, so it stays pending. Fix the
                        -- cause and restart: the DDL is idempotent, so the
                        -- statements that already succeeded are no-ops.
                        recorded = false,
                        appliedThisRun = done,
                    },
                }))
        end

        -- Recorded only after every statement succeeded. A half-applied
        -- migration must remain pending, or the next run would skip it and
        -- every later migration would apply against a schema nobody described.
        local recorded, recordErr = pcall(function()
            db.execute(
                ('INSERT INTO `%s` (resource, migration, checksum) VALUES (?, ?, ?)'):format(TABLE),
                { RESOURCE, migration.filename, migration.checksum })
        end)
        if not recorded then
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CORE_MIGRATION_UNRECORDED',
                ('Migration %s applied but could not be recorded.'):format(migration.filename),
                {
                    resource = RESOURCE,
                    -- Worse than a failed migration: the schema moved and the
                    -- history did not. Recording it by hand is the fix, and
                    -- doing nothing means the next run applies it again.
                    details = { migration = migration.filename,
                                reason = tostring(recordErr),
                                checksum = migration.checksum },
                }))
        end

        done[#done + 1] = migration.filename
    end

    return Nxc.Result.ok({ applied = done, pending = 0 })
end

NxcCore.Migrator = Migrator
return Migrator
