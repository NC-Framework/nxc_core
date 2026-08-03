--- The framework's export surface.
---
--- **nxc_core HAD NONE.** It owned sessions, accounts, characters, capabilities,
--- and identity, and exported not one of them — so no other resource could ask
--- it anything at all. Every resource has its own Lua state, so `NxcCore.
--- Sessions` is not reachable from outside no matter how public it looks.
---
--- Found while writing nxc_target, whose server-side authority check needs to
--- ask "does this player hold this capability" and had nowhere to ask. It is the
--- same class as the two resources that shipped with no entry point: code that
--- exists, is correct, is tested, and is unreachable.
---
--- **EVERY FUNCTION HERE TAKES `source` AND RESOLVES FROM THE SERVER'S OWN
--- STATE.** None of them accept an account id, character id, or capability list
--- from the caller. A resource asking "is player 12 allowed to do X" gets an
--- answer about the session the server holds for connection 12, never about
--- whatever the asker believed. That is what makes this safe to expose: a
--- malicious resource can only ask questions, and only about connections that
--- actually exist.
---
--- Every return value is `Nxc.plain`. A Result is frozen, and a frozen table
--- crosses a resource boundary as an empty one.

if not IsDuplicityVersion() then return end

local Api = {}

--- Is the framework up?
---
--- The first thing any dependent resource needs, and the reason a resource
--- should not simply assume nxc_core started before it.
exports('isReady', function()
    return NxcCore.Startup ~= nil and NxcCore.Startup.isReady() or false
end)

--- A summary of the session on a connection.
---
--- A SUMMARY, not the session. The stored session carries a token and internal
--- bookkeeping that no consumer needs and none should be handed — a token
--- crossing to another resource is a token with a wider blast radius than it was
--- issued for.
---
---@param source any
---@return table|nil
function Api.session(source)
    local session = NxcCore.Sessions.get(source)
    if not session then return nil end
    return {
        id = session.id,
        accountId = session.accountId,
        characterId = session.activeCharacterId,
        createdAt = session.createdAt,
    }
end
exports('session', function(source) return Nxc.plain(Api.session(source)) end)

--- The acting account for a connection.
---
--- **This is how another resource learns who is asking.** Never take an account
--- id from a request payload; ask here with the connection the event arrived on.
exports('accountFor', function(source)
    return NxcCore.Sessions.resolveAccount(source)
end)

--- The acting character, or nil during character selection.
exports('characterFor', function(source)
    return NxcCore.Sessions.resolveCharacter(source)
end)

--- Does this connection hold this capability?
---
--- The question nxc_target's server-side gate exists to ask, and the reason this
--- file was written.
---
---@param source any
---@param capability string
---@return boolean
function Api.hasCapability(source, capability)
    if type(capability) ~= 'string' or capability == '' then return false end

    local session = NxcCore.Sessions.get(source)
    if not session then return false end

    local resolved = NxcCore.Capabilities.resolve(session.capabilityGrants or {})
    return NxcCore.Capabilities.has(resolved, capability) and true or false
end
exports('hasCapability', function(source, capability)
    return Api.hasCapability(source, capability)
end)

--- Every capability a connection holds, as a set.
---
--- A set rather than a list, because every caller wants membership rather than
--- enumeration, and a list makes each of them write the same loop.
---
---@param source any
---@return table
function Api.capabilities(source)
    local session = NxcCore.Sessions.get(source)
    if not session then return {} end

    local resolved = NxcCore.Capabilities.resolve(session.capabilityGrants or {})
    local out = {}
    for _, capability in ipairs(NxcCore.Capabilities.list(resolved)) do
        out[capability] = true
    end
    return out
end
exports('capabilities', function(source) return Nxc.plain(Api.capabilities(source)) end)

NxcCore.Api = Api
return Api
