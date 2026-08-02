--- Runtime configuration values for `nxc_core`.
---
--- The schema in `20_config_schema.lua` declares what is configurable. This
--- module holds what the values currently ARE, and is what framework code reads.
---
--- Three properties matter:
---
---   1. **There is always a value.** Before `nxc_config` has published anything,
---      `get` returns the declared default. Startup order therefore never
---      produces a nil setting, and no caller needs a fallback of its own —
---      which is how two different fallbacks for the same setting appear.
---
---   2. **An unknown key is an error, not nil.** A typo returning nil turns into
---      a silent behaviour change somewhere far away. It raises here instead.
---
---   3. **A published value is validated against its field before it is
---      accepted.** `nxc_config` is trusted to deliver values, not to have
---      validated them; the owner of a setting is the last line of defence for
---      that setting.

local Config = {}

local values = {}

--- Current value of a setting.
---
--- Returns the published value if one exists, otherwise the declared default.
---
---@param key string
---@return any
function Config.get(key)
    local field = NxcCore.ConfigSchema.field(key)
    if not field then
        error(('unknown configuration key: %s'):format(tostring(key)), 2)
    end
    local current = values[key]
    if current == nil then return field.default end
    return current
end

--- Apply values published by the configuration service.
---
--- Every value is checked against its field. A rejected value leaves the
--- previous one in place: a bad edit must not knock a running setting out, and
--- silently falling back to the default would be a change the operator did not
--- ask for.
---
--- Returns which keys were applied and which were rejected, so the caller can
--- report both. Partial application is deliberate — one bad field should not
--- discard five good ones.
---
---@param published table<string, any>
---@return NxcResult
function Config.apply(published)
    if type(published) ~= 'table' then
        error('Config.apply requires a table of values', 2)
    end

    local applied, rejected = {}, {}

    for key, value in pairs(published) do
        local field = NxcCore.ConfigSchema.field(key)
        if not field then
            rejected[#rejected + 1] = { field = key, reason = 'is not a nxc_core setting' }
        else
            local ok, reason = NxcCore.ConfigSchema.checkValue(field, value)
            if not ok then
                rejected[#rejected + 1] = { field = key, reason = reason }
            else
                local previous = values[key]
                values[key] = value
                applied[#applied + 1] = {
                    field = key,
                    from = previous == nil and field.default or previous,
                    to = value,
                    -- The caller needs this to tell the operator whether the
                    -- change has taken effect or is waiting on a restart.
                    reloadBehavior = field.reloadBehavior,
                }
            end
        end
    end

    -- Sorted so the report is stable: pairs() order varies between runs, and an
    -- audit record that reorders itself is hard to diff.
    table.sort(applied, function(a, b) return a.field < b.field end)
    table.sort(rejected, function(a, b) return a.field < b.field end)

    return Nxc.Result.ok({ applied = applied, rejected = rejected })
end

--- Every current value, published or defaulted.
---
--- Sensitive fields would be redacted here. `nxc_core` declares none, and the
--- redaction is written anyway so that adding one cannot leak it through the
--- health surface by omission.
---
---@return table<string, any>
function Config.snapshot()
    local out = {}
    for _, field in ipairs(NxcCore.ConfigSchema.FIELDS) do
        if field.sensitive then
            out[field.key] = '[redacted]'
        else
            out[field.key] = Config.get(field.key)
        end
    end
    return out
end

--- Discard published values and return to declared defaults.
---
--- For tests, and for a configuration service that has gone away: running on
--- defaults is defined behaviour, running on values published by a service that
--- is no longer there is not.
function Config.reset()
    values = {}
end

NxcCore.Config = Config
return Config
