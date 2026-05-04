-- CC:Tweaked General-Purpose Storage Controller
-- Run this on the main controller computer (set as startup or run manually).
-- Storage node computers run storage_server.lua.
-- Any other computer uses storage_api.lua to store/retrieve data.
--
-- ┌──────────────┐  cct-store-ctrl   ┌────────────────────┐
-- │  API client  │ ◄────────────────► │  This controller   │
-- └──────────────┘                    └────────┬───────────┘
--                                              │  cct-media-store
--                            ┌─────────────────┼────────────────────┐
--                       ┌────▼────┐       ┌────▼────┐          ┌────▼────┐
--                       │  node 1 │       │  node 2 │   ...    │  node N │
--                       └─────────┘       └─────────┘          └─────────┘
--
-- CONFIG ──────────────────────────────────────────────────────────────────
local REPLICATION   = 2    -- how many nodes to write each key to
local RESCAN_EVERY  = 60   -- seconds between automatic node rescans
local NODE_TIMEOUT  = 5    -- seconds to wait for a node RPC response
-- ─────────────────────────────────────────────────────────────────────────

local NODE_PROTOCOL = "cct-media-store"   -- controller <-> storage nodes
local CTRL_PROTOCOL = "cct-store-ctrl"    -- clients    <-> controller
local INDEX_FILE    = "ctrl_index.dat"    -- persisted key->node index

-- ── State ──────────────────────────────────────────────────────────────────
local nodes    = {}   -- [id] -> {id, label, free, cap}
local index    = {}   -- [key] -> {nodeId, nodeId, ...}
local lastScan = -999

-- ── Multi-protocol message buffer ──────────────────────────────────────────
-- CC:Tweaked's rednet.receive discards messages from protocols it isn't
-- listening for, which causes problems when node RPCs and client requests
-- interleave.  We pull raw events instead and buffer unmatched messages.
local msgQueue = {}

