-- CC:Tweaked Storage Server Node
-- Drop this on any computer connected to the player via wired modem + cables.
-- Set it as startup.lua or run manually: lua storage_server.lua
-- Each computer provides ~1MB of frame storage.

local VERSION    = "1.4.0"
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
    if ver.server ~= VERSION then
        print(("[update] server: %s -> %s  Downloading..."):format(VERSION, ver.server))
        local dl = http.get(GITHUB_RAW .. "/storage_server.lua")
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

local PROTOCOL = "cct-media-store"

-- Open every modem we can find
local opened = 0
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        pcall(rednet.open, side)
        opened = opened + 1
    end
end
if opened == 0 then error("No modem found! Attach a wired modem and connect cables.") end

local ID    = os.getComputerID()
local LABEL = os.getComputerLabel() or ("node-"..ID)
os.setComputerLabel(LABEL)

term.clear(); term.setCursorPos(1,1)
print("=== CC:T Storage Node ===")
print("ID:    "..ID)
print("Label: "..LABEL)
print("Free:  "..math.floor(fs.getFreeSpace("/")/1024).."KB / "..math.floor(fs.getCapacity("/")/1024).."KB")
print("========================")
print("Listening for requests...")

local function walk(dir, results)
    if not fs.exists(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
        local p = dir.."/"..name
        if fs.isDir(p) then walk(p, results)
        else results[#results+1] = p:sub(#"store/"+1) end
    end
end

local function handle(sender, msg)
    local cmd = msg.cmd

    if cmd == "ping" then
        rednet.send(sender, {
            ok    = true,
            id    = ID,
            label = LABEL,
            free  = fs.getFreeSpace("/"),
            cap   = fs.getCapacity("/"),
        }, PROTOCOL)

    elseif cmd == "put" then
        local path = "store/"..(msg.path or "")
        local dir  = path:match("^(.*)/[^/]+$")
        if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f, err = fs.open(path, "w")
        if not f then
            rednet.send(sender, {ok=false, err=tostring(err)}, PROTOCOL)
            return
        end
        f.write(msg.data); f.close()
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "get" then
        local path = "store/"..(msg.path or "")
        if not fs.exists(path) then
            rednet.send(sender, {ok=false}, PROTOCOL)
            return
        end
        local f = fs.open(path, "r")
        local data = f.readAll(); f.close()
        rednet.send(sender, {ok=true, data=data}, PROTOCOL)

    elseif cmd == "has" then
        rednet.send(sender, {ok=fs.exists("store/"..(msg.path or ""))}, PROTOCOL)

    elseif cmd == "delete" then
        local path = "store/"..(msg.path or "")
        if fs.exists(path) then fs.delete(path) end
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "wipe" then
        if fs.exists("store") then fs.delete("store") end
        print("[store] Wiped all stored frames.")
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "list" then
        local results = {}
        walk("store", results)
        rednet.send(sender, {ok=true, files=results}, PROTOCOL)

    elseif cmd == "free" then
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "task" then
        -- Execute a Lua function string in a sandboxed environment.
        -- The code must be a function body (not a bare expression).
        -- The sandbox provides read-only access to this node's stored files
        -- and standard Lua libs, but NO filesystem writes, rednet, or http.
        local unpack_ = table.unpack or unpack
        local sandbox = {
            -- Standard safe libs
            math      = math,
            string    = string,
            table     = table,
            textutils = textutils,
            pairs     = pairs,
            ipairs    = ipairs,
            tostring  = tostring,
            tonumber  = tonumber,
            type      = type,
            pcall     = pcall,
            error     = error,
            select    = select,
            unpack    = unpack_,
            os        = {clock=os.clock, time=os.time, date=os.date},
            -- Node identity
            nodeId    = ID,
            nodeLabel = LABEL,
            nodeFree  = fs.getFreeSpace("/"),
            nodeCap   = fs.getCapacity("/"),
            -- Read-only access to files stored on this node
            readFile  = function(path)
                local p = "store/"..tostring(path)
                if not fs.exists(p) then return nil end
                local f = fs.open(p, "r")
                local d = f.readAll(); f.close()
                return d
            end,
            listFiles = function(prefix)
                local results = {}
                walk("store", results)
                if prefix then
                    local filtered = {}
                    for _, v in ipairs(results) do
                        if v:sub(1, #prefix) == prefix then
                            filtered[#filtered+1] = v
                        end
                    end
                    return filtered
                end
                return results
            end,
        }
        sandbox._ENV = sandbox

        local code = msg.code or ""
        local fn, compErr = load(code, "task", "t", sandbox)
        if not fn then
            rednet.send(sender, {ok=false, err="Compile error: "..tostring(compErr)}, PROTOCOL)
            return
        end

        local args = msg.args or {}
        local ok2, result = pcall(fn, unpack_(args))
        if not ok2 then
            rednet.send(sender, {ok=false, err=tostring(result)}, PROTOCOL)
            return
        end

        -- Serialize result so it survives rednet transmission
        local ok3, serialized = pcall(textutils.serialize, result)
        if not ok3 then
            rednet.send(sender, {ok=false, err="Task result is not serializable"}, PROTOCOL)
            return
        end
        rednet.send(sender, {ok=true, result=serialized}, PROTOCOL)
    end
end

-- Main loop
while true do
    local ok, err = pcall(function()
        local sender, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            handle(sender, msg)
        end
    end)
    if not ok then
        print("[store] Error: "..tostring(err))
    end
end
