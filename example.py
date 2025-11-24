#!/usr/bin/python3

# This file is part of PB\&J.

# PB\&J is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 3, or (at your option) any later
# version.

# PB\&J is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.

# You should have received a copy of the GNU General Public License
# along with PB\&J; see the file LICENSE.md.  If not see
# <http://www.gnu.org/licenses/>.

# don't use this in prod please

from pbnj import main, duplex
from argon2 import PasswordHasher
from quart import Quart, Response, request

# Prepare password hasher & PB&J command handler.

hasher = PasswordHasher()

cmd_handler = main.CommandHandler()

# Simple example command.

@cmd_handler.command("example")
async def cmd_example(pipe:main.CommandDuplexContext):
    print("Command received!")

    await pipe.send("Hello, world!")
    await pipe.close()

# Simple command using the `CommandDuplexContext` as a ctx manager.

@cmd_handler.command("example-context")
async def cmd_example_context(pipe:main.CommandDuplexContext):
    async with pipe as p:
        print("Context-manager command received!")

        await p.send("Hello, world!")

# Command showing a persistent duplex connection.

@cmd_handler.command("example-persistent")
async def cmd_example_persistent(pipe:main.CommandDuplexContext):
    async with pipe as p:
        print("Starting persistent command handler!")

        while True:
            await p.send(await p.recv())
            await p.send("Next message")

# Load a long-poll session manager for the API key `my key`.  
# > In a production environment you'd want to store the hashed key,
# and load that instead of hashing the plaintext key at runtime.

sessions = duplex.QuartLongPollSessionManager(
    cmd_handler,
    hasher.hash("my key"),
    hasher
)

# Prepare a simple quart app.

app = Quart(__name__)

# Home path is not needed but is recommended.

@app.route("/")
async def index():
    return "OK"

# `/auth` path is used to start a session.

@app.route("/auth", methods=["POST"])
async def auth():
    key = await request.get_data(False)
    ses = await sessions.authenticate(key)
    token = await ses.rotate_key(86400)
    
    response = Response("OK", 200)
    response.headers.set("X-Pbj-Session-Id", str(ses.id))
    response.headers.set("X-Pbj-Session", token)

    return response

# POST and PUT handlers for `/pbj` are linked to the session handler.

app.route("/pbj", methods=["POST"])(sessions.request_handler)
app.route("/pbj", methods=["PUT"])(sessions.push_handler)

# And run the app!

if __name__ == "__main__":
    app.run("127.0.0.1", 8080)
