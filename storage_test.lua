-- Storage Network Test Script
-- Run this on any client computer to verify the network is working.
-- Requires: storage_api.lua on the same computer, controller + nodes online.

local store = require("storage_api")

local passed = 0
local failed = 0

local function setColour(c)
    if term.isColour and term.isColour() then term.setTextColour(c) end
end

local function ok(name)
    passed = passed + 1
    setColour(colours.lime)
    print("  [PASS] " .. name)
    setColour(colours.white)
end

local function fail(name, reason)
    failed = failed + 1
    setColour(colours.red)
    print("  [FAIL] " .. name .. " -- " .. tostring(reason))
    setColour(colours.white)
end

local function section(name)
    print()
    setColour(colours.yellow)
    print(">> " .. name)
    setColour(colours.white)
end

-- ── 1. Controller reachability ─────────────────────────────────────────────
section("Controller")

local info, err = store.stats()
if info then
    ok("Controller found")
    print(("     Nodes: %d  |  Keys: %d  |  Free: %dKB"):format(
        #info.nodes, info.keyCount, math.floor(info.totalFree / 1024)))
    if #info.nodes == 0 then
        fail("Nodes online", "0 nodes found — are storage_server.lua nodes running?")
    else
        ok(#info.nodes .. " node(s) online")
    end
else
    fail("Controller found", err)
    print()
    print("Cannot continue without a controller. Check:")
    print("  - storage_controller.lua is running on the controller computer")
    print("  - All modems are attached (dark colour) and cables are connected")
    print("  - This computer has a modem attached")
    return
end

-- ── 2. Store (upload) ──────────────────────────────────────────────────────
section("Storing data")

local ok1, e1 = store.put("_test/string", "hello network")
if ok1 then ok("Store string") else fail("Store string", e1) end

local ok2, e2 = store.put("_test/number", 42)
if ok2 then ok("Store number") else fail("Store number", e2) end

local ok3, e3 = store.put("_test/table", {a=1, b="two", c=true})
if ok3 then ok("Store table") else fail("Store table", e3) end

local big = string.rep("x", 4096)
local ok4, e4 = store.put("_test/large", big)
if ok4 then ok("Store 4KB blob") else fail("Store 4KB blob", e4) end

-- ── 3. Exists check ────────────────────────────────────────────────────────
section("Exists checks")

local ex1 = store.exists("_test/string")
if ex1 == true  then ok("exists() true for stored key")  else fail("exists() true",  ex1) end

local ex2 = store.exists("_test/doesnotexist_xyz")
if ex2 == false then ok("exists() false for missing key") else fail("exists() false", ex2) end

-- ── 4. Retrieve (download) ─────────────────────────────────────────────────
section("Retrieving data")

local v1, re1 = store.get("_test/string")
if v1 == "hello network" then ok("Retrieve string")
else fail("Retrieve string", ("got %q, want %q"):format(tostring(v1), "hello network")) end

local v2, re2 = store.get("_test/number")
if tonumber(v2) == 42 then ok("Retrieve number")
else fail("Retrieve number", ("got %q, want 42"):format(tostring(v2))) end

local v3, re3 = store.get("_test/table")
local t3 = v3 and textutils.unserialize(v3)
if type(t3) == "table" and t3.a == 1 and t3.b == "two" and t3.c == true then
    ok("Retrieve table")
else
    fail("Retrieve table", ("got %s"):format(tostring(v3)))
end

local v4, re4 = store.get("_test/large")
if v4 and #v4 == 4096 then ok("Retrieve 4KB blob")
else fail("Retrieve 4KB blob", ("got %d bytes, want 4096"):format(v4 and #v4 or 0)) end

local vmiss = store.get("_test/doesnotexist_xyz")
if vmiss == nil then ok("get() nil for missing key")
else fail("get() nil for missing key", "expected nil, got a value") end

-- ── 5. List ────────────────────────────────────────────────────────────────
section("Listing keys")

local keys, le = store.list("_test/")
if type(keys) == "table" and #keys >= 4 then
    ok("list() returned " .. #keys .. " key(s) under _test/")
else
    fail("list()", le or ("got " .. tostring(keys)))
end

-- ── 6. Delete ──────────────────────────────────────────────────────────────
section("Deleting data")

for _, k in ipairs{"_test/string", "_test/number", "_test/table", "_test/large"} do
    store.delete(k)
end

local gone = store.exists("_test/string")
if gone == false then ok("Keys removed after delete")
else fail("Keys removed after delete", "key still exists") end

-- ── Summary ────────────────────────────────────────────────────────────────
print()
print(string.rep("=", 40))
if failed == 0 then
    setColour(colours.lime)
    print(("All %d tests passed! Network is working."):format(passed))
else
    setColour(colours.red)
    print(("%d passed, %d FAILED"):format(passed, failed))
    print()
    print("Troubleshooting:")
    print("  - Make sure storage_controller.lua is running")
    print("  - Make sure at least one storage_server.lua node is online")
    print("  - Check all modems are attached and cables are connected")
    print("  - Try pressing R on the controller to rescan nodes")
end
setColour(colours.white)
