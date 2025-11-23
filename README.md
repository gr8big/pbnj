# PB&J API

An interface for connecting Roblox game server to remote, self-hosted applications.

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
For a more detailed example, see [example.py](./example.py).

A websocket-based manager is also available, but this will not be fully maintained and recommended until Roblox releases websocket support in live experiences.
