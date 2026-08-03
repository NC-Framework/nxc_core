--- Account resolution: platform identifiers in, account out.
---
--- The only place `nxc_core_accounts` and `nxc_core_account_identifiers` are
--- written.
---
--- **This lives in `shared/` and takes its provider by injection**, so it runs
--- under the test harness against an in-memory double. The first version was a
--- server file, could not be tested, and shipped a defect that made every
--- connection fail: it treated the scoped provider's `NxcResult` returns as raw
--- rows, so it never found an existing account and then reported the one it had
--- just created as missing.
---
--- **Every provider call returns a Result.** `db.query(...)` is
--- `{ ok = true, value = rows }`, never rows. Getting that wrong is silent —
--- indexing a Result for row 1 yields nil, which reads exactly like "no rows".

local Accounts = {}

local db  -- scoped provider, installed at startup

--- Install the scoped persistence provider.
---
---@param scoped table
function Accounts.setProvider(scoped)
    db = scoped
end

---@return boolean
function Accounts.isReady()
    return db ~= nil
end

--- Unwrap a provider Result, or nil plus the reason.
---
--- Written once, because the failure it prevents does not announce itself.
local function unwrap(result)
    if type(result) ~= 'table' then
        return nil, 'provider returned ' .. type(result) .. ', expected a Result'
    end
    if result.ok == nil then
        return nil, 'provider returned a table that is not a Result'
    end
    if not result.ok then
        local err = result.error or {}
        return nil, tostring(err.code or 'error') .. ': '
            .. tostring((err.details and err.details.reason) or err.message or 'no detail')
    end
    return result.value or {}, nil
end

--- The account an identifier already maps to, if any.
---
--- Every presented identifier is checked, not only the strongest. A player whose
--- licence is unchanged but whose Discord is new must resolve to the same
--- account, and so must the reverse.
---
---@param identifiers table<string, string>
---@return string|nil accountId, string|nil failure
local function findExisting(identifiers)
    for _, kind in ipairs(NxcCore.PlatformIdentity.PRIORITY) do
        local value = identifiers[kind]
        if value then
            local rows, err = unwrap(db.query(
                'SELECT account_id FROM nxc_core_account_identifiers WHERE kind = ? AND value = ?',
                { kind, value }))
            if err then return nil, err end
            if rows[1] then return rows[1].account_id, nil end
        end
    end
    return nil, nil
end

--- Resolve a connecting player to an account, creating one on first connection.
---
---@param identifiers table<string, string>
---@return NxcResult
function Accounts.resolve(identifiers)
    if not db then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_PERSISTENCE_UNAVAILABLE', 'The database is not available.',
            { resource = NxcCore.RESOURCE, retryable = true }))
    end
    if not NxcCore.PlatformIdentity.sufficient(identifiers) then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_NO_IDENTIFIER', 'Your account could not be identified.',
            { resource = NxcCore.RESOURCE }))
    end

    local function failed(reason)
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_ACCOUNT_RESOLUTION_FAILED', 'Your account could not be loaded.',
            { resource = NxcCore.RESOURCE, retryable = true, details = { reason = reason } }))
    end

    local accountId, findErr = findExisting(identifiers)
    if findErr then return failed(findErr) end

    if not accountId then
        local newId = NxcCore.Identifiers.account()
        local statements = {
            { query = 'INSERT INTO nxc_core_accounts (id) VALUES (?)', values = { newId } },
        }
        for _, row in ipairs(NxcCore.PlatformIdentity.rows(newId, identifiers)) do
            statements[#statements + 1] = {
                query = 'INSERT INTO nxc_core_account_identifiers (account_id, kind, value) '
                     .. 'VALUES (?, ?, ?)',
                values = { row.accountId, row.kind, row.value },
            }
        end

        local _, createErr = unwrap(db.transaction(statements))
        if createErr then
            -- Lost a race, or an identifier already belongs to someone else.
            -- Re-reading is right in both cases: the constraint has told us the
            -- truth and our earlier read was stale.
            local raced, racedErr = findExisting(identifiers)
            if racedErr then return failed(racedErr) end
            if not raced then
                return failed('could not create an account, and no existing one was found: '
                    .. createErr)
            end
            accountId = raced
        else
            accountId = newId
        end
    end

    -- New identifiers on a known account. Ignored on duplicate: two connections
    -- racing to add the same one is normal rather than an error.
    for _, row in ipairs(NxcCore.PlatformIdentity.rows(accountId, identifiers)) do
        db.execute('INSERT IGNORE INTO nxc_core_account_identifiers (account_id, kind, value) '
                .. 'VALUES (?, ?, ?)', { row.accountId, row.kind, row.value })
    end

    local rows, readErr = unwrap(db.query(
        'SELECT id, display_name, whitelisted, priority, character_slots '
     .. 'FROM nxc_core_accounts WHERE id = ?', { accountId }))
    if readErr then return failed(readErr) end
    if not rows[1] then
        return failed(('account %s resolved but could not be read back'):format(accountId))
    end

    return Nxc.Result.ok(rows[1])
end

--- How many characters an account holds.
---
---@param accountId string
---@return integer
function Accounts.characterCount(accountId)
    local rows = unwrap(db.query(
        'SELECT COUNT(*) AS n FROM nxc_core_characters WHERE account_id = ? AND deleted_at IS NULL',
        { accountId }))
    return (rows and rows[1] and tonumber(rows[1].n)) or 0
end

--- Record that an account was seen.
---
--- Best effort: a failed timestamp must never stop a player connecting, so the
--- Result is deliberately discarded rather than checked.
---
---@param accountId string
function Accounts.touch(accountId)
    db.execute('UPDATE nxc_core_accounts SET last_seen_at = CURRENT_TIMESTAMP(3) WHERE id = ?',
        { accountId })
end

--- Whether a value read from the database is absent.
---
--- **`x ~= nil` is not enough for a value that came from SQL.** A NULL arrives
--- through oxmysql as whatever the JS bridge marshals `null` into, and it is not
--- Lua nil. That difference rejected every connection on a real server: a
--- nullable column tested with `~= nil` read as present on a row where the
--- database reported it NULL.
---
--- Kept, and tested, even though the column that exposed it is being removed.
--- Every nullable column read from Lua has the same hazard.
---
---@param value any
---@return boolean
function Accounts.isAbsent(value)
    if value == nil then return true end
    local kind = type(value)
    -- Any non-scalar is a sentinel of some sort, and none of them is a value.
    if kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then return true end
    if kind == 'string' then
        local trimmed = value:gsub('^%s+', ''):gsub('%s+$', '')
        return trimmed == '' or trimmed:upper() == 'NULL'
    end
    return false
end

--- Whether an account is whitelisted.
---
--- The column is TINYINT, so the driver may present 1, "1", or true. Absent
--- means not whitelisted: a whitelist that fails open is not a whitelist.
---
---@param account table
---@return boolean
function Accounts.isWhitelisted(account)
    local value = account and account.whitelisted
    if Accounts.isAbsent(value) then return false end
    if type(value) == 'boolean' then return value end
    return tonumber(value) == 1
end

NxcCore.Accounts = Accounts
return Accounts
