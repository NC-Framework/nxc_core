--- Connection lifecycle: the FiveM events, and nothing else.
---
--- Every decision here is made by a tested pure module. This file supplies the
--- facts those modules need and carries out what they return, so the logic is
--- testable off-server and only the wiring is not.
---
--- **Enhanced changes the pre-connection flow**, so nothing here assumes the
--- Legacy UDP handshake. Deferrals are used as the platform documents them, and
--- the correlation id is issued at the very first event so that a connection can
--- be followed end to end through the log.

if not IsDuplicityVersion() then return end

local Connection = {}

local pending = {}   -- source -> lifecycle state, for the duration of the handshake

--- Reject a connection with a reason the player can act on.
---
--- The message is the one from the structured error, not a generic string. A
--- player told "you are banned until Friday" can plan; one told "connection
--- refused" opens a ticket.
local function reject(deferrals, err, correlationId)
    Nxc.Logger.info('connection.rejected', {
        correlationId = correlationId,
        code = err.code,
        rejection = err.details and err.details.rejection,
    })
    deferrals.done(err.message)
end

AddEventHandler('playerConnecting', function(_, _, deferrals)
    local source = source
    deferrals.defer()

    local state = NxcCore.Lifecycle.begin(source)
    pending[source] = state
    local cid = state.correlationId

    -- The platform requires a tick between defer() and any other deferral call.
    Wait(0)
    deferrals.update('Checking your account…')

    local raw = {}
    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        raw[#raw + 1] = GetPlayerIdentifier(source, i)
    end
    local identifiers = NxcCore.PlatformIdentity.parse(raw)

    NxcCore.Lifecycle.transition(state, NxcCore.Lifecycle.STAGE.IDENTIFYING)
    Nxc.Logger.info('connection.identifying', {
        correlationId = cid,
        -- Redacted: an identifier is a stable handle to a real person, and logs
        -- travel further and last longer than the database does.
        identifiers = NxcCore.PlatformIdentity.redact(identifiers),
    })

    if not NxcCore.PlatformIdentity.sufficient(identifiers) then
        pending[source] = nil
        return reject(deferrals, {
            code = 'NXC_CORE_CONNECTION_REJECTED',
            message = 'Your account could not be identified. Restart your game and try again.',
            details = { rejection = NxcCore.Lifecycle.REJECTION.NO_IDENTIFIER },
        }, cid)
    end

    local resolved = NxcCore.Accounts.resolve(identifiers)
    if not resolved.ok then
        pending[source] = nil
        return reject(deferrals, resolved.error, cid)
    end
    local account = resolved.value

    NxcCore.Lifecycle.transition(state, NxcCore.Lifecycle.STAGE.CHECKING)

    -- Facts in, decision out. The ordering rules — identifier before ban, ban
    -- before whitelist — live in the tested module, not here.
    local decision = NxcCore.Lifecycle.evaluateConnection({
        bootstrapOk = NxcCore.Startup.isReady(),
        hasIdentifier = true,
        banned = account.banned_until ~= nil,
        banReason = account.ban_reason,
        whitelisted = tonumber(account.whitelisted) == 1,
        whitelistRequired = NxcCore.Config.get('nxc_core.connection.whitelistRequired'),
        slotsFree = true,
    })
    if not decision.ok then
        pending[source] = nil
        return reject(deferrals, decision.error, cid)
    end

    state.accountId = account.id
    NxcCore.Accounts.touch(account.id)
    Nxc.Logger.info('connection.accepted', { correlationId = cid, accountId = account.id })
    deferrals.done()
end)

AddEventHandler('playerJoining', function()
    local source = source
    local state = pending[source]
    if not state then return end
    pending[source] = nil

    local created = NxcCore.Sessions.create({
        source = source,
        accountId = state.accountId,
        correlationId = state.correlationId,
    })
    if not created.ok then
        Nxc.Logger.error('session.create_failed', {
            correlationId = state.correlationId,
            code = created.error.code,
        })
        DropPlayer(source, created.error.message)
        return
    end

    NxcCore.Lifecycle.transition(state, NxcCore.Lifecycle.STAGE.SESSION_OPEN)

    -- State bags are client-visible, so only non-sensitive facts go in one. The
    -- policy module refuses keys naming money, items, capabilities, or tokens;
    -- this deliberately publishes neither the account id nor any identifier.
    Player(source).state:set('nxcSession', {
        sessionId = created.value.id,
        stage = state.stage,
    }, true)

    Nxc.Logger.info('session.open', {
        correlationId = state.correlationId,
        sessionId = created.value.id,
    })
end)

AddEventHandler('playerDropped', function()
    local source = source
    pending[source] = nil

    local session = NxcCore.Sessions.get(source)
    if not session then return end

    -- The plan is data from a tested module; this only carries it out.
    -- **Cleanup cannot depend on a clean exit path** — a crashed client never
    -- runs one — so this is driven from the drop event and nowhere else.
    local plan = NxcCore.Lifecycle.disconnectPlan(session)
    -- Sweep the player out of EVERY bucket rather than only the one the session
    -- recorded. The session's bucket is what we believe; the sweep is what is
    -- true, and a player left occupying a bucket keeps it alive forever.
    NxcCore.Buckets.removeOccupant(source)
    NxcCore.Sessions.destroy(source)

    Nxc.Logger.info('session.closed', {
        correlationId = session.correlationId,
        sessionId = plan.sessionId,
        steps = plan.steps,
    })
end)

--- Sessions currently open. Used by the status command and by health reporting.
---@return integer
function Connection.sessionCount()
    return NxcCore.Sessions.count()
end

NxcCore.Connection = Connection
return Connection
