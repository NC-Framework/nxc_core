--- MariaDB persistence provider, backed by oxmysql.
---
--- The thinnest possible translation between the provider interface and
--- oxmysql's exports. Everything with logic in it — the cross-domain guard,
--- error shaping, migration planning — lives in shared modules that are testable
--- without a database.
---
--- This file cannot be unit tested: oxmysql exists only in the FiveM runtime.
--- Keeping it thin is what makes that acceptable.

if not IsDuplicityVersion() then return end

local Provider = {}

local function oxmysql()
    -- Resolved lazily. At load time oxmysql may not have started yet, and a
    -- cached nil would be permanent.
    local ok, export = pcall(function() return exports.oxmysql end)
    if not ok or not export then
        error('oxmysql is not available: it must start before nxc_core', 0)
    end
    return export
end

--- Synchronous query returning rows.
---
---@param sql string
---@param params table|nil
---@return table
function Provider.query(sql, params)
    return oxmysql():query_async(sql, params or {})
end

--- Synchronous statement returning affected rows.
---
---@param sql string
---@param params table|nil
---@return integer
function Provider.execute(sql, params)
    return oxmysql():update_async(sql, params or {})
end

--- Atomic transaction.
---
--- oxmysql rolls back the whole set if any statement fails, which is what the
--- ten mandatory-atomic operation classes require. A sequence of separate
--- statements would not.
---
---@param statements { query: string, values?: table }[]
---@return boolean
function Provider.transaction(statements)
    local prepared = {}
    for i, st in ipairs(statements) do
        prepared[i] = { query = st.query, values = st.values or {} }
    end
    return oxmysql():transaction_async(prepared)
end

--- Whether the database is reachable.
---
--- Called during bootstrap. A server that starts without its database appears
--- healthy and fails on the first player action, which is a worse failure than
--- refusing to start.
---
---@return boolean, string|nil
function Provider.ping()
    local ok, err = pcall(function()
        return oxmysql():scalar_async('SELECT 1')
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

NxcCore.MariaDBProvider = Provider
return Provider
