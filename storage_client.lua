-- CC:Tweaked Media Storage Client
-- Pre-load videos from GitHub onto the storage network, then play them
-- back at full speed without downloading during playback.
--
-- PREREQUISITES
--   1. storage_server.lua      running on each node computer
--   2. storage_controller.lua  running on one controller computer
--   3. storage_api.lua         copied to THIS computer (same folder)
--
-- USAGE: lua storage_client.lua

local store = require("storage_api")

local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"

-- ── Index / manifest loading ────────────────────────────────────────────────
local function loadIndex()
    local res = http.get(GITHUB_RAW.."/output/index.lua")
    if not res then error("Could not fetch index from GitHub") end
    local data = res.readAll(); res.close()
    local f = fs.open("sc_tmp.lua", "w"); f.write(data); f.close()
    local fn = loadfile("sc_tmp.lua"); fs.delete("sc_tmp.lua")
    if not fn then error("Could not parse index") end
    local ok, r = pcall(fn)
    if not ok or type(r) ~= "table" then return {video={}, audio={}} end
    r.video = r.video or {}; r.audio = r.audio or {}
    return r
end

local function loadManifest(name)
    local res = http.get(GITHUB_RAW.."/output/"..name.."/manifest.lua")
    if not res then error("Could not fetch manifest for "..name) end
    local data = res.readAll(); res.close()
    local f = fs.open("sc_tmp.lua", "w"); f.write(data); f.close()
    local fn = loadfile("sc_tmp.lua"); fs.delete("sc_tmp.lua")
    if not fn then error("Bad manifest") end
    return fn()
end

-- ── Pre-load a video onto the storage network ───────────────────────────────
local function loadVideo(name, manifest)
    local count = manifest.frame_count or 0
    local fext  = manifest.frame_ext or "nfp"
    local audio = manifest.has_audio == "true"
    print("[loader] Pre-loading "..name.."  frames="..count.."  ext="..fext)

    if audio then
        io.write("  Downloading audio... ")
        local res = http.get(GITHUB_RAW.."/output/"..name.."/audio.dfpwm", nil, true)
        if res then
            local data = res.readAll(); res.close()
            local ok, err = store.put(name.."/audio.dfpwm", data)
            if ok then print("stored") else print("FAILED: "..tostring(err)) end
        else print("FAILED (download)") end
    end

    local stored = 0; local failed = 0
    for i = 1, count do
        local fname = string.format("%06d.%s", i, fext)
        local key   = name.."/frames/"..fname
        local res   = http.get(GITHUB_RAW.."/output/"..name.."/frames/"..fname)
        if res then
            local data = res.readAll(); res.close()
            local ok, err = store.put(key, data)
            if ok then stored = stored + 1
            else failed = failed + 1; print("\n  FAILED frame "..i..": "..tostring(err)); break end
        else failed = failed + 1 end
        if i % 20 == 0 or i == count then
            io.write("\r  Frames: "..stored.."/"..count.." stored, "..failed.." failed  ")
        end
    end
    print("\n  Done. "..stored.."/"..count.." frames stored.")
    return stored
end

-- ── Delete all stored keys for a video ─────────────────────────────────────
local function wipeVideo(name)
    print("Wiping "..name.." from storage network...")
    local keys, err = store.list(name.."/")
    if not keys then print("Error: "..tostring(err)); return end
    local n = 0
    for _, k in ipairs(keys) do store.delete(k); n = n + 1 end
    print("  Deleted "..n.." key(s).")
end

-- ── Playback from storage network ───────────────────────────────────────────
local BLIT = "0123456789abcdef"
local function renderLines(mon, lines)
    local nh = #lines; if nh == 0 then return end
    local nw = #lines[1]; if nw == 0 then return end
    local mw, mh = mon.getSize()
    for row = 1, mh do
        local srcRow = math.max(1, math.min(nh, math.ceil(row * nh / mh)))
        local line   = lines[srcRow]
        for col = 1, mw do
            local srcCol = math.max(1, math.min(nw, math.ceil(col * nw / mw)))
            local c = line:sub(srcCol, srcCol)
            local ci = BLIT:find(c, 1, true)
            if ci then local bc = BLIT:sub(ci,ci); mon.setCursorPos(col,row); mon.blit(" ",bc,bc) end
        end
    end
end

