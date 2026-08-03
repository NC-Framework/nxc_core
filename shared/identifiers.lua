--- Immutable identifiers.
---
--- Accounts, characters, sessions, and every other persistent entity carry an
--- immutable, opaque, server-generated identifier.
---
--- Display names, licence plates, and phone numbers are NEVER primary
--- identifiers: a player can change them, and anything keyed on them breaks
--- silently when they do.

local Identifiers = {}

-- Crockford base32, which excludes I, L, O, and U so an identifier cannot be
-- misread aloud or mistyped into a support ticket.
local ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
local RANDOM_LENGTH = 16
local TIME_LENGTH = 10

Identifiers.PREFIX = {
    ACCOUNT   = 'acc',
    CHARACTER = 'chr',
    SESSION   = 'ses',
}

local seeded = false
local counter = 0

local function ensureSeeded()
    if seeded then return end
    seeded = true
    -- `os` does not exist on the FiveM client, so a seed that reaches for it
    -- crashes there. GetGameTimer is present on both sides; os.time is the
    -- fallback for a bare Lua runtime such as the test harness.
    local function seedSource()
        if type(GetGameTimer) == 'function' then return GetGameTimer() end
        if type(os) == 'table' and type(os.time) == 'function' then return os.time() end
        return 0
    end

    local addr = tostring({}):match('0x(%x+)') or '0'
    math.randomseed((seedSource() % 2147483647) ~ (tonumber(addr, 16) or 0))
end

local function encodeTime(ms, length)
    local out = {}
    local value = math.floor(ms)
    for i = length, 1, -1 do
        local rem = value % 32
        out[i] = ALPHABET:sub(rem + 1, rem + 1)
        value = math.floor(value / 32)
    end
    return table.concat(out)
end

local function randomPart(length)
    ensureSeeded()
    local out = {}
    for i = 1, length do
        local idx = math.random(1, #ALPHABET)
        out[i] = ALPHABET:sub(idx, idx)
    end
    return table.concat(out)
end

--- Generate an identifier.
---
--- Time-ordered: the leading component encodes the creation time, so
--- identifiers sort chronologically and index well as a clustered key. A
--- counter is mixed into the random part so two generated in the same
--- millisecond cannot collide.
---
---@param prefix string
---@param nowMs number|nil
---@return string
function Identifiers.new(prefix, nowMs)
    if type(prefix) ~= 'string' or #prefix < 2 or #prefix > 8 then
        error('an identifier prefix must be 2 to 8 characters, got ' .. tostring(prefix), 2)
    end
    counter = (counter + 1) % 1024
    local ms = nowMs or Nxc.Time.nowMs()
    local body = encodeTime(ms, TIME_LENGTH) .. randomPart(RANDOM_LENGTH - 3)
    local suffix = encodeTime(counter, 3)
    return ('%s_%s%s'):format(prefix, body, suffix)
end

---@param nowMs number|nil
---@return string
function Identifiers.account(nowMs)
    return Identifiers.new(Identifiers.PREFIX.ACCOUNT, nowMs)
end

---@param nowMs number|nil
---@return string
function Identifiers.character(nowMs)
    return Identifiers.new(Identifiers.PREFIX.CHARACTER, nowMs)
end

---@param nowMs number|nil
---@return string
function Identifiers.session(nowMs)
    return Identifiers.new(Identifiers.PREFIX.SESSION, nowMs)
end

--- Whether a value is a well-formed identifier, optionally of a given kind.
---
--- Identifiers arrive in payloads from clients. An unvalidated one reaching a
--- query is a malformed key at best.
---
---@param id any
---@param prefix string|nil
---@return boolean
function Identifiers.isValid(id, prefix)
    if type(id) ~= 'string' then return false end
    local p, body = id:match('^(%w+)_([0-9A-HJKMNP-TV-Z]+)$')
    if not p or not body then return false end
    if #body ~= (TIME_LENGTH + RANDOM_LENGTH) then return false end
    if prefix and p ~= prefix then return false end
    return true
end

--- The kind of an identifier, or nil if malformed.
---
---@param id any
---@return string|nil
function Identifiers.kindOf(id)
    if not Identifiers.isValid(id) then return nil end
    return id:match('^(%w+)_')
end

Nxc.Identifiers = Identifiers
NxcCore.Identifiers = Identifiers
return Identifiers
