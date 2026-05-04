# CC:Tweaked General-Purpose Storage Network

A distributed storage system for CC:Tweaked that uses multiple computers as storage nodes, controlled by a single main computer. Any computer on the network can store and retrieve arbitrary data through a simple API.

---

## How It Works

```
[ API Client ]  ──cct-store-ctrl──►  [ Controller ]  ──cct-media-store──►  [ Node 1 ]
                                                                        ──►  [ Node 2 ]
                                                                        ──►  [ Node N ]
```

- **Storage Nodes** hold the actual data on their local filesystems (~1MB each by default in CC:Tweaked)
- **The Controller** discovers nodes, distributes writes across them, and maintains an index of where every key lives
- **API Clients** are any computers that need to read/write data — they talk only to the controller

---

## Files

| File | Runs On | Purpose |
|---|---|---|
| `storage_server.lua` | Every storage node | Node daemon — listens for read/write commands |
| `storage_controller.lua` | Main/controller computer | Discovers nodes, routes all requests, manages the index |
| `storage_api.lua` | Any client computer | Library — copy here and `require` it |

---

## Setup

### 1. Physical connections
Connect all storage node computers and the controller computer together using **Wired Modems** and **Networking Cable**. Right-click each modem to attach it to its computer.

### 2. Storage nodes
On **each** storage node computer:
1. Copy `storage_server.lua` to the computer
2. To run it automatically on boot, save it as `startup.lua`
3. Or run it manually: `lua storage_server.lua`

### 3. Controller computer
On the **one** main/controller computer:
1. Copy `storage_controller.lua` to the computer
2. To run it automatically on boot, save it as `startup.lua`
3. Or run it manually: `lua storage_controller.lua`

On startup it will scan for nodes and print how many it found and how much total space is available.

### 4. Client computers
On any computer that needs to use the storage network:
1. Copy `storage_api.lua` to the computer (must be named `storage_api.lua`)
2. Use `require("storage_api")` in your code (see examples below)

---

## API Reference

```lua
local store = require("storage_api")
```

### `store.put(key, data)` → `true, replicaCount` or `false, error`
Store data under a key. The key can be any non-empty string — slashes are a good way to namespace keys (e.g. `"players/steve/inventory"`). Data can be a string, number, boolean, or table (non-strings are auto-serialized).

```lua
store.put("config/motd", "Welcome to the server!")
store.put("players/steve/score", 9001)
store.put("world/spawn", {x=0, y=64, z=0})
```

### `store.get(key)` → `string` or `nil, error`
Retrieve a stored value. Always returns a string — use `textutils.unserialize()` if you stored a table or number.

```lua
local motd  = store.get("config/motd")
local score = tonumber(store.get("players/steve/score"))
local spawn = textutils.unserialize(store.get("world/spawn"))
```

### `store.exists(key)` → `true/false` or `nil, error`
Check whether a key is stored without fetching its data.

```lua
if store.exists("players/steve/score") then ... end
```

### `store.delete(key)` → `true` or `false, error`
Remove a key from all nodes it was replicated to.

```lua
store.delete("players/steve/score")
```

### `store.list([prefix])` → `{key, key, ...}` or `nil, error`
List all stored keys, sorted alphabetically. Pass an optional prefix string to filter results.

```lua
local all    = store.list()            -- every key
local players = store.list("players/") -- only player keys
```

### `store.stats()` → table or `nil, error`
Get information about the storage network.

```lua
local info = store.stats()
print("Keys stored: "  .. info.keyCount)
print("Free space: "   .. math.floor(info.totalFree / 1024) .. "KB")
print("Total capacity: ".. math.floor(info.totalCap  / 1024) .. "KB")
print("Nodes online: " .. #info.nodes)
print("Replication: "  .. info.replication .. "x")

for _, n in ipairs(info.nodes) do
    print(n.label .. " | free: " .. math.floor(n.free/1024) .. "KB")
end
```

### `store.rescan()` → `true, nodeCount` or `false, error`
Tell the controller to search for nodes again. Use this after adding new storage node computers to the network.

```lua
local ok, count = store.rescan()
print(count .. " node(s) found")
```

### `store.reconnect()` → `true` or `false, error`
Force the client to rediscover the controller. Call this if the controller computer was restarted.

```lua
store.reconnect()
```

---

## Configuration

Open `storage_controller.lua` and edit the values at the top:

```lua
local REPLICATION  = 2   -- copies of each key written to different nodes
local RESCAN_EVERY = 60  -- seconds between automatic node rescans
local NODE_TIMEOUT = 5   -- seconds to wait for a node to respond
```

- **`REPLICATION = 1`** — no redundancy, maximum usable storage
- **`REPLICATION = 2`** — one node can die and data survives (recommended)
- **`REPLICATION = 3`** — two nodes can die and data survives

---

## Scaling

Adding more storage is as simple as:
1. Set up another computer with `storage_server.lua`
2. Connect it to the network with a wired modem and cable
3. Run `store.rescan()` from any client, or wait up to 60 seconds for the controller to auto-detect it

---

## Troubleshooting

**"No modem found!"**
Make sure a Wired Modem is attached to the computer and you have right-clicked it to connect it.

**"No storage nodes found"**
- Check that `storage_server.lua` is running on the node computers
- Make sure all modems are attached and cables are connecting the computers
- Run `store.rescan()` or restart the controller

**"No storage controller found"**
- Check that `storage_controller.lua` is running on the controller computer
- Call `store.reconnect()` on the client if the controller was restarted

**Data survived a node restart?**
Yes — the controller's index (`ctrl_index.dat`) persists to disk. As long as the physical files on the node are intact, data is recoverable after a restart.

**Data survived a controller restart?**
Yes — the index is reloaded from `ctrl_index.dat` on startup.
