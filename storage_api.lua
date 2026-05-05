-- CC:Tweaked Storage API
-- Drop this file on any computer that needs to use the storage network.
-- The controller computer must be running storage_controller.lua.
--
-- USAGE EXAMPLE ──────────────────────────────────────────────────────────────
--
--   local store = require("storage_api")
--
--   -- Store anything (strings, or tables/numbers auto-serialized)
--   store.put("players/steve/score", 42)
--   store.put("config/motd", "Hello world!")
--
--   -- Retrieve it back
--   local score = store.get("players/steve/score")   --> "42"
--   local motd  = store.get("config/motd")           --> "Hello world!"
--
--   -- Check / delete
--   print(store.exists("config/motd"))   --> true
--   store.delete("config/motd")
--

local VERSION    = "1.5.0"
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-Tweaked-General-Purpose-Storage-Network/main"

-- ── Auto-updater ───────────────────────────────────────────────────────────
-- Runs once at require() time. If a newer version exists on GitHub the file
-- is replaced on disk and the computer reboots so the caller gets the new code.
local function autoUpdate()
    if not http then return end
    local res = http.get(GITHUB_RAW .. "/versions.lua")
    if not res then return end
    local fn = load(res.readAll()); res.close()
    if not fn then return end
    local ok, ver = pcall(fn)
    if not ok or type(ver) ~= "table" then return end
    if ver.api ~= VERSION then
        print(("[update] storage_api: %s -> %s  Downloading..."):format(VERSION, ver.api))
        local dl = http.get(GITHUB_RAW .. "/storage_api.lua")
        if dl then
            local f = fs.open("storage_api.lua", "w"); f.write(dl.readAll()); f.close(); dl.close()
            print("[update] Done. Rebooting...")
            os.sleep(1); os.reboot()
        else
            print("[update] Download failed, continuing with current version.")
        end
    end
end

