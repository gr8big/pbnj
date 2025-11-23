#!/usr/bin/python3
# don't use this in prod please

from pbnj import main, duplex
from argon2 import PasswordHasher
from quart import Quart, Response, request

# prepare pb&j

hasher = PasswordHasher()

cmd_handler = main.CommandHandler()

@cmd_handler.command("example")
async def cmd_example(pipe:main.CommandDuplexContext):
    print("Command received!")

    await pipe.send("Hello, world!")
    await pipe.close()

@cmd_handler.command("example-context")
async def cmd_example_context(pipe:main.CommandDuplexContext):
    async with pipe as p:
        print("Context-manager command received!")

        await p.send("Hello, world!")

sessions = duplex.QuartLongPollSessionManager(
    cmd_handler,
    hasher.hash("my key"),
    hasher
)

# prepare quart app

app = Quart(__name__)

@app.route("/")
async def index():
    return "OK"

@app.route("/auth", methods=["POST"])
async def auth():
    key = await request.get_data(False)
    ses = await sessions.authenticate(key)
    token = await ses.rotate_key(86400)
    
    response = Response("OK", 200)
    response.headers.set("X-Pbj-Session-Id", str(ses.id))
    response.headers.set("X-Pbj-Session", token)

    return response

app.route("/pbj", methods=["POST"])(sessions.request_handler)
app.route("/pbj", methods=["PUT"])(sessions.push_handler)

# and run

if __name__ == "__main__":
    app.run("127.0.0.1", 8080)
