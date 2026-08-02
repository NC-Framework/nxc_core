--- Configuration schema for `nxc_core`.
---
--- Every Nexus Core resource registers its operational configuration through
--- `nxc_config` and exposes a permission-controlled in-game management surface.
--- That is a condition of acceptance, not a quality goal.
---
--- **What belongs here is the mirror image of what belongs in bootstrap.**
--- `11_bootstrap.lua` holds values an operator could not safely change on a
--- running server: the database connection, the environment identity, the token
--- signing key. Everything an operator *could* safely change while players are
--- connected belongs here and is edited in game.
---
--- **Every field below is read by code that exists.** A configuration surface
--- that offers a setting nothing consults is worse than no setting: the operator
--- changes it, observes no effect, and stops trusting the whole panel. So there
--- is no job limit here, because nothing enforces one; no query timeout, because
--- the provider does not implement one; and no routing bucket range, because
--- those are protocol constants that resources agree on rather than operator
--- preferences.
---
--- The schema is **pure data** and the registration function takes an injected
--- registrar, so both are testable without the FiveM runtime and without
--- `nxc_config` existing.

local ConfigSchema = {}

--- Every field declares all fourteen required properties.
ConfigSchema.FIELDS = {
    {
        key = 'nxc_core.characters.maxPerAccount',
        type = 'integer',
        description =
            'How many characters one account may hold. An account is one real person; a character '
            .. 'is one persona.',
        default = 5,
        validation = { min = 1, max = 20 },
        scope = { 'global', 'environment' },
        clientVisible = true,
        editCapability = 'config.resource.publish',
        auditClassification = 'operational',
        sensitive = false,
        -- Read when a character is created, so a change applies to the next
        -- creation attempt. Lowering it never deletes anything: an account
        -- already over the new limit keeps its characters and cannot add more.
        reloadBehavior = 'Immediate',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:characterPolicyChanged',
    },
    {
        key = 'nxc_core.characters.allowLiveSwitch',
        type = 'boolean',
        description =
            'Whether a player may switch characters without reconnecting. Disabled, a switch '
            .. 'requires a reconnect.',
        default = true,
        validation = {},
        scope = { 'global', 'environment' },
        clientVisible = true,
        editCapability = 'config.resource.publish',
        auditClassification = 'operational',
        sensitive = false,
        -- Checked at the moment a switch is requested. Turning it off does not
        -- disturb a switch already in progress.
        reloadBehavior = 'Immediate',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:characterPolicyChanged',
    },
    {
        key = 'nxc_core.session.reconnectGraceMs',
        type = 'integer',
        description =
            'How long after a disconnect a returning player is put straight back on their previous '
            .. 'character instead of the selection screen. Zero always returns them to selection.',
        default = 300000,
        validation = { min = 0, max = 1800000 },
        scope = { 'global', 'environment' },
        clientVisible = false,
        editCapability = 'config.resource.edit',
        auditClassification = 'operational',
        sensitive = false,
        -- Read when a reconnect plan is built, which is once per connection.
        reloadBehavior = 'Immediate',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:sessionPolicyChanged',
    },
    {
        key = 'nxc_core.connection.whitelistRequired',
        type = 'boolean',
        description = 'Whether a connecting account must be whitelisted before it may join.',
        default = false,
        validation = {},
        scope = { 'global', 'environment' },
        clientVisible = false,
        editCapability = 'config.resource.publish',
        -- Turning a whitelist on or off changes who may enter the server, so
        -- the change belongs in the security audit trail rather than the
        -- operational one.
        auditClassification = 'security',
        sensitive = false,
        -- Evaluated per connection. Enabling it does not remove players who are
        -- already connected; that is a moderation action, not a config change.
        reloadBehavior = 'Immediate',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:connectionPolicyChanged',
    },
    {
        key = 'nxc_core.migrations.applyOnStart',
        type = 'boolean',
        description =
            'Whether pending database migrations are applied automatically at startup. Disabled, '
            .. 'the server reports what is pending and refuses to start until they are applied.',
        default = true,
        validation = {},
        scope = { 'global', 'environment' },
        clientVisible = false,
        editCapability = 'config.resource.publish',
        auditClassification = 'security',
        sensitive = false,
        -- Migrations run once, during startup. Changing this mid-session cannot
        -- retroactively apply or unapply anything, and claiming otherwise in the
        -- admin panel would be a lie.
        reloadBehavior = 'Resource Restart Required',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:migrationPolicyChanged',
    },
    {
        key = 'nxc_core.startup.banner',
        type = 'boolean',
        description = 'Whether the Nexus Core banner is printed to the server console at startup.',
        default = true,
        validation = {},
        scope = { 'global', 'environment' },
        clientVisible = false,
        editCapability = 'config.resource.edit',
        auditClassification = 'operational',
        sensitive = false,
        -- Printed once, during startup. Changing it later cannot un-print
        -- anything, and claiming otherwise in the admin panel would be a lie.
        reloadBehavior = 'Resource Restart Required',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:startupPolicyChanged',
    },
    {
        key = 'nxc_core.logging.level',
        type = 'string',
        description =
            'Minimum severity written to the log by nxc_core. Overrides the nxc_log_level '
            .. 'bootstrap value once configuration is available.',
        default = 'info',
        validation = { oneOf = { 'debug', 'info', 'warn', 'error', 'fatal' } },
        scope = { 'global', 'environment', 'resource' },
        clientVisible = false,
        editCapability = 'config.resource.edit',
        auditClassification = 'operational',
        sensitive = false,
        reloadBehavior = 'Immediate',
        migrationBehavior = 'retain',
        rollbackBehavior = 'restore',
        changeEvent = 'nxc_core:server:logLevelChanged',
    },
}

