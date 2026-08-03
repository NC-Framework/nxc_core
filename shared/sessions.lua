--- Accounts, characters, and sessions.
---
---     Account      one real person        stable across characters and sessions
---       Character    one persona          stable across sessions
---         Session      one play period    ends at disconnect
---
--- **An account holds multiple characters** (R-215). Nearly all gameplay state
--- hangs off a character; priority and framework permissions hang off the
--- account, so a permission granted to a person applies to every persona they
--- play (R-216).
---
--- **Banning is not the framework's.** FXServer and txAdmin handle it, and they
--- match on platform identifiers rather than on anything here — which means a
--- ban already stops every character, without this code having an opinion.
---
--- **Every request resolves its actor from the session, never from the payload.**
--- A request naming a character id is making a claim, not stating a fact. This
--- single rule prevents an entire class of impersonation exploit.

local Sessions = {}

Sessions.MAX_CHARACTERS_DEFAULT = 5

local sessions = {}          -- source -> session
local accountsBySession = {} -- sessionId -> source

--- Create a session for a connected player.
---
--- A session is created at connection and holds no character until one is
--- selected. `activeCharacterId` being nil is a normal state, not an error.
---
--- `correlationId` may be supplied to continue the connection's own id into the
--- session. A connection and the session it produces are one story, and issuing
--- a fresh id here would break the trail at exactly the point someone follows it.
---
---@param opts { source: any, accountId: string, identifiers?: table, bucket?: integer, correlationId?: string }
---@return NxcResult
function Sessions.create(opts)
    if type(opts) ~= 'table' then
        error('Sessions.create requires options', 2)
    end
    if opts.source == nil then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'source', reason = 'is required' } } }))
    end
    if not NxcCore.Identifiers.isValid(opts.accountId, NxcCore.Identifiers.PREFIX.ACCOUNT) then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'accountId', reason = 'is not a valid account identifier' } } }))
    end
    if sessions[opts.source] then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_SESSION_EXISTS', 'A session already exists for that connection.',
            { resource = NxcCore.RESOURCE, details = { source = tostring(opts.source) } }))
    end

    local session = {
        id = NxcCore.Identifiers.session(),
        source = opts.source,
        accountId = opts.accountId,
        activeCharacterId = nil,
        identifiers = opts.identifiers or {},
        bucket = opts.bucket or 0,
        correlationId = opts.correlationId or Nxc.Correlation.new(),
        createdAt = Nxc.Time.nowMs(),

        --- Capability grants held by this session.
        ---
        --- **NOTHING POPULATES THIS YET.** Capabilities are computed by a pure
        --- module with no storage and no wiring behind it: employment, ranks,
        --- and organisation membership are all later phases. The field exists so
        --- the shape is settled and so a consumer asking about a capability gets
        --- a definite `false` rather than an error.
        ---
        --- Failing closed is the right direction for the gap. A server-side gate
        --- that refuses everything is visible immediately; one that permits
        --- everything is not visible at all.
        capabilityGrants = opts.capabilityGrants or {},
    }
    sessions[opts.source] = session
    accountsBySession[session.id] = opts.source
    return Nxc.Result.ok(session)
end

--- Replace the capability grants on a session.
---
--- Whole-list replacement rather than add and remove, because a grant is
--- evidence of a relationship — an employment, a rank — and those change as a
--- set. Merging piecemeal is how a revoked one survives.
---
---@param source any
---@param grants table
---@return NxcResult
function Sessions.setCapabilityGrants(source, grants)
    local session = sessions[source]
    if not session then
        return Nxc.Result.err(Nxc.Errors.sessionInvalid())
    end
    if type(grants) ~= 'table' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'grants', reason = 'must be a list of grant records' } } }))
    end
    session.capabilityGrants = grants
    return Nxc.Result.ok(true)
end

--- The session for a connection, or nil.
---
---@param source any
---@return table|nil
function Sessions.get(source)
    return sessions[source]
end

--- Resolve the acting account from a connection.
---
--- **This is how the server knows who is asking.** Never take an account or
--- character id from a request payload.
---
---@param source any
---@return string|nil
function Sessions.resolveAccount(source)
    local s = sessions[source]
    return s and s.accountId or nil
end

