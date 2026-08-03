--- Registering nxc_core's configuration with nxc_config.
---
--- The consumer half of the handshake ADR-0013 describes. nxc_core starts
--- SECOND and nxc_config starts THIRD, so this resource is always up before the
--- service it registers with — which is exactly why registration is
--- event-driven rather than a startup dependency.
---
--- Two paths into the same place:
---
---   nxc_config announces readiness  → register
---   nxc_config restarts             → announces again → register again
---
--- Until either happens, nxc_core runs on its declared defaults. That is defined
--- behaviour rather than a fallback, because the defaults are part of the schema.

if not IsDuplicityVersion() then return end

local ConfigClient = {}

local registered = false

---@return boolean
function ConfigClient.isRegistered() return registered end

--- Register, and apply whatever comes back.
---
---@return boolean
function ConfigClient.register()
    if GetResourceState('nxc_config') ~= 'started' then return false end

    local ok, result = pcall(function()
        return exports.nxc_config:register(NxcCore.ConfigSchema.FIELDS)
    end)

    if not ok then
        Nxc.Logger.warn('config.registration_failed', {
            detail = tostring(result),
            effect = 'nxc_core continues on its declared defaults',
        })
        return false
    end

    if type(result) ~= 'table' or result.ok ~= true then
        local reason = 'unknown'
        if type(result) == 'table' and result.error then
            reason = tostring(result.error.code or result.error.message)
        end
        -- Error, not warn. A refused schema means every setting this resource
        -- has is unmanageable, and nothing else will say so.
        Nxc.Logger.error('config.registration_refused', {
            reason = reason,
            effect = 'nxc_core continues on its declared defaults; its settings cannot be changed',
        })
        return false
    end

    registered = true

    -- Apply what is in force. Config.apply validates each value against the
    -- field before accepting it — nxc_config is trusted to deliver values, not
    -- to have validated them, and the owner of a setting is the last line of
    -- defence for that setting.
    local applied = NxcCore.Config.apply(result.value.values or {})
    Nxc.Logger.info('config.registered', {
        fields = result.value.fieldCount,
        applied = applied.ok and #applied.value.applied or 0,
        rejected = applied.ok and #applied.value.rejected or 0,
    })

    if applied.ok and #applied.value.rejected > 0 then
        for _, rejection in ipairs(applied.value.rejected) do
            Nxc.Logger.warn('config.value_rejected', {
                field = rejection.field, reason = rejection.reason,
            })
        end
    end

    return true
end

AddEventHandler('nxc_config:server:ready', function()
    ConfigClient.register()
end)

--- Re-resolve when something we own changes.
---
--- The event carries KEYS, not values, so this asks for the values rather than
--- being handed them. That is what keeps sensitive configuration off the wire —
--- and it means a subscriber cannot act on a value it was not entitled to see.
AddEventHandler('nxc_config:server:changed', function(event)
    if type(event) ~= 'table' or event.resource ~= NxcCore.RESOURCE then return end

    local ok, values = pcall(function() return exports.nxc_config:effectiveValues({}) end)
    if not ok or type(values) ~= 'table' then
        Nxc.Logger.warn('config.reresolve_failed', { detail = tostring(values) })
        return
    end

    local applied = NxcCore.Config.apply(values)
    Nxc.Logger.info('config.changed', {
        publicationId = event.publicationId,
        keys = event.keys,
        applied = applied.ok and #applied.value.applied or 0,
    })
end)

--- The late-start case.
---
--- If nxc_config was already running when this resource started, its `ready`
--- announcement happened before anyone here was listening. Registering
--- unprompted covers that, and the service accepts registration at any time
--- precisely so it can.
CreateThread(function()
    Wait(2000)
    if not registered then ConfigClient.register() end
end)

NxcCore.ConfigClient = ConfigClient
return ConfigClient
