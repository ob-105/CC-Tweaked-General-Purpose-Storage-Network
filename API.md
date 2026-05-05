# Storage API Reference

`storage_api.lua` is a library you drop on any CC:Tweaked computer to read and write data to the storage network. The controller handles all the distribution and redundancy — your code just calls simple functions.

---

## Installation

Run this on the client computer once:
```
wget https://raw.githubusercontent.com/ob-105/CC-Tweaked-General-Purpose-Storage-Network/main/storage_api.lua storage_api.lua
```

Then at the top of your script:
```lua
local store = require("storage_api")
```

The API will automatically find the controller on the network. If the controller restarts, call `store.reconnect()`.

---

## Keys

A **key** is just a string that names your data. Slashes create namespaces (like folders) and make `list()` filtering useful:

```
"config/motd"
"players/steve/score"
"players/steve/inventory"
"world/spawn"
```

---

## Functions

---

### `store.put(key, data)`
**Store data under a key.**

- `key` — any non-empty string
- `data` — string, number, boolean, or table (non-strings are auto-serialized)
- Returns `true, replicaCount` on success, or `false, errorMessage` on failure

```lua
store.put("config/motd", "Welcome!")
store.put("players/steve/score", 9001)
store.put("world/spawn", {x=0, y=64, z=0})
```

Putting to an existing key **overwrites** it.

---

### `store.get(key)`
**Retrieve data by key.**

- Returns the stored value as a **string**, or `nil, errorMessage` if not found
- Tables/numbers you stored with `put()` come back serialized — use `textutils.unserialize()` to convert them back

```lua
local motd  = store.get("config/motd")
-- motd = "Welcome!"

local score = tonumber(store.get("players/steve/score"))
-- score = 9001

local spawn = textutils.unserialize(store.get("world/spawn"))
-- spawn = {x=0, y=64, z=0}
```

---

### `store.exists(key)`
**Check if a key is stored without fetching its data.**

- Returns `true` or `false`, or `nil, errorMessage` if the controller is unreachable

```lua
if store.exists("players/steve/score") then
    print("Steve has a score!")
end
```

---

### `store.delete(key)`
**Remove a key from the network.**

- Deletes from all replicas automatically
- Returns `true`, or `false, errorMessage`

```lua
store.delete("players/steve/score")
```

---

### `store.list([prefix])`
**List stored keys, optionally filtered by prefix.**

- Returns a sorted array of key strings
- Pass a prefix to narrow results — use a trailing `/` to scope to a namespace
- Returns `nil, errorMessage` if the controller is unreachable

```lua
-- All keys
local all = store.list()

-- Only keys under "players/"
local playerKeys = store.list("players/")
-- {"players/alex/score", "players/steve/inventory", "players/steve/score"}

-- Iterate
for _, key in ipairs(playerKeys) do
    print(key)
end
```

---

### `store.stats()`
**Get information about the storage network.**

- Returns a table, or `nil, errorMessage`

```lua
local info = store.stats()

print("Keys stored:    " .. info.keyCount)
print("Free space:     " .. math.floor(info.totalFree / 1024) .. " KB")
print("Total capacity: " .. math.floor(info.totalCap  / 1024) .. " KB")
print("Nodes online:   " .. #info.nodes)
print("Replication:    " .. info.replication .. "x")

-- Per-node breakdown
for _, n in ipairs(info.nodes) do
    print(n.label .. "  free: " .. math.floor(n.free / 1024) .. " KB")
end
```

Fields on `info`:
| Field | Type | Description |
|-------|------|-------------|
| `keyCount` | number | Total keys stored |
| `totalFree` | number | Free bytes across all nodes |
| `totalCap` | number | Total capacity across all nodes |
| `nodes` | table | Array of `{id, label, free, cap}` per node |
| `replication` | number | Current replication factor |

---

### `store.rescan()`
**Tell the controller to search for nodes again.**

Useful after adding new storage node computers to the network.

- Returns `true, nodeCount`, or `false, errorMessage`

```lua
local ok, count = store.rescan()
print(count .. " node(s) found")
```

---

### `store.reconnect()`
**Re-discover the controller on the network.**

Call this if the controller computer was restarted and calls are failing.

- Returns `true`, or `false, errorMessage`

```lua
store.reconnect()
```

---

## Full Example

```lua
local store = require("storage_api")

-- Save a player's data
local function savePlayer(name, data)
    local ok, err = store.put("players/" .. name, data)
    if not ok then
        print("Save failed: " .. err)
    end
end

-- Load a player's data
local function loadPlayer(name)
    if not store.exists("players/" .. name) then
        return nil
    end
    return textutils.unserialize(store.get("players/" .. name))
end

-- Delete a player
local function deletePlayer(name)
    store.delete("players/" .. name)
end

-- List all online players with saved data
local function listPlayers()
    return store.list("players/")
end

savePlayer("steve", {score=100, level=5, items={"sword","torch"}})
local data = loadPlayer("steve")
print(data.score)  -- 100
```

---

## Error Handling

All functions return `nil` or `false` as the first value on failure, with an error string as the second. It is good practice to check:

```lua
local data, err = store.get("some/key")
if not data then
    print("Error: " .. tostring(err))
    return
end
```
