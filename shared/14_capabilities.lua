--- Capability resolution across concurrent employments.
---
--- Authorization is always a capability check. Roles, grades, positions, and
--- organization memberships GRANT capabilities; gameplay logic never compares
--- rank name strings.
---
--- **A character may hold multiple concurrent employments** (R-217) — primary,
--- secondary, temporary contracts, business ownership, department membership,
--- certifications, volunteer roles. This module resolves capabilities across all
--- of them.
---
--- The rule that makes that safe: **grants union, denials win** (R-219). A
--- second job can only ever add capabilities, and an explicit denial from any
--- source cannot be silently overridden by a grant from another. Without the
--- second half, taking a temporary contract could quietly restore a capability
--- a department had deliberately revoked.

local Capabilities = {}

Capabilities.SOURCE = {
    ACCOUNT      = 'account',       -- framework-level, e.g. staff
    EMPLOYMENT   = 'employment',    -- a job or department role
    ORGANIZATION = 'organization',  -- membership rank
    BUSINESS     = 'business',      -- ownership or a business role
    CERTIFICATION = 'certification',
    TEMPORARY    = 'temporary',     -- a contract or shift-scoped grant
}

--- Resolve the effective capability set for an actor.
---
--- `grants` is a list of grant records, each naming its source so a later audit
--- can answer *which* employment authorized an action, not merely that the actor
--- held the capability.
---
---@param grants { source: string, sourceId?: string, allow?: string[], deny?: string[] }[]
---@return { effective: table<string, string>, denied: table<string, string> }
function Capabilities.resolve(grants)
    if type(grants) ~= 'table' then
        error('Capabilities.resolve requires a list of grants', 2)
    end

    local allowed, denied = {}, {}

    -- Denials are collected first so ordering cannot change the outcome. A
    -- resolution that depended on grant order would be a race waiting to happen
    -- when employments load asynchronously.
    for _, grant in ipairs(grants) do
        for _, cap in ipairs(grant.deny or {}) do
            denied[cap] = grant.source .. (grant.sourceId and (':' .. grant.sourceId) or '')
        end
    end

    for _, grant in ipairs(grants) do
        for _, cap in ipairs(grant.allow or {}) do
            if not denied[cap] and not allowed[cap] then
                allowed[cap] = grant.source .. (grant.sourceId and (':' .. grant.sourceId) or '')
            end
        end
    end

    return { effective = allowed, denied = denied }
end

--- Whether a resolved set holds a capability.
---
---@param resolved table
---@param capability string
---@return boolean
function Capabilities.has(resolved, capability)
    return resolved.effective[capability] ~= nil
end

--- Which source granted a capability.
---
--- Recorded in the audit trail, so a review can ask whether that grant was
--- appropriate rather than only whether the actor held it.
---
---@param resolved table
---@param capability string
---@return string|nil
function Capabilities.grantedBy(resolved, capability)
    return resolved.effective[capability]
end

--- Why a capability was denied, if it was explicitly denied.
---
--- Distinguishes "explicitly revoked" from "never granted", which are different
--- situations for an operator investigating a complaint.
---
---@param resolved table
---@param capability string
---@return string|nil
function Capabilities.deniedBy(resolved, capability)
    return resolved.denied[capability]
end

--- Check a capability, returning a Result.
---
---@param resolved table
---@param capability string
---@param correlationId string|nil
---@return NxcResult
function Capabilities.require(resolved, capability, correlationId)
    if Capabilities.has(resolved, capability) then
        return Nxc.Result.ok(Capabilities.grantedBy(resolved, capability))
    end
    return Nxc.Result.err(Nxc.Errors.forbidden(capability, correlationId))
end

--- Remove every grant originating from one source.
---
--- Used on termination. **Revocation must reach an offline player** (P5-07): a
--- terminated employee whose capabilities clear only at next login is still
--- authorized until they log in, so this operates on the stored grant list
--- rather than on a live session.
---
---@param grants table[]
---@param source string
---@param sourceId string|nil
---@return table[] remaining, integer removed
function Capabilities.revokeSource(grants, source, sourceId)
    local remaining, removed = {}, 0
    for _, grant in ipairs(grants) do
        local match = grant.source == source
            and (sourceId == nil or grant.sourceId == sourceId)
        if match then
            removed = removed + 1
        else
            remaining[#remaining + 1] = grant
        end
    end
    return remaining, removed
end

--- A sorted list of effective capabilities, for diagnostics.
---
---@param resolved table
---@return string[]
function Capabilities.list(resolved)
    local out = {}
    for cap in pairs(resolved.effective) do out[#out + 1] = cap end
    table.sort(out)
    return out
end

NxcCore.Capabilities = Capabilities
return Capabilities
