--- Session and NUI token signing key.
---
--- **Generated at startup and rotated by restarting** (OD-005). The operator
--- supplies nothing, which removes a whole class of deployment failure: a blank
--- key, a key duplicated into two `set` lines, a key committed to a repository,
--- a key copied between environments because it was easier than making a new one.
---
--- **Restarting invalidates every live session, and that is the intended
--- behaviour** rather than a side effect. A session token outliving the server
--- that issued it is a token nobody can revoke.
---
--- An operator may still pin a key by setting `nxc_token_signing_key`. That is
--- for the case this design does not cover — more than one server instance
--- sharing sessions — and it is not the default, because a value that must be
--- set is a value that will be set badly.
---
--- Key generation itself is injected, so the policy is testable and the entropy
--- source is not.

local Tokens = {}

Tokens.MIN_LENGTH = 32

local signingKey = nil
local source = nil

--- Decide the key from an operator-supplied value and a generator.
---
--- Pure, and returns the decision rather than applying it, so every branch is
--- testable: supplied and good, supplied and too short, absent, generator
--- failing.
---
---@param supplied string|nil
---@param generate fun(): string|nil, string|nil
---@return NxcResult
function Tokens.decide(supplied, generate)
    if type(supplied) == 'string' and supplied ~= '' then
        if #supplied < Tokens.MIN_LENGTH then
            -- Refused rather than silently replaced by a generated one. An
            -- operator who set a key meant to control it, and quietly ignoring
            -- them would make a multi-instance deployment fail in a way that
            -- looks like anything but this.
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CORE_SIGNING_KEY_TOO_SHORT',
                'The configured token signing key is too short.',
                {
                    resource = NxcCore.RESOURCE,
                    details = {
                        fields = { {
                            field = 'nxc_token_signing_key',
                            reason = ('must be at least %d characters, or unset to have one '
                                  .. 'generated at startup'):format(Tokens.MIN_LENGTH),
                        } },
                    },
                }))
        end
        return Nxc.Result.ok({ key = supplied, source = 'operator' })
    end

    local generated, err = generate()
    if not generated or #generated < Tokens.MIN_LENGTH then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_SIGNING_KEY_UNAVAILABLE',
            'A token signing key could not be generated.',
            { resource = NxcCore.RESOURCE, details = { reason = err or 'generator returned too few characters' } }))
    end
    return Nxc.Result.ok({ key = generated, source = 'generated' })
end

--- Install the key for this run.
---
---@param key string
---@param origin string
function Tokens.install(key, origin)
    signingKey = key
    source = origin
end

--- The key, for signing and verification only.
---
--- Raises rather than returning nil: a caller that signs with nil produces a
--- token anyone can forge, and would not notice.
---
---@return string
function Tokens.key()
    if not signingKey then
        error('the token signing key has not been installed; nxc_core is not ready', 2)
    end
    return signingKey
end

--- Where the key came from, for the health surface. Never the key itself.
---
---@return string|nil
function Tokens.source()
    return source
end

---@return boolean
function Tokens.isReady()
    return signingKey ~= nil
end

--- Test helper.
function Tokens.reset()
    signingKey, source = nil, nil
end

NxcCore.Tokens = Tokens
return Tokens
