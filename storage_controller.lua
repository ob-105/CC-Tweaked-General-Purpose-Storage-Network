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
local VERSION    = "1.1.0"
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-Tweaked-General-Purpose-Storage-Network/main"

-- ── Auto-updater ───────────────────────────────────────────────────────────
local function autoUpdate()
    if not http then return end
    local res = http.get(GITHUB_RAW .. "/versions.lua")
    if not res then return end
    local fn = load(res.readAll()); res.close()
    if not fn then return end
    local ok, ver = pcall(fn)
    if not ok or type(ver) ~= "table" then return end
    if ver.controller ~= VERSION then
        print(("[update] controller: %s -> %s  Downloading..."):format(VERSION, ver.controller))
        local dl = http.get(GITHUB_RAW .. "/storage_controller.lua")
        if dl then
            local path = shell.getRunningProgram()
            local f = fs.open(path, "w"); f.write(dl.readAll()); f.close(); dl.close()
            print("[update] Done. Rebooting...")
            os.sleep(1); os.reboot()
        else
            print("[update] Download failed, continuing with current version.")
        end
    end
end

autoUpdate()

-- CONFIG ──────────────────────────────────────────────────────────────────
local REPLICATION   = 2    -- how many nodes to write each key to
local RESCAN_EVERY  = 60   -- seconds between automatic node rescans
local NODE_TIMEOUT  = 5    -- seconds to wait for a node RPC response
-- ─────────────────────────────────────────────────────────────────────────

-- ── Screen layout ──────────────────────────────────────────────────────────
-- Lines 1 .. H-4  : scrolling activity log
-- Line  H-3       : divider
-- Line  H-2       : live stats bar
-- Line  H-1       : key hint bar
-- Line  H         : (reserved / cursor)
local W, H   = term.getSize()
local LOG_H  = H - 4        -- usable log rows
local inMenu = false        -- true while a menu is open (pauses log redraws)

-- Colour helpers (safe on non-advanced computers)
local function colour(c) if term.isColour() then term.setTextColour(c) end end
local function resetColour() colour(colours.white) end

local NODE_PROTOCOL = "cct-media-store"   -- controller <-> storage nodes
local CTRL_PROTOCOL = "cct-store-ctrl"    -- clients    <-> controller
local INDEX_FILE    = "ctrl_index.dat"    -- persisted key->node index

-- ── State ──────────────────────────────────────────────────────────────────
local nodes    = {}   -- [id] -> {id, label, free, cap}
local index    = {}   -- [key] -> {nodeId, nodeId, ...}
local lastScan = -999

-- ── Activity log ───────────────────────────────────────────────────────────
local logBuf = {}   -- ring buffer of strings

