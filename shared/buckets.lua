--- Routing bucket allocation.
---
--- **nxc_core owns allocation.** It is the only resource that assigns bucket
--- identifiers. Resources REQUEST a bucket and receive an id; they never pick
--- one.
---
--- Two resources choosing the same number is exactly the accidental-instance
--- failure the design names as an existing production problem.

local Buckets = {}

Buckets.SHARED_WORLD = 0
Buckets.RESERVED_MAX = 999
Buckets.DYNAMIC_MIN = 1000
Buckets.DYNAMIC_MAX = 99999

local allocated = {}   -- id -> record
local nextId = Buckets.DYNAMIC_MIN

--- Allocate a bucket.
---
---@param opts { owner: string, purpose: string, hold?: boolean }
---@return NxcResult
function Buckets.allocate(opts)
    if type(opts) ~= 'table' or type(opts.owner) ~= 'string' or opts.owner == '' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'owner', reason = 'is required' } } }))
    end
    if type(opts.purpose) ~= 'string' or opts.purpose == '' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'purpose', reason = 'is required' } } }))
    end

    -- Scan for a free id rather than reusing the counter blindly. A wrapped
    -- counter must not hand out an id that is still occupied.
    local start = nextId
    local id
    repeat
        if not allocated[nextId] then id = nextId end
        nextId = nextId + 1
        if nextId > Buckets.DYNAMIC_MAX then nextId = Buckets.DYNAMIC_MIN end
        if id then break end
    until nextId == start

    if not id then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_BUCKETS_EXHAUSTED', 'No routing bucket is available.',
            { resource = NxcCore.RESOURCE }))
    end

    allocated[id] = {
        id = id,
        owner = opts.owner,
        purpose = opts.purpose,
        occupants = {},
        held = opts.hold == true,
        createdAt = Nxc.Time.nowMs(),
    }
    return Nxc.Result.ok(allocated[id])
end

---@param id integer
---@return table|nil
function Buckets.get(id)
    return allocated[id]
end

--- Add an occupant.
---
---@param id integer
---@param occupant any
---@return NxcResult
function Buckets.enter(id, occupant)
    local b = allocated[id]
    if not b then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_BUCKET_NOT_FOUND', 'That routing bucket does not exist.',
            { resource = NxcCore.RESOURCE, details = { bucket = id } }))
    end
    b.occupants[tostring(occupant)] = true
    return Nxc.Result.ok(b)
end

--- Remove an occupant, releasing the bucket when it is empty and unheld.
---
--- Returns whether the bucket was released, because the caller needs to know
--- whether entities in it must be resolved.
---
---@param id integer
---@param occupant any
---@return NxcResult
function Buckets.leave(id, occupant)
    local b = allocated[id]
    if not b then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_BUCKET_NOT_FOUND', 'That routing bucket does not exist.',
            { resource = NxcCore.RESOURCE, details = { bucket = id } }))
    end
    b.occupants[tostring(occupant)] = nil

    local empty = next(b.occupants) == nil
    if empty and not b.held then
        allocated[id] = nil
        return Nxc.Result.ok({ released = true, bucket = id })
    end
    return Nxc.Result.ok({ released = false, bucket = id })
end

--- Hold a bucket open even when empty, or release the hold.
---
--- A hold is explicit and visible, never implicit. An implicitly held bucket is
--- a leak nobody can find.
---
---@param id integer
---@param held boolean
---@return NxcResult
function Buckets.setHold(id, held)
    local b = allocated[id]
    if not b then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CORE_BUCKET_NOT_FOUND', 'That routing bucket does not exist.',
            { resource = NxcCore.RESOURCE, details = { bucket = id } }))
    end
    b.held = held == true
    if not b.held and next(b.occupants) == nil then
        allocated[id] = nil
        return Nxc.Result.ok({ released = true, bucket = id })
    end
    return Nxc.Result.ok({ released = false, bucket = id })
end

--- Release every bucket owned by a resource. Called when that resource stops.
---
--- Returns the released ids so the caller can resolve entities that were in
--- them. An entity left in a bucket nobody occupies is an orphan.
---
---@param owner string
---@return integer[] released
function Buckets.releaseOwner(owner)
    local released = {}
    for id, b in pairs(allocated) do
        if b.owner == owner then
            released[#released + 1] = id
            allocated[id] = nil
        end
    end
    table.sort(released)
    return released
end

--- Remove an occupant from every bucket. Called on disconnect.
---
--- The disconnect path cannot rely on the player having left cleanly, so it
--- sweeps rather than targeting a known bucket.
---
---@param occupant any
---@return integer[] releasedBuckets
function Buckets.removeOccupant(occupant)
    local key = tostring(occupant)
    local released = {}
    for id, b in pairs(allocated) do
        if b.occupants[key] then
            b.occupants[key] = nil
            if next(b.occupants) == nil and not b.held then
                allocated[id] = nil
                released[#released + 1] = id
            end
        end
    end
    table.sort(released)
    return released
end

---@return integer
function Buckets.count()
    local n = 0
    for _ in pairs(allocated) do n = n + 1 end
    return n
end

--- Every allocated bucket, sorted, for diagnostics.
---
---@return table[]
function Buckets.all()
    local out = {}
    for _, b in pairs(allocated) do out[#out + 1] = b end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Test helper.
function Buckets.reset()
    allocated = {}
    nextId = Buckets.DYNAMIC_MIN
end

NxcCore.Buckets = Buckets
return Buckets
