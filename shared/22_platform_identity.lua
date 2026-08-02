--- Platform identifiers presented by a connecting player.
---
--- Distinct from `10_identifiers.lua`, which mints Nexus Core's own identifiers.
--- These are what FiveM hands us — `license:abc`, `discord:123`, `steam:110…` —
--- and they are the only evidence available at connection time about who a
--- player is.
---
--- **An identifier is a claim about identity, not the identity.** It maps to an
--- account; it is never the account id. That indirection is what lets a player
--- change Discord accounts, or the platform retire an identifier kind, without
--- rewriting every row that references them.
---
--- Pure: the identifier list is passed in, so this is testable without a server.

local PlatformIdentity = {}

--- Identifier kinds, most trustworthy first.
---
--- `license` is the Rockstar licence and is the strongest available: it is tied
--- to the game entitlement rather than to an account the player can swap.
---
--- **`ip` is deliberately absent, and its absence is a security property.** An
--- address is shared by a household, reassigned by a provider, and trivially
--- changed. Treating one as identity both merges strangers and separates the
--- same person, and the failure is silent in each direction.
PlatformIdentity.PRIORITY = { 'license', 'license2', 'fivem', 'steam', 'discord', 'xbl', 'live' }

local ACCEPTED = {}
for _, kind in ipairs(PlatformIdentity.PRIORITY) do ACCEPTED[kind] = true end

--- Parse a FiveM identifier list into a kind → value map.
---
--- Unknown kinds are dropped rather than stored. A kind nobody has reasoned
--- about should not silently become an identity key.
---
---@param list string[]
---@return table<string, string>
function PlatformIdentity.parse(list)
    local out = {}
    for _, raw in ipairs(list or {}) do
        if type(raw) == 'string' then
            local kind, value = raw:match('^(%w+):(.+)$')
            -- Only the FIRST of a kind is kept. A player presenting two
            -- licences is presenting one true one and one to be explained;
            -- taking the later would let ordering decide identity.
            if kind and value and ACCEPTED[kind] and not out[kind] then
                out[kind] = value
            end
        end
    end
    return out
end

--- The strongest identifier available, by declared priority.
---
--- Returns nil when nothing usable was presented, which is a rejectable
--- condition rather than an error: a player with no identifier cannot be given
--- an account, and guessing one would create a new account on every connection.
---
---@param identifiers table<string, string>
---@return string|nil kind, string|nil value
function PlatformIdentity.primary(identifiers)
    for _, kind in ipairs(PlatformIdentity.PRIORITY) do
        local value = identifiers[kind]
        if value and value ~= '' then return kind, value end
    end
    return nil, nil
end

--- Whether enough identity was presented to resolve an account.
---
---@param identifiers table<string, string>
---@return boolean
function PlatformIdentity.sufficient(identifiers)
    local kind = PlatformIdentity.primary(identifiers)
    return kind ~= nil
end

--- Identifiers as rows ready for `nxc_core_account_identifiers`.
---
--- Ordered by priority rather than by whatever order the platform supplied, so
--- two connections by the same player produce the same statements and a diff of
--- the audit log stays readable.
---
---@param accountId string
---@param identifiers table<string, string>
---@return { accountId: string, kind: string, value: string }[]
function PlatformIdentity.rows(accountId, identifiers)
    local rows = {}
    for _, kind in ipairs(PlatformIdentity.PRIORITY) do
        if identifiers[kind] then
            rows[#rows + 1] = { accountId = accountId, kind = kind, value = identifiers[kind] }
        end
    end
    return rows
end

--- A redacted form safe to log.
---
--- An identifier is a stable handle to a real person. Logs are read by more
--- people than the database is, kept longer, and shipped to places nobody
--- audits, so the full value never goes into one.
---
---@param identifiers table<string, string>
---@return table<string, string>
function PlatformIdentity.redact(identifiers)
    local out = {}
    for kind, value in pairs(identifiers) do
        if #value <= 6 then
            out[kind] = ('*'):rep(#value)
        else
            out[kind] = value:sub(1, 3) .. ('*'):rep(#value - 6) .. value:sub(-3)
        end
    end
    return out
end

NxcCore.PlatformIdentity = PlatformIdentity
return PlatformIdentity