--- Resolve the acting character from a connection.
---
--- Returns nil when no character is selected, which is a normal state during
--- character selection rather than an error.
---
---@param source any
---@return string|nil
function Sessions.resolveCharacter(source)
    local s = sessions[source]
    return s and s.activeCharacterId or nil
end

--- Select a character on a session.
---
--- The character must belong to the session's account. Without that check, a
--- client could select any character in the database by sending its identifier.
---
---@param source any
---@param characterId string
---@param ownedBy fun(characterId: string): string|nil  returns the owning account id
---@return NxcResult
function Sessions.selectCharacter(source, characterId, ownedBy)
    local s = sessions[source]
    if not s then
        return Nxc.Result.err(Nxc.Errors.sessionInvalid())
    end
    if not NxcCore.Identifiers.isValid(characterId, NxcCore.Identifiers.PREFIX.CHARACTER) then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'characterId', reason = 'is not a valid character identifier' } } },
            s.correlationId))
    end

    local owner = ownedBy(characterId)
    if owner ~= s.accountId then
        -- Deliberately the same error as a missing character. Distinguishing
        -- them would confirm that a character id exists, which is a probing
        -- oracle.
        return Nxc.Result.err(Nxc.Errors.forbidden('core.character.select', s.correlationId))
    end

    local previous = s.activeCharacterId
    s.activeCharacterId = characterId
    return Nxc.Result.ok({ session = s, previousCharacterId = previous })
end

--- Clear the active character.
---
--- Called on character switch, before the new character loads. The caller is
--- responsible for the cleanup this implies — unload event, bucket release,
--- state bag clearing — which is why the previous id is returned rather than
--- discarded (P2-10).
---
---@param source any
---@return NxcResult
function Sessions.clearCharacter(source)
    local s = sessions[source]
    if not s then
        return Nxc.Result.err(Nxc.Errors.sessionInvalid())
    end
    local previous = s.activeCharacterId
    s.activeCharacterId = nil
    return Nxc.Result.ok({ session = s, previousCharacterId = previous })
end

--- Destroy a session on disconnect.
---
--- Returns what was cleaned up so the caller can release the bucket and any
--- character-scoped state. **Cleanup must not depend on a clean exit path**: a
--- crashed client never runs one, so this is called from the disconnect handler
--- rather than from an orderly shutdown.
---
---@param source any
---@return NxcResult
function Sessions.destroy(source)
    local s = sessions[source]
    if not s then
        return Nxc.Result.err(Nxc.Errors.sessionInvalid())
    end
    sessions[source] = nil
    accountsBySession[s.id] = nil
    return Nxc.Result.ok({
        sessionId = s.id,
        accountId = s.accountId,
        characterId = s.activeCharacterId,
        bucket = s.bucket,
    })
end

--- Sessions currently held by an account.
---
--- Used to enforce whatever concurrent-login policy is chosen. The policy itself
--- is an open question in ADR-0012; this reports the facts it needs.
---
---@param accountId string
---@return table[]
function Sessions.forAccount(accountId)
    local out = {}
    for _, s in pairs(sessions) do
        if s.accountId == accountId then out[#out + 1] = s end
    end
    return out
end

--- Whether an account may hold another character.
---
--- Slot count is operational configuration. It may be passed in explicitly —
--- a test does, and so would a per-account override such as a donor tier — and
--- otherwise comes from the configured value.
---
---@param currentCount integer
---@param maxSlots integer|nil
---@return boolean
function Sessions.canCreateCharacter(currentCount, maxSlots)
    return currentCount < (maxSlots or Sessions.configuredMaxCharacters())
end

--- The configured character limit.
---
--- Read through the configuration holder rather than from the constant, so an
--- operator raising the limit in game takes effect on the next creation attempt.
--- The constant remains the declared fallback for the window before
--- configuration is available.
---
---@return integer
function Sessions.configuredMaxCharacters()
    if NxcCore.Config then
        return NxcCore.Config.get('nxc_core.characters.maxPerAccount')
    end
    return Sessions.MAX_CHARACTERS_DEFAULT
end

---@return integer
function Sessions.count()
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return n
end

--- Test helper.
function Sessions.reset()
    sessions = {}
    accountsBySession = {}
end

NxcCore.Sessions = Sessions
return Sessions
