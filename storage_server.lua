-- CC:Tweaked Storage Server Node
-- Drop this on any computer connected to the player via wired modem + cables.
-- Set it as startup.lua or run manually: lua storage_server.lua
-- Each computer provides ~1MB of frame storage.

local VERSION    = "1.5.0"
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

-- ── LZ77 compression (runs locally so the controller stays free) ───────────
-- Format: MAGIC (3 bytes) | LZ tokens
--   flag < 0x80  → literal run:  (flag+1) literal bytes follow
--   flag >= 0x80 → back-ref:     length=(flag-0x80)+3, dist=next_byte+1
local COMPRESS_MAGIC = "\27LZ"
local LZ_MIN    = 3
local LZ_MAX    = 130
local LZ_WIN    = 255
local MAX_CANDS = 4

local function lzCompress(input)
    local n = #input
    if n == 0 then return "" end
    local b = {input:byte(1, n)}
    local ht, out, lits = {}, {}, {}

    local function flushLits()
        if #lits == 0 then return end
        local i = 1
        while i <= #lits do
            local cnt = math.min(128, #lits - i + 1)
            out[#out+1] = string.char(cnt - 1)
            for j = i, i + cnt - 1 do out[#out+1] = lits[j] end
            i = i + cnt
        end
        lits = {}
    end

    local function hashAdd(p)
        if p + 1 > n then return end
        local k = b[p] * 256 + b[p + 1]
        local t = ht[k]
        if not t then ht[k] = {p}; return end
        if #t >= MAX_CANDS then table.remove(t, 1) end
        t[#t + 1] = p
    end

    local pos = 1
    while pos <= n do
        local blen, bdist = 0, 0
        if pos + LZ_MIN - 1 <= n then
            local k = b[pos] * 256 + b[pos + 1]
            local cands = ht[k]
            if cands then
                local maxl = math.min(LZ_MAX, n - pos)
                for ci = #cands, 1, -1 do
                    local cp   = cands[ci]
                    local dist = pos - cp
                    if dist > 0 and dist <= LZ_WIN then
                        if b[cp + 2] == b[pos + 2] then
                            local len = 2
                            while len < maxl and b[cp + len] == b[pos + len] do len = len + 1 end
                            if len > blen then blen = len; bdist = dist end
                            if blen == LZ_MAX then break end
                        end
                    end
                end
            end
        end
        hashAdd(pos)
        if blen >= LZ_MIN then
            flushLits()
            out[#out+1] = string.char(0x80 + blen - LZ_MIN, bdist - 1)
            for i = 1, blen - 1 do hashAdd(pos + i) end
            pos = pos + blen
        else
            lits[#lits+1] = string.char(b[pos])
            pos = pos + 1
            if #lits == 128 then flushLits() end
        end
    end
    flushLits()
    return table.concat(out)
end

local function lzDecompress(input)
    local n, out, outlen, pos = #input, {}, 0, 1
    while pos <= n do
        local flag = input:byte(pos); pos = pos + 1
        if flag < 0x80 then
            local cnt = flag + 1
            for i = pos, pos + cnt - 1 do outlen = outlen + 1; out[outlen] = input:sub(i, i) end
            pos = pos + cnt
        else
            local length = (flag - 0x80) + LZ_MIN
            local dist   = input:byte(pos) + 1; pos = pos + 1
            local from   = outlen - dist + 1
            for i = 0, length - 1 do outlen = outlen + 1; out[outlen] = out[from + (i % dist)] end
        end
    end
    return table.concat(out)
end

local function compress(data)
    local c = lzCompress(data)
    if #c + #COMPRESS_MAGIC < #data then return COMPRESS_MAGIC .. c end
    return data
end

local function decompress(data)
    if data:sub(1, #COMPRESS_MAGIC) == COMPRESS_MAGIC then
        return lzDecompress(data:sub(#COMPRESS_MAGIC + 1))
    end
    return data
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
        -- Compress on this node if the controller requested it, keeping CPU
        -- off the controller. Only store the compressed form when it's smaller.
        local payload = msg.compress and compress(msg.data) or msg.data
        local f, err = fs.open(path, "w")
        if not f then
            rednet.send(sender, {ok=false, err=tostring(err)}, PROTOCOL)
            return
        end
        f.write(payload); f.close()
        -- Return stored size so the controller can log the compression ratio.
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/"), stored=#payload}, PROTOCOL)

    elseif cmd == "get" then
        local path = "store/"..(msg.path or "")
        if not fs.exists(path) then
            rednet.send(sender, {ok=false}, PROTOCOL)
            return
        end
        local f = fs.open(path, "r")
        local raw = f.readAll(); f.close()
        -- Decompress transparently — works for both old (controller-compressed)
        -- and new (node-compressed) files; passes through uncompressed data.
        rednet.send(sender, {ok=true, data=decompress(raw)}, PROTOCOL)

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
