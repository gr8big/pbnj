# PB&J API

An interface for connecting Roblox game server to remote, self-hosted applications.

## Install

### Server Install

At some point this project might have proper install instructions.  

For now, just use the repository as a module. Clone it (or add as a submodule) somewhere in the project's python path, and then:  
```py
import pbnj
```

### Client Install

Installing on the client (a Roblox experience) is as simple as inserting the `client` directory into a place. Afterwards, it can be loaded with:
```lua
local libpbj = require("path.to.libpbj")
```

Ideally, the directory should be in a server-only location (mainly `ServerStorage`), since it uses server-only APIs.  
Alternatively, you can use this directory as the basis for a Rojo instance, as the included [project file](./default.project.json) will load the module into `game.ServerStorage.libpbj`.

## Server Usage

PB&J consists of two main components: the server (your application) and the client (the Roblox game server). It is recommended to use one of the Quart-based handlers provided in `duplex`.

An example using `duplex.QuartLongPollSessionManager`:
```py
from quart import Quart
from pbnj import CommandHandler
from pbnj.duplex import QuartLongPollSessionManager

commands = CommandHandler()
# Prepare commands

manager = QuartLongPollSessionManager(commands, "api key")

app = Quart(__name__)

@app.route("/pbj", methods=["POST"])(manager.request_handler)
@app.route("/pbj", methods=["PUT"])(manager.push_handler)
```

The result is a PB&J instance available at `/pbj`.  
For a more detailed example, see [example.py](./example/example.py).

A websocket-based manager is also available, but this will not be fully maintained and recommended until Roblox releases websocket support in live experiences.

## Client Usage

To connect to a PB&J server, you need the API URL and the auth URL. Once the `client` directory is inside a Roblox instance (ideally under `ServerStorage`), you can require `libpbj.luau` and construct an API.  
After constructing it, a simple `connect()` call will start sending messages to & from the server, and commands can be run.  

For example:  
```lua
local libpbj = require("game.ServerStorage.libpbj.libpbj")

local api = libpbj.new("https://example.com/pbj")
api:connect("my key", "https://example.com/auth")

-- The API object is now ready to run commands!
```

For a more detailed example, see [example.luau](./example/example.luau).

## Licensing

This project is licensed under the GNU GPL v3. For more details see [LICENSE.md](./LICENSE.md).