local REQUIRED_PROPERTIES = {
    'key', 'type', 'description', 'default', 'validation', 'scope', 'clientVisible',
    'editCapability', 'auditClassification', 'sensitive', 'reloadBehavior',
    'migrationBehavior', 'rollbackBehavior', 'changeEvent',
}

local RELOAD_BEHAVIORS = {
    ['Immediate'] = true,
    ['Next Interaction'] = true,
    ['Next Session'] = true,
    ['Resource Restart Required'] = true,
    ['Server Restart Required'] = true,
}

--- Validate the schema itself.
---
--- Run before registration, so a malformed field produces one clear failure
--- rather than a partial registration discovered later.
---
---@return NxcResult
function ConfigSchema.validate()
    local problems, seen = {}, {}

    for _, field in ipairs(ConfigSchema.FIELDS) do
        local key = field.key or '(no key)'

        for _, prop in ipairs(REQUIRED_PROPERTIES) do
            if field[prop] == nil then
                problems[#problems + 1] = { field = key, reason = 'missing property: ' .. prop }
            end
        end

        if field.key then
            if not field.key:match('^nxc_core%.[%a][%w]*%.[%a][%w]*$') then
                problems[#problems + 1] =
                    { field = key, reason = 'key must be nxc_core.<group>.<key>' }
            end
            -- A duplicate key silently shadows its twin: whichever loses is
            -- editable in the panel and read by nothing.
            if seen[field.key] then
                problems[#problems + 1] = { field = key, reason = 'duplicate key' }
            end
            seen[field.key] = true
        end

        if field.reloadBehavior and not RELOAD_BEHAVIORS[field.reloadBehavior] then
            problems[#problems + 1] = { field = key,
                reason = 'unknown reload behavior: ' .. tostring(field.reloadBehavior) }
        end

        -- A sensitive value must never be client-visible, whatever its scope
        -- resolution would otherwise permit.
        if field.sensitive == true and field.clientVisible == true then
            problems[#problems + 1] =
                { field = key, reason = 'a sensitive field cannot be client-visible' }
        end

        -- The declared default must itself satisfy the declared validation.
        -- Otherwise a fresh server starts on a value the panel would reject.
        if field.default ~= nil and field.validation ~= nil then
            local ok, reason = ConfigSchema.checkValue(field, field.default)
            if not ok then
                problems[#problems + 1] =
                    { field = key, reason = 'the declared default is invalid: ' .. reason }
            end
        end
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end
    return Nxc.Result.ok(ConfigSchema.FIELDS)
end

--- Check one value against one field's declared type and validation.
---
--- Used by the schema's own self-check and by the runtime holder, so a value
--- accepted at registration and a value accepted at edit time are judged by
--- exactly the same rules.
---
---@param field table
---@param value any
---@return boolean, string|nil
function ConfigSchema.checkValue(field, value)
    local expected = field.type
    local actual = type(value)

    if expected == 'integer' then
        if actual ~= 'number' or value ~= math.floor(value) then
            return false, 'must be a whole number'
        end
    elseif expected == 'number' then
        if actual ~= 'number' then return false, 'must be a number' end
    elseif actual ~= expected then
        return false, 'must be a ' .. expected
    end

    local rules = field.validation or {}

    if rules.min and value < rules.min then
        return false, ('must be at least %s'):format(rules.min)
    end
    if rules.max and value > rules.max then
        return false, ('must be at most %s'):format(rules.max)
    end
    if rules.pattern and not tostring(value):match(rules.pattern) then
        return false, 'is not in the expected format'
    end
    if rules.oneOf then
        for _, allowed in ipairs(rules.oneOf) do
            if value == allowed then return true end
        end
        return false, 'must be one of: ' .. table.concat(rules.oneOf, ', ')
    end

    return true
end

--- Look up a field by key.
---
---@param key string
---@return table|nil
function ConfigSchema.field(key)
    for _, field in ipairs(ConfigSchema.FIELDS) do
        if field.key == key then return field end
    end
    return nil
end

--- Declared defaults, used before registration completes.
---
--- `nxc_core` loads before `nxc_config`, so between startup and the registration
--- handshake it runs on these. They are part of the schema, which makes this
--- defined behaviour rather than a fallback.
---
---@return table<string, any>
function ConfigSchema.defaults()
    local out = {}
    for _, field in ipairs(ConfigSchema.FIELDS) do
        out[field.key] = field.default
    end
    return out
end

--- Register the schema with a configuration service.
---
--- The registrar is injected rather than looked up, so this is testable without
--- `nxc_config` existing and without the FiveM runtime. Registration is an
--- event-driven handshake, not a startup dependency: `nxc_config` announces
--- readiness and each resource registers then.
---
---@param registrar fun(resource: string, fields: table): boolean
---@return NxcResult
function ConfigSchema.register(registrar)
    if type(registrar) ~= 'function' then
        error('ConfigSchema.register requires a registrar function', 2)
    end

    local valid = ConfigSchema.validate()
    if not valid.ok then return valid end

    local ok, accepted = pcall(registrar, NxcCore.RESOURCE, ConfigSchema.FIELDS)
    if not ok then
        return Nxc.Result.err(Nxc.Errors.new(
            Nxc.Errors.CODES.INTERNAL,
            'Configuration registration failed.',
            { resource = NxcCore.RESOURCE, details = { reason = tostring(accepted) } }))
    end
    if accepted ~= true then
        return Nxc.Result.err(Nxc.Errors.new(
            Nxc.Errors.CODES.INTERNAL,
            'Configuration registration was refused.',
            { resource = NxcCore.RESOURCE, details = { resource = NxcCore.RESOURCE } }))
    end

    return Nxc.Result.ok(true)
end

NxcCore.ConfigSchema = ConfigSchema
return ConfigSchema
