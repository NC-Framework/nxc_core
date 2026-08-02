--- State bag policy and validation.
---
--- **Every state bag is client-visible.** Registering one is a disclosure
--- decision, not a storage choice.
---
--- A state bag is a REPLICATION mechanism, not a STORAGE mechanism. Authoritative
--- state lives in the owning domain's database; a bag may mirror a derived,
--- non-sensitive fact so clients can read it cheaply. If the bag were lost on
--- restart, nothing authoritative should be lost.
---
--- That test resolves most arguments: if losing it matters, it does not belong
--- in a bag.

local StateBags = {}

local KEY_PATTERN = '^nxc%.[%l][%l%d]*%.[%l][%l%d]*$'

--- Values that must never appear in a state bag, whatever a caller argues.
---
--- Matched against the key's leaf segment. This list is deliberately blunt: the
--- cost of a false positive is a rejected registration and a conversation; the
--- cost of a false negative is a permanent client-visible disclosure.
StateBags.FORBIDDEN_LEAVES = {
    'balance', 'balances', 'money', 'cash', 'bank', 'funds',
    'inventory', 'items', 'stash', 'contents',
    'capabilities', 'permissions', 'grants',
    'token', 'secret', 'key', 'password',
    'ssn', 'medical', 'diagnosis', 'criminal', 'charges',
}

StateBags.ATTACHMENT = { PLAYER = 'player', ENTITY = 'entity', GLOBAL = 'global' }

local registry = {}

local function forbiddenLeaf(key)
    local leaf = key:match('([^.]+)$')
    if not leaf then return nil end
    for _, bad in ipairs(StateBags.FORBIDDEN_LEAVES) do
        if leaf == bad then return bad end
    end
    return nil
end

--- Register a state bag key.
---
---@param spec { key: string, owner: string, attachment: string, type: string, description: string, maxBytes?: integer }
---@return NxcResult
function StateBags.register(spec)
    if type(spec) ~= 'table' then
        error('StateBags.register requires a spec', 2)
    end

    local problems = {}

    if type(spec.key) ~= 'string' or not spec.key:match(KEY_PATTERN) then
        problems[#problems + 1] =
            { field = 'key', reason = 'must be nxc.<domain>.<key> in lowercase' }
    else
        local bad = forbiddenLeaf(spec.key)
        if bad then
            problems[#problems + 1] = {
                field = 'key',
                reason = ('"%s" must never be in a state bag: every bag is client-visible'):format(bad),
            }
        end
    end

    if type(spec.owner) ~= 'string' or spec.owner == '' then
        problems[#problems + 1] = { field = 'owner', reason = 'is required' }
    end

    local attachmentValid = false
    for _, a in pairs(StateBags.ATTACHMENT) do
        if spec.attachment == a then attachmentValid = true break end
    end
    if not attachmentValid then
        problems[#problems + 1] =
            { field = 'attachment', reason = 'must be player, entity, or global' }
    end

    -- Only small scalars belong in a bag. A table replicates its whole contents
    -- on every change, to every client in scope.
    if spec.type ~= 'string' and spec.type ~= 'number' and spec.type ~= 'boolean' then
        problems[#problems + 1] = {
            field = 'type',
            reason = 'must be string, number, or boolean; a bag carries small scalars',
        }
    end

    if type(spec.description) ~= 'string' or spec.description == '' then
        problems[#problems + 1] = {
            field = 'description',
            reason = 'is required: a bag is a public contract and a disclosure decision',
        }
    end

    if spec.key and registry[spec.key] then
        problems[#problems + 1] = { field = 'key', reason = 'is already registered' }
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end

    registry[spec.key] = Nxc.freeze({
        key = spec.key,
        owner = spec.owner,
        attachment = spec.attachment,
        type = spec.type,
        description = spec.description,
        maxBytes = spec.maxBytes or 256,
    })
    return Nxc.Result.ok(registry[spec.key])
end

--- Validate a write against a registered key.
---
--- **Server writes, clients read.** A client-writable bag is an unauthenticated
--- write primitive, so this is called on the server before any write; there is
--- no client-side path that reaches it.
---
---@param key string
---@param value any
---@return NxcResult
function StateBags.validateWrite(key, value)
    local spec = registry[key]
    if not spec then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_STATE_BAG_UNREGISTERED',
            'That state bag is not registered.',
            { resource = NxcCore.RESOURCE, details = { key = key } }))
    end

    if type(value) ~= spec.type then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = { {
            field = key,
            reason = ('must be a %s, got %s'):format(spec.type, type(value)),
        } } }))
    end

    if spec.type == 'string' and #value > spec.maxBytes then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = { {
            field = key,
            reason = ('exceeds %d bytes; a bag replicates on every change'):format(spec.maxBytes),
        } } }))
    end

    return Nxc.Result.ok(value)
end

---@param key string
---@return table|nil
function StateBags.get(key)
    return registry[key]
end

--- Every registered key, sorted, for diagnostics and the contract registry.
---
---@return table[]
function StateBags.all()
    local out = {}
    for _, spec in pairs(registry) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- Remove every key owned by a resource. Called when that resource stops.
---
---@param owner string
---@return integer removed
function StateBags.unregisterOwner(owner)
    local removed = 0
    for key, spec in pairs(registry) do
        if spec.owner == owner then
            registry[key] = nil
            removed = removed + 1
        end
    end
    return removed
end

--- Test helper.
function StateBags.reset()
    registry = {}
end

NxcCore.StateBags = StateBags
return StateBags
