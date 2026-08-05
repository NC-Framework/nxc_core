--- Service registration, discovery, and framework health.
---
--- **BOTH MODULES WERE FINISHED, TESTED, AND REACHABLE BY NOBODY.** The Phase 1
--- gate failed on P1-03 and P1-04 with `nxc_lib/shared/health.lua` and
--- `nexus_core/shared/services.lua` complete and exported by no one. `Health.init`
--- had never been called by any resource, and exactly one service was ever
--- registered: nxc_core, by itself.
---
--- The same class as the two resources that shipped with no entry point. It is
--- worth naming why check-reachability did not catch this one: that check reports
--- exports nobody calls, and these were never exported at all, so there was
--- nothing for it to report. A check written for a defect covers that defect.
---
--- **A SERVICE IS NAMED BY WHO IS CALLING, NOT BY WHAT THEY PASS.** Every
--- registration is attributed with `GetInvokingResource()`, so no resource can
--- register, restate, or remove another's entry. The same rule as zones, targets,
--- and configuration fields.

if not IsDuplicityVersion() then return end

local Services = NxcCore.Services

--- Resources that have their own `health` export, discovered as they register.
---
--- Kept rather than probed: asking every started resource on the server whether
--- it answers to `health` means calling into resources that have nothing to do
--- with this framework.
local reporting = {}

-- ------------------------------------------------------------- registration

--- Register the calling resource as a service.
---
--- The name is taken from the caller. A spec may still carry `version`,
--- `contractVersion`, and `capabilities`, because only the resource itself knows
--- those.
---
---@param spec { version?: string, contractVersion?: integer, capabilities?: string[] }
---@return NxcResult
exports('registerService', function(spec)
    local resource = GetInvokingResource()
    if not resource then
        -- No caller means no owner, and an unowned registration can never be
        -- cleaned up when the resource that made it stops.
        return Nxc.plain(Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_UNKNOWN_CALLER', 'The calling resource could not be identified.',
            { resource = NxcCore.RESOURCE })))
    end

    spec = type(spec) == 'table' and spec or {}

    -- Re-registration is an update, not an error. A resource restart is ordinary,
    -- and refusing the second registration would leave the entry describing the
    -- version that stopped.
    Services.unregister(resource)

    local registered = Services.register({
        name = resource,
        version = spec.version,
        contractVersion = spec.contractVersion or 1,
        capabilities = spec.capabilities,
    })
    if not registered.ok then return Nxc.plain(registered) end

    reporting[resource] = spec.reportsHealth ~= false

    Nxc.Logger.info('services.registered', {
        service = resource,
        version = registered.value.version,
        contractVersion = registered.value.contractVersion,
    })
    return Nxc.plain(registered)
end)

--- Move the calling resource's service to a new state.
---
---@param state string  one of Services.STATE
---@return NxcResult
exports('setServiceState', function(state)
    local resource = GetInvokingResource()
    if not resource then
        return Nxc.plain(Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_UNKNOWN_CALLER', 'The calling resource could not be identified.',
            { resource = NxcCore.RESOURCE })))
    end
    return Nxc.plain(Services.setState(resource, state))
end)

--- A resource that stops loses its registration, whether or not it said so.
---
--- **CENTRAL RATHER THAN PER-RESOURCE.** A resource that crashes cannot
--- unregister itself, and a stale registration is worse than an absent one: a
--- consumer discovers the service, calls it, and gets nothing back.
AddEventHandler('onResourceStop', function(resource)
    if not Services.discover(resource).present then return end
    Services.unregister(resource)
    reporting[resource] = nil
    Nxc.Logger.info('services.unregistered', { service = resource, reason = 'resource stopped' })
end)

-- ---------------------------------------------------------------- discovery

--- Find a service.
---
--- **`present = false` IS A NORMAL ANSWER, NOT AN ERROR.** A consumer that treats
--- absence as a failure cannot support an optional dependency, and optional
--- dependencies are how the platform degrades as later-phase resources arrive.
---
---@param name string
---@param minContractVersion integer|nil
---@return { present: boolean, ready: boolean, service: table|nil, reason: string|nil }
exports('discover', function(name, minContractVersion)
    return Nxc.plain(Services.discover(name, minContractVersion))
end)

---@param name string
---@param capability string
---@return boolean
exports('serviceSupports', function(name, capability)
    return Services.supports(name, capability) and true or false
end)

--- Every registered service, sorted. For diagnostics.
---
---@return table[]
exports('services', function()
    return Nxc.plain(Services.all())
end)

-- ------------------------------------------------------------------- health

--- Ask one resource for its own health report.
---
--- **EACH RESOURCE HOLDS ITS OWN.** nxc_lib is loaded into every resource's Lua
--- state, so `Nxc.Health` inside nxc_zones tracks nxc_zones and nothing else.
--- There is no central health to read — it has to be collected.
---
--- Fails soft, deliberately. A resource that does not answer is reported as
--- unknown rather than breaking the report, because the report is what somebody
--- reads when things are already going wrong.
local function reportFor(name)
    -- nxc_core reads its own directly. It cannot call its own `health` export —
    -- that name is the aggregate below — and going through the export machinery
    -- to reach a table in this same state would be theatre.
    if name == NxcCore.RESOURCE then return Nxc.Health.report() end

    if not reporting[name] then
        return { resource = name, state = 'unknown', detail = 'does not report health' }
    end

    local ok, report = pcall(function() return exports[name]:health() end)
    if not ok or type(report) ~= 'table' or report.state == nil then
        return {
            resource = name,
            state = 'unknown',
            detail = ok and 'health export returned nothing usable'
                or 'health export raised an error',
        }
    end
    return report
end

--- The framework's health, resource by resource.
---
--- The `state` at the top is the worst of its parts: one failed resource means
--- the framework is failed, whatever the other seven say.
---
---@return table
exports('health', function()
    local resources = {}
    for _, service in ipairs(Services.all()) do
        local report = reportFor(service.name)
        report.serviceState = service.state
        resources[#resources + 1] = report
    end

    return Nxc.plain({
        state = Services.worstOf(resources),
        ready = NxcCore.Startup ~= nil and NxcCore.Startup.isReady() or false,
        checkedAt = Nxc.Time.nowMs(),
        resources = resources,
    })
end)

-- ------------------------------------------------------------------ console

--- `nxc_health` — what a server owner reads when something is wrong.
---
--- The gate check is "resource health CAN BE QUERIED". An export that only
--- another resource can call does not satisfy that on its own: the person who
--- needs the answer at three in the morning is at a console.
RegisterCommand('nxc_health', function(source)
    if source ~= 0 then return end

    local report = exports[NxcCore.RESOURCE]:health()
    local COLOUR = {
        serviceable = '^2', degraded = '^3', starting = '^3', failed = '^1', unknown = '^8',
    }

    print(('^5[nxc_core]^7 framework health: %s%s^7')
        :format(COLOUR[report.state] or '^7', report.state))

    if #report.resources == 0 then
        -- An empty list is a real answer and looks identical to a broken command,
        -- so it says which it is.
        print('  nothing registered — no resource has called nxc_core:registerService')
        return
    end

    for _, entry in ipairs(report.resources) do
        print(('  %s%-14s %-12s^7 %s'):format(
            COLOUR[entry.state] or '^7',
            entry.resource,
            entry.state,
            entry.detail or ''))

        for _, dep in ipairs(entry.dependencies or {}) do
            if not dep.satisfied then
                print(('      ^3missing %s%s^7'):format(
                    dep.name, dep.optional and ' (optional)' or ''))
            end
        end
    end
end, true)