local function drawLog()
    if inMenu then return end
    local start = math.max(1, #logBuf - LOG_H + 1)
    for row = 1, LOG_H do
        local line = logBuf[start + row - 1] or ""
        term.setCursorPos(1, row)
        term.clearLine()
        term.write(line:sub(1, W))
    end
end

local function drawDivider()
    if inMenu then return end
    term.setCursorPos(1, H - 3)
    colour(colours.grey)
    term.write(string.rep("-", W))
    resetColour()
end

local function drawStats()
    if inMenu then return end
    local nodeCount, totalFree = 0, 0
    for _, n in pairs(nodes) do nodeCount = nodeCount + 1; totalFree = totalFree + n.free end
    local keyCount = 0; for _ in pairs(index) do keyCount = keyCount + 1 end
    term.setCursorPos(1, H - 2); term.clearLine()
    colour(colours.cyan)
    term.write(("Nodes: %d  |  Keys: %d  |  Free: %dKB  |  Rep: %dx")
        :format(nodeCount, keyCount, math.floor(totalFree / 1024), REPLICATION))
    resetColour()
end

local function drawHints()
    if inMenu then return end
    term.setCursorPos(1, H - 1); term.clearLine()
    colour(colours.yellow)
    term.write("[M] Menu  [R] Rescan  [Q] Quit")
    resetColour()
    term.setCursorPos(1, H); term.clearLine()
end

local function redraw()
    drawLog(); drawDivider(); drawStats(); drawHints()
end

local function log(msg)
    local ts = ("[%s] "):format(textutils.formatTime(os.time(), true))
    logBuf[#logBuf + 1] = ts .. msg
    if #logBuf > 200 then table.remove(logBuf, 1) end
    drawLog(); drawDivider(); drawStats(); drawHints()
end

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
                return a, b
            else
                msgQueue[#msgQueue+1] = {sender=a, msg=b, proto=c}
            end
        elseif ev == "timer" and a == timerId then
            return nil, nil
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
    log("Scanning for storage nodes...")
    rednet.broadcast({cmd = "ping"}, NODE_PROTOCOL)
    local found    = {}
    local timerId  = os.startTimer(3)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "rednet_message" then
            if c == NODE_PROTOCOL and type(b) == "table" and b.ok then
                found[a] = {id=a, label=b.label or ("node-"..a), free=b.free or 0, cap=b.cap or 0}
            elseif c ~= NODE_PROTOCOL then
                msgQueue[#msgQueue+1] = {sender=a, msg=b, proto=c}
            end
        elseif ev == "timer" and a == timerId then
            break
        end
    end
    nodes = found
    local count, totalFree = 0, 0
    for _, n in pairs(nodes) do count = count + 1; totalFree = totalFree + n.free end
    log(("Scan complete: %d node(s) online | %dKB total free"):format(count, math.floor(totalFree / 1024)))
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
    log(("STORE '%s' → %d replica(s) | %dB"):format(key, #written, #data))
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
    if not nodeIds then return true end
    for _, nid in ipairs(nodeIds) do
        if nodes[nid] then
            local r = nodeRPC(nid, {cmd="delete", path=key})
            if r and r.free then nodes[nid].free = r.free end
        end
    end
    index[key] = nil
    saveIndex()
    log(("DELETE '%s'"):format(key))
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
        log(("GET '%s' from #%d"):format(msg.key or "?", sender))
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

-- ── Management console helpers ─────────────────────────────────────────────
local function menuHeader(title)
    term.clear(); term.setCursorPos(1, 1)
    colour(colours.orange)
    print("=== Storage Controller | " .. title .. " ===")
    resetColour()
end

local function pause(msg)
    colour(colours.grey)
    print(msg or "\nPress Enter to continue...")
    resetColour()
    io.read()
end

-- Show per-node status table
local function menuStatus()
    menuHeader("Node Status")
    local nodeList = {}
    for _, n in pairs(nodes) do nodeList[#nodeList+1] = n end
    table.sort(nodeList, function(a, b) return a.id < b.id end)

    if #nodeList == 0 then
        colour(colours.red); print("No nodes online."); resetColour()
    else
        print(("%-20s %5s %8s %8s %6s"):format("Label", "ID", "Free KB", "Cap KB", "Used%"))
        print(string.rep("-", W))
        for _, n in ipairs(nodeList) do
            local pct = n.cap > 0 and math.floor((1 - n.free / n.cap) * 100) or 0
            colour(pct >= 90 and colours.red or pct >= 70 and colours.yellow or colours.lime)
            print(("%-20s %5d %8d %8d %5d%%"):format(
                n.label:sub(1, 20), n.id,
                math.floor(n.free / 1024), math.floor(n.cap / 1024), pct))
            resetColour()
        end
    end
    local keyCount = 0; for _ in pairs(index) do keyCount = keyCount + 1 end
    print(string.rep("-", W))
    print(("Total nodes: %d  |  Keys stored: %d  |  Replication: %dx")
        :format(#nodeList, keyCount, REPLICATION))
    pause()
end

-- Browse stored keys with optional prefix filter
local function menuBrowse()
    menuHeader("Browse Keys")
    io.write("Filter prefix (Enter for all): "); local prefix = io.read()
    if prefix == "" then prefix = nil end
    local keys = opList(prefix)
    print(string.rep("-", W))
    if #keys == 0 then
        colour(colours.yellow); print("No keys found."); resetColour()
    else
        for i, k in ipairs(keys) do
            local replicas = index[k] and #index[k] or 0
            colour(replicas < REPLICATION and colours.yellow or colours.white)
            print(("  %d. %s  [%drep]"):format(i, k, replicas))
            resetColour()
            if i % (H - 6) == 0 and i < #keys then
                io.write("-- more -- (Enter) "); io.read()
            end
        end
        print(string.rep("-", W))
        print(#keys .. " key(s)")
    end
    pause()
end

-- Delete a single key by name
local function menuDeleteKey()
    menuHeader("Delete Key")
    io.write("Key to delete (exact): "); local key = io.read()
    if key == "" then return end
    if not index[key] then
        colour(colours.red); print("Key not found: " .. key); resetColour()
    else
        io.write("Delete '" .. key .. "'? (y/n): ")
        if (io.read() or ""):lower() == "y" then
            opDelete(key)
            colour(colours.lime); print("Deleted."); resetColour()
        end
    end
    pause()
end

-- Wipe a single node (removes all files from it) and repair index
local function menuWipeNode()
    menuHeader("Wipe Node")
    local nodeList = {}
    for _, n in pairs(nodes) do nodeList[#nodeList+1] = n end
    table.sort(nodeList, function(a, b) return a.id < b.id end)
    if #nodeList == 0 then
        colour(colours.red); print("No nodes online."); resetColour()
        pause(); return
    end
    for i, n in ipairs(nodeList) do
        print(("  %d. [#%d] %s  (%dKB free)"):format(i, n.id, n.label, math.floor(n.free/1024)))
    end
    print("  0. Cancel"); io.write("Select node: ")
    local sel = tonumber(io.read())
    if not sel or sel == 0 or not nodeList[sel] then return end
    local n = nodeList[sel]
    io.write(("Wipe ALL data on '%s' (#%d)? This cannot be undone. (y/n): "):format(n.label, n.id))
    if (io.read() or ""):lower() ~= "y" then return end

    local r = nodeRPC(n.id, {cmd="wipe"})
    if r and r.ok then
        nodes[n.id].free = r.free or nodes[n.id].free
        -- Remove all index entries that were ONLY on this node; downgrade others
        local removed = 0
        for k, reps in pairs(index) do
            local newReps = {}
            for _, rid in ipairs(reps) do if rid ~= n.id then newReps[#newReps+1] = rid end end
            if #newReps == 0 then index[k] = nil; removed = removed + 1
            else index[k] = newReps end
        end
        saveIndex()
        log(("WIPE node '%s' | %d key(s) removed from index"):format(n.label, removed))
        colour(colours.lime); print("Node wiped. " .. removed .. " index entries removed."); resetColour()
    else
        colour(colours.red); print("Wipe failed or node did not respond."); resetColour()
    end
    pause()
end

-- Wipe every node and clear the entire index
local function menuWipeAll()
    menuHeader("!! WIPE ALL STORAGE !!")
    colour(colours.red)
    print("This will permanently erase ALL data on ALL nodes")
    print("and clear the index. This CANNOT be undone.")
    resetColour()
    io.write("\nType WIPE to confirm, or Enter to cancel: ")
    if io.read() ~= "WIPE" then
        print("Cancelled."); pause(); return
    end
    local wiped = 0
    for _, n in pairs(nodes) do
        local r = nodeRPC(n.id, {cmd="wipe"})
        if r and r.ok then
            nodes[n.id].free = r.free or nodes[n.id].free
            wiped = wiped + 1
            colour(colours.lime)
            print(("  Wiped: %s (#%d)"):format(n.label, n.id))
            resetColour()
        else
            colour(colours.red)
            print(("  FAILED: %s (#%d)"):format(n.label, n.id))
            resetColour()
        end
    end
    index = {}
    saveIndex()
    log(("WIPE ALL — %d node(s) wiped, index cleared"):format(wiped))
    colour(colours.lime); print("\nDone. " .. wiped .. " node(s) wiped."); resetColour()
    pause()
end

-- Top-level management menu
local function managementMenu()
    inMenu = true
    while true do
        menuHeader("Main Menu")
        print("  1. Node status & health")
        print("  2. Browse stored keys")
        print("  3. Delete a key")
        print("  4. Rescan nodes")
        print("  5. Wipe a single node")
        print("  6. WIPE ALL storage")
        print("  0. Back to monitor")
        print()
        io.write("Choice: ")
        local c = io.read() or ""

        if     c == "1" then menuStatus()
        elseif c == "2" then menuBrowse()
        elseif c == "3" then menuDeleteKey()
        elseif c == "4" then
            inMenu = false; scanNodes(); inMenu = true
            menuHeader("Rescan")
            local count = 0; for _ in pairs(nodes) do count = count + 1 end
            colour(colours.lime); print(count .. " node(s) found."); resetColour()
            pause()
        elseif c == "5" then menuWipeNode()
        elseif c == "6" then menuWipeAll()
        elseif c == "0" or c == "" then break
        end
    end
    inMenu = false
    term.clear()
    redraw()
end

-- ── Network loop (runs as a parallel coroutine) ────────────────────────────
local function networkLoop()
    while true do
        if os.clock() - lastScan >= RESCAN_EVERY then scanNodes() end
        local sender, msg = queuedReceive(CTRL_PROTOCOL, 1)
        if sender and type(msg) == "table" then
            local ok, err = pcall(handleClient, sender, msg)
            if not ok then
                log("ERR from #" .. sender .. ": " .. tostring(err))
                pcall(rednet.send, sender, {ok=false, err="Internal controller error"}, CTRL_PROTOCOL)
            end
        end
    end
end

-- ── Console loop (runs as a parallel coroutine) ───────────────────────────
local function consoleLoop()
    while true do
        -- Read a single keypress without blocking the network coroutine
        local _, key = os.pullEvent("key")
        if key == keys.m then
            managementMenu()
        elseif key == keys.r then
            scanNodes()
        elseif key == keys.q then
            term.clear(); term.setCursorPos(1, 1)
            print("Controller shutting down.")
            os.shutdown()
        end
    end
end

-- ── Startup ────────────────────────────────────────────────────────────────
if openModems() == 0 then
    error("No modem found! Attach a wired modem and connect cables to your storage nodes.")
end

loadIndex()
local keyCount = 0; for _ in pairs(index) do keyCount = keyCount + 1 end

term.clear(); term.setCursorPos(1, 1)
-- Initial boot message goes straight into the log buffer before redraw
logBuf[#logBuf+1] = "Controller starting | ID: " .. os.getComputerID()
    .. " | Label: " .. (os.getComputerLabel() or "(none)")
logBuf[#logBuf+1] = "Replication: " .. REPLICATION .. "x | Index: " .. keyCount .. " key(s) loaded"

redraw()
scanNodes()

-- Run the network listener and the keyboard console side by side
parallel.waitForAny(networkLoop, consoleLoop)
