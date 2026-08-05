--- Service registration and discovery.
---
--- A consumer asks nxc_core for a service rather than calling a resource
--- blindly. The answer is one of: present and ready, present but not ready, or
--- absent.
---
--- ALL THREE ARE NORMAL. A consumer that treats "absent" as an error cannot
--- support optional dependencies, and optional dependencies are how the
--- platform degrades gracefully as later-phase resources arrive.

local Services = {}

Services.STATE = {
    REGISTERED  = 'registered',
    READY       = 'ready',
    DEGRADED    = 'degraded',
    FAILED      = 'failed',
}

local registry = {}

--- Register a service.
---
---@param spec { name: string, version: string, contractVersion: integer, capabilities?: string[] }
---@return NxcResult
function Services.register(spec)
    if type(spec) ~= 'table' then
        error('Services.register requires a spec', 2)
    end
    if type(spec.name) ~= 'string' or not spec.name:match('^[%a][%w_]*$') then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'name', reason = 'must be a resource name' } } }))
    end
    if type(spec.contractVersion) ~= 'number' or spec.contractVersion < 1 then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'contractVersion', reason = 'must be a positive integer' } } }))
    end
    if registry[spec.name] then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_SERVICE_ALREADY_REGISTERED',
            'That service is already registered.',
            { resource = NxcCore.RESOURCE, details = { name = spec.name } }))
    end

    local caps = {}
    for _, c in ipairs(spec.capabilities or {}) do caps[c] = true end

    registry[spec.name] = {
        name = spec.name,
        version = spec.version or '0.0.0',
        contractVersion = spec.contractVersion,
        capabilities = caps,
        state = Services.STATE.REGISTERED,
        registeredAt = Nxc.Time.nowMs(),
    }
    return Nxc.Result.ok(registry[spec.name])
end

--- Remove a service. Called when a resource stops.
---
--- Registrations are removed on stop and re-created on start. A stale
--- registration is worse than an absent one: a consumer discovers a service,
--- calls it, and gets nothing.
---
---@param name string
---@return boolean removed
function Services.unregister(name)
    if not registry[name] then return false end
    registry[name] = nil
    return true
end

---@param name string
---@param state string
---@return NxcResult
function Services.setState(name, state)
    local svc = registry[name]
    if not svc then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_SERVICE_NOT_FOUND', 'That service is not registered.',
            { resource = NxcCore.RESOURCE, details = { name = name } }))
    end
    local valid = false
    for _, s in pairs(Services.STATE) do
        if s == state then valid = true break end
    end
    if not valid then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'state', reason = 'unknown service state' } } }))
    end
    svc.state = state
    return Nxc.Result.ok(svc)
end

--- Discover a service.
---
--- Returns `present` false rather than an error when the service is absent,
--- because absence is a condition rather than a failure.
---
---@param name string
---@param minContractVersion integer|nil
---@return { present: boolean, ready: boolean, service: table|nil, reason: string|nil }
function Services.discover(name, minContractVersion)
    local svc = registry[name]
    if not svc then
        return { present = false, ready = false, service = nil, reason = 'not registered' }
    end
    if minContractVersion and svc.contractVersion < minContractVersion then
        return {
            present = true, ready = false, service = svc,
            reason = ('contract version %d is below the required %d')
                :format(svc.contractVersion, minContractVersion),
        }
    end
    local ready = svc.state == Services.STATE.READY
    -- Written as an if rather than `ready and nil or reason`: that idiom always
    -- yields the right-hand side, because nil is falsy. A ready service would
    -- have reported a reason.
    local reason
    if not ready then
        reason = 'state is ' .. svc.state
    end
    return {
        present = true,
        ready = ready,
        service = svc,
        reason = reason,
    }
end

---@param name string
---@param capability string
---@return boolean
function Services.supports(name, capability)
    local svc = registry[name]
    return svc ~= nil and svc.capabilities[capability] == true
end

--- All registered services, sorted, for diagnostics.
---
---@return table[]
function Services.all()
    local out = {}
    for _, svc in pairs(registry) do out[#out + 1] = svc end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- The worst state among a set of health reports.
---
--- **THE FRAMEWORK IS AS HEALTHY AS ITS UNHEALTHIEST PART.** One failed resource
--- means the framework is failed, whatever the other seven say. A summary that
--- averaged, or that reported the most common state, would read green with
--- sessions down.
---
--- `unknown` ranks ABOVE serviceable and BELOW starting. A resource that did not
--- answer is not evidence of health, and it is not evidence of failure either —
--- reporting it as either would be inventing a fact about a resource that said
--- nothing.
---
--- Pure, and separate from the export that uses it, because a ranking inlined in
--- a closure is a ranking nothing can test.
---
---@param reports table[]  each with a `state`
---@return string
function Services.worstOf(reports)
    local RANK = {
        serviceable = 0,
        unknown = 1,
        starting = 2,
        degraded = 3,
        failed = 4,
    }

    local worst = 'serviceable'
    for _, report in ipairs(reports or {}) do
        -- An unrecognised state ranks as unknown rather than being ignored.
        -- Ignoring it would let a resource hide by reporting nonsense.
        local rank = RANK[report.state] or RANK.unknown
        if rank > RANK[worst] then worst = RANK[report.state] and report.state or 'unknown' end
    end
    return worst
end

--- Test helper.
function Services.reset()
    registry = {}
end

NxcCore.Services = Services
return Services