local function decodeNFP(data)
    local lines = {}
    for line in (data.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = line end
    return lines
end

local function decodeNFPC(data)
    local lines = {}
    for rowstr in (data.."\n"):gmatch("([^\n]*)\n") do
        local line = ""
        for run in (rowstr.."|"):gmatch("([^|]*)|") do
            local c, n = run:match("^(.):(%d+)$")
            if c and n then line = line .. c:rep(tonumber(n)) end
        end
        lines[#lines+1] = line
    end
    return lines
end

local function playFromNetwork(name, manifest)
    local fps   = manifest.fps or 5
    local count = manifest.frame_count or 0
    local fext  = manifest.frame_ext or "nfp"
    local audio = manifest.has_audio == "true"
    local mon   = peripheral.find("monitor")
    if mon then mon.setTextScale(0.5) end
    local speakers = {peripheral.find("speaker")}
    print("[player] monitor="..tostring(mon~=nil).."  speakers="..#speakers)

    local function audioLoop()
        if not audio or #speakers == 0 then return end
        local data, err = store.get(name.."/audio.dfpwm")
        if not data then print("[player] Audio not on network: "..tostring(err)); return end
        local tmp = "sc_audio_tmp.dfpwm"
        local f = fs.open(tmp, "wb"); f.write(data); f.close()
        local dfpwm = require("cc.audio.dfpwm")
        local decoder = dfpwm.make_decoder()
        local fh = fs.open(tmp, "rb")
        while true do
            local chunk = fh.read(16384)
            if not chunk then break end
            local pcm = decoder(chunk)
            local busy = true
            while busy do
                busy = false
                for _, spk in ipairs(speakers) do
                    if not spk.playAudio(pcm) then busy = true end
                end
                if busy then os.pullEvent("speaker_audio_empty") end
            end
        end
        fh.close(); fs.delete(tmp)
    end

    local t0 = os.clock(); local skipped = 0
    local function videoLoop()
        for frame = 1, count do
            local due     = (frame - 1) / fps
            local elapsed = os.clock() - t0
            local key     = name.."/frames/"..string.format("%06d.%s", frame, fext)
            local data    = store.get(key)
            if elapsed <= due + (1/fps) then
                local wait = due - elapsed
                if wait > 0 then os.sleep(wait) end
                if data and mon then
                    local lines = (fext == "nfpc") and decodeNFPC(data) or decodeNFP(data)
                    renderLines(mon, lines)
                end
            else
                skipped = skipped + 1
            end
        end
        if skipped > 0 then print("[player] Skipped "..skipped.." frame(s).") end
    end

    print("[player] Playing "..name.." from storage network...")
    if audio and count > 0 then parallel.waitForAll(audioLoop, videoLoop)
    elseif audio then audioLoop()
    elseif count > 0 then videoLoop() end
    print("\n[player] Done. Press Enter..."); io.read()
end

-- ── Menus ────────────────────────────────────────────────────────────────────
local function drawMenu(title, items)
    term.clear(); term.setCursorPos(1,1)
    print("===========================")
    print("  Media Storage | "..title)
    print("===========================")
    if #items == 0 then print("  (none)") end
    for i, item in ipairs(items) do
        print("  "..i..". "..tostring(item))
    end
    print("---------------------------"); print("  0. Back"); print()
    io.write("Select: ")
    local n = tonumber(io.read())
    if not n or n == 0 then return nil end
    return items[n]
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    term.clear(); term.setCursorPos(1,1)
    print("=== CC:T Media Storage Client ==="); print()

    local info, err = store.stats()
    if not info then
        print("Could not reach storage controller: "..tostring(err))
        print("Make sure storage_controller.lua is running.")
        return
    end
    print("Network: "..#info.nodes.." node(s)  |  Free: "..math.floor(info.totalFree/1024).."KB / "..math.floor(info.totalCap/1024).."KB")
    print()

    while true do
        term.clear(); term.setCursorPos(1,1)
        local info2  = store.stats()
        local freeKB = info2 and math.floor(info2.totalFree/1024) or "?"
        local kcount = info2 and info2.keyCount or "?"
        print("=== Media Storage Client ===")
        print("  Free: "..tostring(freeKB).."KB  |  Keys: "..tostring(kcount))
        print("============================")
        print("  1. Pre-load video onto network")
        print("  2. Play video from network")
        print("  3. Wipe a video from network")
        print("  4. Wipe ALL data from network")
        print("  5. Network stats")
        print("  Q. Quit"); print()
        io.write("Choice: ")
        local inp = (io.read() or ""):lower()

        if inp == "q" then return

        elseif inp == "1" then
            print("Fetching index from GitHub...")
            local ok, idx = pcall(loadIndex)
            if not ok then print("Error: "..tostring(idx)); io.read(); goto continue end
            if #idx.video == 0 then print("No videos in index."); os.sleep(1); goto continue end
            local pick = drawMenu("Choose video to pre-load", idx.video)
            if pick then
                local ok2, manifest = pcall(loadManifest, pick)
                if not ok2 then print("Error: "..tostring(manifest)); io.read()
                else loadVideo(pick, manifest) end
                io.read()
            end

        elseif inp == "2" then
            print("Fetching index from GitHub...")
            local ok, idx = pcall(loadIndex)
            if not ok then print("Error: "..tostring(idx)); io.read(); goto continue end
            if #idx.video == 0 then print("No videos."); os.sleep(1); goto continue end
            local pick = drawMenu("Choose video to play", idx.video)
            if pick then
                local ok2, manifest = pcall(loadManifest, pick)
                if not ok2 then print("Error: "..tostring(manifest)); io.read()
                else playFromNetwork(pick, manifest) end
            end

        elseif inp == "3" then
            print("Fetching index from GitHub...")
            local ok, idx = pcall(loadIndex)
            if not ok then print("Error: "..tostring(idx)); io.read(); goto continue end
            if #idx.video == 0 then print("No videos."); os.sleep(1); goto continue end
            local pick = drawMenu("Choose video to wipe", idx.video)
            if pick then wipeVideo(pick); io.read() end

        elseif inp == "4" then
            io.write("Wipe ALL stored data from the network? (y/n): ")
            if (io.read() or ""):lower() == "y" then
                print("Listing all keys...")
                local ks, e2 = store.list()
                if not ks then print("Error: "..tostring(e2))
                else
                    local n = 0
                    for _, k in ipairs(ks) do store.delete(k); n = n + 1 end
                    print("Deleted "..n.." key(s).")
                end
                io.read()
            end

        elseif inp == "5" then
            local si, se = store.stats()
            if not si then print("Error: "..tostring(se))
            else
                print("Keys:        "..si.keyCount)
                print("Free:        "..math.floor(si.totalFree/1024).."KB / "..math.floor(si.totalCap/1024).."KB")
                print("Replication: "..si.replication.."x")
                print("Nodes ("..#si.nodes.."):")
                for _, nd in ipairs(si.nodes) do
                    print("  "..nd.label.."  free="..math.floor(nd.free/1024).."KB")
                end
            end
            io.read()
        end
        ::continue::
    end
end

main()
