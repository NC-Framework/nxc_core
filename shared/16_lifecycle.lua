--- Connection lifecycle and reconnect recovery.
---
--- A player moves through a defined sequence, and every stage can fail. Each
--- failure has a defined outcome: a player rejected at the ban check gets a
--- clear reason, and a player who disconnects mid-load leaves no partial state.
---
--- **A reconnecting player gets a NEW session.** Reconnect recovery restores
--- character state from the database; it does not resurrect the old session. A
--- resurrected session would have to reconcile a token that may have leaked
--- during the disconnection, and the recovery path is the same one needed after
--- a server restart anyway.

local Lifecycle = {}

Lifecycle.STAGE = {
    CONNECTING     = 'connecting',
    IDENTIFYING    = 'identifying',
    CHECKING       = 'checking',       -- ban and whitelist
    QUEUED         = 'queued',
    SESSION_OPEN   = 'session_open',
    SELECTING      = 'selecting',      -- character selection
    LOADING        = 'loading',
    PLAYING        = 'playing',
    DISCONNECTING  = 'disconnecting',
}

Lifecycle.REJECTION = {
    NO_IDENTIFIER  = 'no_identifier',
    BANNED         = 'banned',
    NOT_WHITELISTED = 'not_whitelisted',
    SERVER_FULL    = 'server_full',
    BOOTSTRAP_FAILED = 'bootstrap_failed',
}

-- Which stage may follow which. An undefined transition is a bug, and catching
-- it here beats discovering it as an inconsistent session later.
local TRANSITIONS = {
    connecting    = { identifying = true, disconnecting = true },
    identifying   = { checking = true, disconnecting = true },
    checking      = { queued = true, session_open = true, disconnecting = true },
    queued        = { session_open = true, disconnecting = true },
    session_open  = { selecting = true, disconnecting = true },
    selecting     = { loading = true, disconnecting = true },
    loading       = { playing = true, selecting = true, disconnecting = true },
    -- playing -> selecting is a character switch, which is a normal transition.
    playing       = { selecting = true, disconnecting = true },
    disconnecting = {},
}

--- Whether a transition is permitted.
---
---@param from string
---@param to string
---@return boolean
function Lifecycle.canTransition(from, to)
    local allowed = TRANSITIONS[from]
    return allowed ~= nil and allowed[to] == true
end

--- Advance a lifecycle state.
---
---@param state table
---@param to string
---@return NxcResult
function Lifecycle.transition(state, to)
    if type(state) ~= 'table' or type(state.stage) ~= 'string' then
        error('Lifecycle.transition requires a lifecycle state', 2)
    end
    if not Lifecycle.canTransition(state.stage, to) then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_INVALID_TRANSITION',
            'That is not a valid lifecycle transition.',
            {
                resource = NxcCore.RESOURCE,
                details = { from = state.stage, to = to },
            }))
    end
    state.previousStage = state.stage
    state.stage = to
    state.changedAt = Nxc.Time.nowMs()
    return Nxc.Result.ok(state)
end

--- Begin a connection.
---
---@param source any
---@return table
function Lifecycle.begin(source)
    return {
        source = source,
        stage = Lifecycle.STAGE.CONNECTING,
        previousStage = nil,
        startedAt = Nxc.Time.nowMs(),
        changedAt = Nxc.Time.nowMs(),
        correlationId = Nxc.Correlation.new(),
    }
end

--- Evaluate the connection checks.
---
--- Returns the first rejection, because a rejected player needs one clear
--- reason rather than a list. The order is deliberate: identifier before ban,
--- because a ban check needs an identifier to check against.
---
---@param facts { hasIdentifier: boolean, banned: boolean, banReason?: string, whitelisted: boolean, whitelistRequired: boolean, slotsFree: boolean, bootstrapOk: boolean }
---@return NxcResult
function Lifecycle.evaluateConnection(facts)
    if facts.bootstrapOk == false then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_CONNECTION_REJECTED', 'The server is not accepting connections.',
            { resource = NxcCore.RESOURCE,
              details = { rejection = Lifecycle.REJECTION.BOOTSTRAP_FAILED } }))
    end
    if not facts.hasIdentifier then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_CONNECTION_REJECTED', 'Your account could not be identified.',
            { resource = NxcCore.RESOURCE,
              details = { rejection = Lifecycle.REJECTION.NO_IDENTIFIER } }))
    end
    -- The ban is checked against the ACCOUNT, not the character. A ban that
    -- only stops one character is not a ban.
    if facts.banned then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_CONNECTION_REJECTED', facts.banReason or 'You are banned from this server.',
            { resource = NxcCore.RESOURCE,
              details = { rejection = Lifecycle.REJECTION.BANNED } }))
    end
    if facts.whitelistRequired and not facts.whitelisted then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_CONNECTION_REJECTED', 'This server is whitelisted.',
            { resource = NxcCore.RESOURCE,
              details = { rejection = Lifecycle.REJECTION.NOT_WHITELISTED } }))
    end
    if not facts.slotsFree then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_CONNECTION_REJECTED', 'The server is full.',
            { resource = NxcCore.RESOURCE,
              details = { rejection = Lifecycle.REJECTION.SERVER_FULL } }))
    end
    return Nxc.Result.ok(true)
end

--- Build a reconnect recovery plan.
---
--- The plan is data, so it is testable and auditable. Applying it belongs to the
--- caller, which has the natives and the database.
---
---@param opts { accountId: string, lastCharacterId?: string, lastSeenMs?: number, graceMs?: number, nowMs?: number }
---@return { newSession: boolean, restoreCharacter: boolean, characterId: string|nil, reason: string }
function Lifecycle.planReconnect(opts)
    local nowMs = opts.nowMs or Nxc.Time.nowMs()
    local grace = opts.graceMs or (5 * 60 * 1000)

    -- Always a new session. Never a resurrected one.
    local plan = { newSession = true, restoreCharacter = false, characterId = nil }

    if not opts.lastCharacterId then
        plan.reason = 'no previous character; the player selects one'
        return plan
    end

    local elapsed = nowMs - (opts.lastSeenMs or 0)
    if elapsed > grace then
        plan.reason = ('last seen %s ago, beyond the grace window; the player selects again')
            :format(Nxc.Time.formatDuration(elapsed))
        return plan
    end

    plan.restoreCharacter = true
    plan.characterId = opts.lastCharacterId
    plan.reason = 'within the grace window; the previous character is restored'
    return plan
end

--- What a disconnect must clean up.
---
--- Returned as data rather than performed, so the caller can act on it and a
--- test can assert on it. **Cleanup cannot depend on a clean exit path**: a
--- crashed client never runs one, so this is driven from the disconnect handler.
---
---@param session table|nil
---@return table
function Lifecycle.disconnectPlan(session)
    if not session then
        return { sessionId = nil, releaseBucket = nil, unloadCharacter = nil, steps = {} }
    end
    local steps = {}
    if session.activeCharacterId then
        steps[#steps + 1] = 'unload character'
        steps[#steps + 1] = 'clear character state bags'
    end
    if session.bucket and session.bucket ~= 0 then
        steps[#steps + 1] = 'release routing bucket'
    end
    steps[#steps + 1] = 'destroy session'
    steps[#steps + 1] = 'forget rate limit buckets'

    return {
        sessionId = session.id,
        releaseBucket = (session.bucket ~= 0) and session.bucket or nil,
        unloadCharacter = session.activeCharacterId,
        steps = steps,
    }
end

NxcCore.Lifecycle = Lifecycle
return Lifecycle
