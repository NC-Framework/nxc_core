--- Environment bootstrap validation.
---
--- Runs at startup, before anything else. Identifies a missing or malformed
--- bootstrap value and fails with a STRUCTURED error naming what is wrong.
---
--- The alternative — starting successfully and failing later at an unrelated
--- point — turns a five-second diagnosis into an hour of confusion. Gate check
--- P1-02 requires the structured failure specifically.
---
--- Convar reading is injected, so this is testable without the FiveM runtime.

local Bootstrap = {}

Bootstrap.MODES = { normal = true, recovery = true }
Bootstrap.ENVIRONMENTS = { development = true, staging = true, production = true }

--- Bootstrap values, and only bootstrap values.
---
--- Everything operational is registered with nxc_config and edited in game. The
--- test for belonging here: could an operator safely change this on a running
--- server? If yes, it is operational and does not belong.
Bootstrap.REQUIRED = {
    {
        convar = 'mysql_connection_string',
        description = 'Database connection. Supplied by the operator in server.cfg.',
        secret = true,
        validate = function(v)
            if not v:match('^mysql://') and not v:match('=') then
                return false, 'must be a mysql:// URI or a key=value connection string'
            end
            if v:match('<%u+>') then
                return false, 'still contains a placeholder; the operator has not filled it in'
            end
            return true
        end,
    },
    {
        convar = 'nxc_environment',
        description = 'Environment identity: development, staging, or production.',
        secret = false,
        validate = function(v)
            if not Bootstrap.ENVIRONMENTS[v] then
                return false, 'must be development, staging, or production'
            end
            return true
        end,
    },
    {
        convar = 'nxc_token_signing_key',
        description = 'Signing key for session and NUI tokens. Unique per environment.',
        secret = true,
        validate = function(v)
            if #v < 32 then
                return false, 'must be at least 32 characters'
            end
            return true
        end,
    },
    {
        convar = 'nxc_server_build',
        description = 'The exact Cfx Server build this deployment runs. Set in server.cfg.',
        secret = false,
        -- Required by MDD v0.4 section 38.2: every deployment records its build,
        -- so a platform regression can be attributed to a specific update rather
        -- than to whatever changed most recently. Enhanced is early access, so
        -- this is a matter of when.
        --
        -- Required rather than optional. A value that is optional is a value
        -- that is empty on the one server where it matters.
        validate = function(v)
            if v:match('^<.*>$') or v == 'UNPINNED' then
                return false, 'is still a placeholder; the operator has not filled it in'
            end
            -- WHAT THIS DOES NOT CHECK: whether the build is an Enhanced build.
            -- A build number does not carry its edition, and inventing a range
            -- to test against would be a fabricated fact that fails closed on
            -- correct input. Recording the build is the requirement; verifying
            -- the edition is the operator's, and P1-E02's.
            if not v:match('%d') then
                return false, 'must contain the server build, not a description'
            end
            return true
        end,
    },
}

Bootstrap.OPTIONAL = {
    {
        convar = 'nxc_startup_mode',
        default = 'normal',
        validate = function(v)
            if not Bootstrap.MODES[v] then return false, 'must be normal or recovery' end
            return true
        end,
    },
    {
        convar = 'nxc_log_level',
        default = 'info',
        validate = function(v)
            if not Nxc.Logger.LEVELS[v] then return false, 'unknown log level' end
            return true
        end,
    },
    {
        convar = 'nxc_dev_mode',
        default = 'false',
        validate = function(v)
            if v ~= 'true' and v ~= 'false' then return false, 'must be true or false' end
            return true
        end,
    },
}

--- Validate the bootstrap environment.
---
--- `getConvar(name, default)` is injected. Returns a Result whose value is the
--- resolved settings, or a structured error listing every problem — not just
--- the first, because an operator fixing one at a time is an operator restarting
--- five times.
---
---@param getConvar fun(name: string, default: string): string
---@return NxcResult
function Bootstrap.validate(getConvar)
    if type(getConvar) ~= 'function' then
        error('Bootstrap.validate requires a convar getter', 2)
    end

    local problems, settings = {}, {}

    for _, spec in ipairs(Bootstrap.REQUIRED) do
        local value = getConvar(spec.convar, '')
        if type(value) ~= 'string' or value == '' then
            problems[#problems + 1] = {
                field = spec.convar,
                reason = 'is required and is not set. ' .. spec.description,
            }
        else
            local ok, reason = spec.validate(value)
            if not ok then
                problems[#problems + 1] = { field = spec.convar, reason = reason }
            else
                -- A secret is recorded as present, never by value. Settings are
                -- logged and reported by the health surface.
                settings[spec.convar] = spec.secret and true or value
            end
        end
    end

    for _, spec in ipairs(Bootstrap.OPTIONAL) do
        local value = getConvar(spec.convar, spec.default)
        if value == nil or value == '' then value = spec.default end
        local ok, reason = spec.validate(value)
        if not ok then
            problems[#problems + 1] = { field = spec.convar, reason = reason }
        else
            settings[spec.convar] = value
        end
    end

    -- Development diagnostics expose internal state. A production server with
    -- them enabled is an information-disclosure vulnerability, so this is a
    -- startup failure rather than a warning.
    if settings.nxc_environment == 'production' and settings.nxc_dev_mode == 'true' then
        problems[#problems + 1] = {
            field = 'nxc_dev_mode',
            reason = 'must be false in production: development diagnostics expose internal state',
        }
    end

    if settings.nxc_environment == 'production' and settings.nxc_log_level == 'debug' then
        problems[#problems + 1] = {
            field = 'nxc_log_level',
            reason = 'debug logging is not permitted in production',
        }
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_BOOTSTRAP_INVALID',
            'The server is not configured correctly and cannot start.',
            { resource = NxcCore.RESOURCE, details = { fields = problems } }))
    end

    return Nxc.Result.ok(settings)
end

--- A human-readable report of a bootstrap failure, for the server console.
---
--- An operator reading a startup failure needs to know which value, and what is
--- wrong with it, without consulting documentation.
---
---@param err NxcError
---@return string
function Bootstrap.explain(err)
    local lines = { 'Nexus Core cannot start. The following must be corrected in server.cfg:', '' }
    local anyMissing = false
    for _, p in ipairs((err.details and err.details.fields) or {}) do
        lines[#lines + 1] = ('  %-28s %s'):format(p.field, p.reason)
        if p.reason:find('is required and is not set') then anyMissing = true end
    end

    -- The most common cause of "set, but the server disagrees", and one the
    -- framework cannot see: server.cfg runs top to bottom and the LAST `set`
    -- wins, so a blank line further down silently overrides a filled-in one
    -- above it. GetConvar returns only the resolved value, so this is invisible
    -- from here and has to be guessed at in the message instead.
    if anyMissing then
        lines[#lines + 1] = ''
        lines[#lines + 1] = '  If you believe one of these IS set, check for a SECOND `set` of the'
        lines[#lines + 1] = '  same name further down server.cfg. The file runs top to bottom and the'
        lines[#lines + 1] = '  last one wins, so a blank line below silently overrides your value.'
        lines[#lines + 1] = '  Re-running the deployment recipe is a common way to acquire one.'
    end
    return table.concat(lines, '\n')
end

NxcCore.Bootstrap = Bootstrap
return Bootstrap