autoUpdate()
--   -- List keys (optionally filter by prefix)
--   local keys = store.list("players/")   --> {"players/steve/score", ...}
--
--   -- Network info
--   local info = store.stats()
--   print(info.keyCount, info.totalFree, #info.nodes)
--
-- ─────────────────────────────────────────────────────────────────────────────

local CTRL_PROTOCOL = "cct-store-ctrl"
local FIND_TIMEOUT  = 3    -- seconds to search for the controller
local RPC_TIMEOUT   = 10   -- seconds to wait for a controller response

local M = {}
local controllerId = nil

-- ── Modem setup ────────────────────────────────────────────────────────────
local function ensureModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            pcall(rednet.open, side)
            return true
        end
    end
    return false
end

-- ── Locate the controller on the network ──────────────────────────────────
local function findController()
    if not ensureModem() then return false, "No modem attached" end
    rednet.broadcast({cmd = "ping"}, CTRL_PROTOCOL)
    local deadline = os.clock() + FIND_TIMEOUT
    while os.clock() < deadline do
        local sender, msg = rednet.receive(CTRL_PROTOCOL, deadline - os.clock())
        if sender and type(msg) == "table" and msg.ok then
            controllerId = sender
            return true
        end
    end
    return false, "No storage controller found on the network"
end

-- ── Send a request and wait for the reply ─────────────────────────────────
local function rpc(req, timeout)
    if not controllerId then
        local ok, err = findController()
        if not ok then return nil, err end
    end
    rednet.send(controllerId, req, CTRL_PROTOCOL)
    local sender, resp = rednet.receive(CTRL_PROTOCOL, timeout or RPC_TIMEOUT)
    if sender == controllerId and type(resp) == "table" then
        return resp
    end
    -- Lost the controller - reset so next call rediscovers it
    controllerId = nil
    return nil, "No response from controller (did it restart? call store.reconnect())"
end

-- ── Public API ─────────────────────────────────────────────────────────────

-- store.put(key, data)
-- Store a value.  key is any non-empty string (slashes make nice namespaces).
-- data can be a string, number, boolean, or table (auto-serialized).
-- Returns: true, replicaCount   OR   false, errorMessage
function M.put(key, data)
    if type(data) ~= "string" then data = textutils.serialize(data) end
    local r, err = rpc({cmd="store", key=key, data=data})
    if not r then return false, err end
    if r.ok then return true, r.replicas end
    return false, r.err
end

-- store.get(key)
-- Retrieve a stored value as a string, or nil + error on failure.
-- If you stored a table with put(), deserialize with textutils.unserialize().
function M.get(key)
    local r, err = rpc({cmd="retrieve", key=key})
    if not r then return nil, err end
    if r.ok then return r.data end
    return nil, r.err
end

-- store.delete(key)
-- Remove a key from all nodes.
-- Returns: true   OR   false, errorMessage
function M.delete(key)
    local r, err = rpc({cmd="delete", key=key})
    if not r then return false, err end
    return r.ok
end

-- store.exists(key)
-- Returns true/false, or nil + error if the controller is unreachable.
function M.exists(key)
    local r, err = rpc({cmd="exists", key=key})
    if not r then return nil, err end
    return r.exists
end

-- store.list([prefix])
-- Returns a sorted array of all stored keys.
-- Pass a prefix string to filter (e.g. "players/" returns only player keys).
function M.list(prefix)
    local r, err = rpc({cmd="list", prefix=prefix})
    if not r then return nil, err end
    return r.keys
end

-- store.stats()
-- Returns a table with network information:
--   .nodes       - array of {id, label, free, cap} per node
--   .keyCount    - number of keys stored
--   .totalFree   - total free bytes across all nodes
--   .totalCap    - total capacity across all nodes
--   .replication - current replication factor
function M.stats()
    local r, err = rpc({cmd="stats"})
    if not r then return nil, err end
    return r.stats
end

-- store.rescan()
-- Tell the controller to rediscover storage nodes (useful after adding nodes).
-- Returns: true, nodeCount   OR   false, errorMessage
function M.rescan()
    local r, err = rpc({cmd="rescan"}, 15)
    if not r then return false, err end
    return r.ok, r.nodeCount
end

-- store.task(code, [args], [timeout])
-- Run a Lua function on one storage node and return the result.
--
-- 'code' is a string containing a Lua function body (return a value at the end).
-- 'args' is an optional table of arguments passed to the function.
-- 'timeout' is optional seconds to wait (default 30).
--
-- Inside the task the following globals are available:
--   math, string, table, textutils, pairs, ipairs, tostring, tonumber, type,
--   pcall, error, os.clock/time/date
--   nodeId, nodeLabel, nodeFree, nodeCap
--   readFile(path)  -- read a file stored on this node (returns string or nil)
--   listFiles([prefix]) -- list files stored on this node
--
-- Returns: result_value   OR   nil, errorMessage
--
-- EXAMPLE -- count files stored across one node:
--   local count = store.task("return #listFiles()")
--
-- EXAMPLE -- find all keys matching a prefix on one node:
--   local keys = store.task("return listFiles('players/')")
function M.task(code, args, timeout)
    local r, err = rpc({cmd="task", code=code, args=args, timeout=timeout},
                        (timeout or 30) + 5)
    if not r then return nil, err end
    if r.ok then return r.result end
    return nil, r.err
end

-- store.taskAll(code, [args], [timeout])
-- Run a Lua function on ALL storage nodes simultaneously.
-- Returns an array of results, one per node:
--   { {id, label, result}, ... }  for nodes that succeeded
--   { {id, label, err},    ... }  for nodes that failed or timed out
--
-- Use this for map-reduce style work: each node processes its own data,
-- then you aggregate the results in your script.
--
-- EXAMPLE -- total files across all nodes:
--   local results = store.taskAll("return #listFiles()")
--   local total = 0
--   for _, r in ipairs(results) do
--       if r.result then total = total + r.result end
--   end
--   print("Total files: " .. total)
--
-- EXAMPLE -- collect all player keys from every node:
--   local results = store.taskAll("return listFiles('players/')")
--   for _, r in ipairs(results) do
--       if r.result then
--           for _, key in ipairs(r.result) do print(r.label .. ": " .. key) end
--       end
--   end
function M.taskAll(code, args, timeout)
    local r, err = rpc({cmd="taskAll", code=code, args=args, timeout=timeout},
                        (timeout or 30) + 5)
    if not r then return nil, err end
    if r.ok then return r.results end
    return nil, r.err
end

-- store.reconnect()
-- Forget the cached controller ID and search for it again.
-- Call this if the controller computer was restarted.
function M.reconnect()
    controllerId = nil
    return findController()
end

return M