-- Receive the next message matching `protocol`, waiting up to `timeout` sec.
local function queuedReceive(protocol, timeout)
    -- Check buffer first
    for i, e in ipairs(msgQueue) do
        if e.proto == protocol then
            table.remove(msgQueue, i)
            return e.sender, e.msg
        end
    end
    local timerId = timeout and os.startTimer(timeout)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "rednet_message" then
            if c == protocol then
                return a, b          -- matched
            else
                msgQueue[#msgQueue+1] = {sender=a, msg=b, proto=c}
            end
        elseif ev == "timer" and a == timerId then
            return nil, nil          -- timed out
        end
    end
end

-- ── Modem setup ────────────────────────────────────────────────────────────
local function openModems()
    local n = 0
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            pcall(rednet.open, side)
            n = n + 1
        end
    end
    return n
end

-- ── Index persistence ──────────────────────────────────────────────────────
local function saveIndex()
    local f = fs.open(INDEX_FILE, "w")
    f.write(textutils.serialize(index))
    f.close()
end

local function loadIndex()
    if not fs.exists(INDEX_FILE) then return end
    local f = fs.open(INDEX_FILE, "r")
    local raw = f.readAll(); f.close()
    local t = textutils.unserialize(raw)
    if type(t) == "table" then index = t end
end

-- ── Node discovery ─────────────────────────────────────────────────────────
local function scanNodes()
    print("[ctrl] Scanning for storage nodes...")
    rednet.broadcast({cmd = "ping"}, NODE_PROTOCOL)
    local found    = {}
    local timerId  = os.startTimer(3)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "rednet_message" then
            if c == NODE_PROTOCOL and type(b) == "table" and b.ok then
                found[a] = {id=a, label=b.label or ("node-"..a), free=b.free or 0, cap=b.cap or 0}
            elseif c ~= NODE_PROTOCOL then
                -- buffer messages for other protocols (e.g. client requests arriving during scan)
                msgQueue[#msgQueue+1] = {sender=a, msg=b, proto=c}
            end
        elseif ev == "timer" and a == timerId then
            break
        end
    end
    nodes = found
    local count, totalFree = 0, 0
    for _, n in pairs(nodes) do count = count + 1; totalFree = totalFree + n.free end
    print(("[ctrl] %d node(s) online | %dKB total free"):format(count, math.floor(totalFree / 1024)))
    lastScan = os.clock()
end

-- ── Node RPC ───────────────────────────────────────────────────────────────
-- Sends a request to a specific node and waits for its reply.
-- Buffers responses from other nodes so they aren't lost.
local function nodeRPC(nodeId, req, timeout)
    rednet.send(nodeId, req, NODE_PROTOCOL)
    local deadline = os.clock() + (timeout or NODE_TIMEOUT)
    while os.clock() > 0 do   -- loop until deadline
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local sender, resp = queuedReceive(NODE_PROTOCOL, remaining)
        if not sender then break end                -- timed out
        if sender == nodeId then return resp end    -- got our reply
        -- Response from a different node - buffer it
        msgQueue[#msgQueue+1] = {sender=sender, msg=resp, proto=NODE_PROTOCOL}
    end
    return nil
end

-- ── Pick write targets (nodes with most free space first) ──────────────────
local function pickNodes(count)
    local list = {}
    for _, n in pairs(nodes) do list[#list+1] = n end
    table.sort(list, function(a, b) return a.free > b.free end)
    local out = {}
    for i = 1, math.min(count, #list) do out[#out+1] = list[i] end
    return out
end

-- ── Core storage operations ────────────────────────────────────────────────

local function opStore(key, data)
    local targets = pickNodes(REPLICATION)
    if #targets == 0 then return false, "No storage nodes available" end

    local written = {}
    for _, n in ipairs(targets) do
        if n.free >= #data + 2048 then
            local r = nodeRPC(n.id, {cmd="put", path=key, data=data}, NODE_TIMEOUT)
            if r and r.ok then
                written[#written+1] = n.id
                if nodes[n.id] then nodes[n.id].free = r.free or nodes[n.id].free end
            end
        end
    end

    if #written == 0 then return false, "No node had enough free space" end
    index[key] = written
    saveIndex()
    return true, #written
end

local function opRetrieve(key)
    local nodeIds = index[key]
    if not nodeIds or #nodeIds == 0 then return nil, "Key not found" end
    for _, nid in ipairs(nodeIds) do
        if nodes[nid] then
            local r = nodeRPC(nid, {cmd="get", path=key}, NODE_TIMEOUT)
            if r and r.ok and r.data ~= nil then return r.data end
        end
    end
    return nil, "All replicas unavailable (try rescan if nodes were restarted)"
end

local function opDelete(key)
    local nodeIds = index[key]
    if not nodeIds then return true end     -- already gone
    for _, nid in ipairs(nodeIds) do
        if nodes[nid] then
            local r = nodeRPC(nid, {cmd="delete", path=key})
            if r and r.free then nodes[nid].free = r.free end
        end
    end
    index[key] = nil
    saveIndex()
    return true
end

local function opList(prefix)
    local keys = {}
    for k in pairs(index) do
        if not prefix or k:sub(1, #prefix) == prefix then
            keys[#keys+1] = k
        end
    end
    table.sort(keys)
    return keys
end

local function opStats()
    local nodeList, totalFree, totalCap = {}, 0, 0
    for _, n in pairs(nodes) do
        nodeList[#nodeList+1] = {id=n.id, label=n.label, free=n.free, cap=n.cap}
        totalFree = totalFree + n.free
        totalCap  = totalCap  + n.cap
    end
    local keyCount = 0
    for _ in pairs(index) do keyCount = keyCount + 1 end
    return {
        nodes       = nodeList,
        keyCount    = keyCount,
        totalFree   = totalFree,
        totalCap    = totalCap,
        replication = REPLICATION,
    }
end

-- ── Handle a single client request ─────────────────────────────────────────
local function handleClient(sender, msg)
    local cmd = msg.cmd

    if cmd == "ping" then
        rednet.send(sender, {
            ok    = true,
            id    = os.getComputerID(),
            label = os.getComputerLabel() or "controller",
        }, CTRL_PROTOCOL)

    elseif cmd == "store" then
        if type(msg.key) ~= "string" or msg.key == "" then
            return rednet.send(sender, {ok=false, err="'key' must be a non-empty string"}, CTRL_PROTOCOL)
        end
        if type(msg.data) ~= "string" then
            return rednet.send(sender, {ok=false, err="'data' must be a string"}, CTRL_PROTOCOL)
        end
        local ok, info = opStore(msg.key, msg.data)
        if ok then rednet.send(sender, {ok=true,  replicas=info}, CTRL_PROTOCOL)
        else      rednet.send(sender, {ok=false, err=info},      CTRL_PROTOCOL) end

    elseif cmd == "retrieve" then
        local data, err = opRetrieve(msg.key)
        if data ~= nil then rednet.send(sender, {ok=true, data=data},  CTRL_PROTOCOL)
        else                rednet.send(sender, {ok=false, err=err},   CTRL_PROTOCOL) end

    elseif cmd == "delete" then
        opDelete(msg.key)
        rednet.send(sender, {ok=true}, CTRL_PROTOCOL)

    elseif cmd == "exists" then
        rednet.send(sender, {ok=true, exists=(index[msg.key] ~= nil)}, CTRL_PROTOCOL)

    elseif cmd == "list" then
        rednet.send(sender, {ok=true, keys=opList(msg.prefix)}, CTRL_PROTOCOL)

    elseif cmd == "stats" then
        rednet.send(sender, {ok=true, stats=opStats()}, CTRL_PROTOCOL)

    elseif cmd == "rescan" then
        scanNodes()
        local count = 0; for _ in pairs(nodes) do count = count + 1 end
        rednet.send(sender, {ok=true, nodeCount=count}, CTRL_PROTOCOL)
    end
end

-- ── Startup ────────────────────────────────────────────────────────────────
if openModems() == 0 then
    error("No modem found! Attach a wired modem and connect cables to your storage nodes.")
end

loadIndex()
local keyCount = 0; for _ in pairs(index) do keyCount = keyCount + 1 end

term.clear(); term.setCursorPos(1, 1)
print("=== CC:T Storage Controller ===")
print("ID:          " .. os.getComputerID())
print("Label:       " .. (os.getComputerLabel() or "(none)"))
print("Replication: " .. REPLICATION .. "x")
print("Index:       " .. keyCount .. " key(s) loaded from disk")
print("================================")

scanNodes()
print("Ready. Listening on protocol: " .. CTRL_PROTOCOL)

-- ── Main loop ──────────────────────────────────────────────────────────────
while true do
    if os.clock() - lastScan >= RESCAN_EVERY then
        scanNodes()
    end

    -- Wait up to 1 second for a client request, then loop (to check rescan timer)
    local sender, msg = queuedReceive(CTRL_PROTOCOL, 1)
    if sender and type(msg) == "table" then
        local ok, err = pcall(handleClient, sender, msg)
        if not ok then
            print("[ctrl] Error handling request from " .. sender .. ": " .. tostring(err))
            pcall(rednet.send, sender, {ok=false, err="Internal controller error"}, CTRL_PROTOCOL)
        end
    end
end
