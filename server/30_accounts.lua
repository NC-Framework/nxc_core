--- Account resolution: platform identifiers in, account out.
---
--- The only place `nxc_core_accounts` and `nxc_core_account_identifiers` are
--- written. Every query goes through the scoped provider, so a statement naming
--- another domain's table fails here rather than succeeding quietly.
---
--- **Resolution is find-or-create, and the create is racy by nature.** Two
--- connections from one player in the same tick would both find nothing and both
--- insert. The unique constraint on (kind, value) is what makes that safe: one
--- insert wins, the loser re-reads and finds the winner's account. The constraint
--- is the mechanism, not the application check before it.

if not IsDuplicityVersion() then return end

local Accounts = {}

local db  -- scoped provider, installed at startup

---@param scoped table
function Accounts.setProvider(scoped)
    db = scoped
end

--- The account an identifier already maps to, if any.
---
--- Every presented identifier is checked, not just the primary. A player whose
--- licence is unchanged but whose Discord is new must resolve to the same
--- account, and so must the reverse.
---
---@param identifiers table<string, string>
---@return string|nil accountId
local function findExisting(identifiers)
    for _, kind in ipairs(NxcCore.PlatformIdentity.PRIORITY) do
        local value = identifiers[kind]
        if value then
            local rows = db.query(
                'SELECT account_id FROM nxc_core_account_identifiers WHERE kind = ? AND value = ?',
                { kind, value })
            if rows and rows[1] then return rows[1].account_id end
        end
    end
    return nil
end

--- Resolve a connecting player to an account, creating one if this is their
--- first connection.
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

    local ok, result = pcall(function()
        local accountId = findExisting(identifiers)

        if not accountId then
            accountId = NxcCore.Identifiers.account()
            local statements = {
                { query = 'INSERT INTO nxc_core_accounts (id) VALUES (?)', values = { accountId } },
            }
            for _, row in ipairs(NxcCore.PlatformIdentity.rows(accountId, identifiers)) do
                statements[#statements + 1] = {
                    query = 'INSERT INTO nxc_core_account_identifiers (account_id, kind, value) '
                         .. 'VALUES (?, ?, ?)',
                    values = { row.accountId, row.kind, row.value },
                }
            end

            local created = pcall(function() return db.transaction(statements) end)
            if not created then
                -- Lost the race, or one identifier already belonged to someone
                -- else. Re-reading is correct in both cases: the constraint has
                -- told us the truth and our copy was stale.
                accountId = findExisting(identifiers)
                if not accountId then error('account creation failed and no existing account was found', 0) end
            end
        end

        -- New identifiers on a known account. Ignored on duplicate, because two
        -- connections racing to add the same one is normal rather than an error.
        for _, row in ipairs(NxcCore.PlatformIdentity.rows(accountId, identifiers)) do
            pcall(function()
                db.execute('INSERT IGNORE INTO nxc_core_account_identifiers '
                        .. '(account_id, kind, value) VALUES (?, ?, ?)',
                    { row.accountId, row.kind, row.value })
            end)
        end

        local rows = db.query(
            'SELECT id, display_name, whitelisted, priority, character_slots, banned_until, '
         .. 'ban_reason FROM nxc_core_accounts WHERE id = ?', { accountId })
        if not rows or not rows[1] then error('account ' .. accountId .. ' vanished after resolution', 0) end
        return rows[1]
    end)

    if not ok then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_ACCOUNT_RESOLUTION_FAILED', 'Your account could not be loaded.',
            { resource = NxcCore.RESOURCE, retryable = true,
              details = { reason = tostring(result) } }))
    end
    return Nxc.Result.ok(result)
end

--- How many characters an account holds.
---
---@param accountId string
---@return integer
function Accounts.characterCount(accountId)
    local rows = db.query(
        'SELECT COUNT(*) AS n FROM nxc_core_characters WHERE account_id = ? AND deleted_at IS NULL',
        { accountId })
    return (rows and rows[1] and tonumber(rows[1].n)) or 0
end

--- Record that an account was seen. Best effort: a failed timestamp write must
--- never stop a player connecting.
---
---@param accountId string
function Accounts.touch(accountId)
    pcall(function()
        db.execute('UPDATE nxc_core_accounts SET last_seen_at = CURRENT_TIMESTAMP(3) WHERE id = ?',
            { accountId })
    end)
end

NxcCore.Accounts = Accounts
return Accounts
