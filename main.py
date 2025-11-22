import io
import os
import json
import time
import typing
import asyncio
from nacl import bindings
from hashlib import sha3_512
from argon2 import PasswordHasher

# this

T_Expect = typing.TypeVar("T_Expect", str, bytes)

# constants

COMMAND_ROOT = b"\xff\xff\xff\xff"

FRAME_NULL = b"\x00"
FRAME_BINARY = b"\x40"
FRAME_TEXT = b"\x41"
FRAME_JSON = b"\x50"
FRAME_EOF = b"\xff"

STATUS_OK = b"\x00"
STATUS_NOTFOUND = b"\xa0"

# exceptions

class CommandError(RuntimeError):
    "Base class for command-related errors"
class InternalCommandError(CommandError):
    "Error in user-provided command handler"

# utility

async def pack_eof(status:bytes, message:str) -> bytes:
    raw = bytes(message, "utf8")
    return status + len(raw).to_bytes(1, "little", signed=False) + raw

async def pack_frame(v:typing.Any) -> bytes:
    if isinstance(v, str):
        return FRAME_TEXT + bytes(v, "utf8")
    elif isinstance(v, bytes):
        return FRAME_BINARY + v
    elif (isinstance(v, list)
            or isinstance(v, dict)
            or isinstance(v, float)
            or isinstance(v, int)
            or isinstance(v, bool)):
        return FRAME_JSON + bytes(json.dumps(v), "utf8")

# session class

class Session:
    def __init__(self, id:int):
        self.id = id
        self.token = b""
        self.expiry = 0
        self.dead = False
        self.__close_hook = []

    def on_close(self, callback:typing.Callable[[typing.Self],typing.Awaitable[None]]):
        "Add a hook to run on close."

        self.__close_hook.append(callback)


    async def rotate_key(self, lifetime:float=30) -> str:
        "Generate a new session token, returning the client auth."

        if self.dead is True:
            raise RuntimeError("Cannot rotate a closed session")

        token = sha3_512(os.urandom(64)).hexdigest()
        self.token = sha3_512(bytes(token, "utf8")).digest()
        self.expiry = time.perf_counter() + lifetime

        return token

    async def validate(self, sent:str, bump_by:float=30) -> bool:
        "Validate a client-sent session token, returning `True` if it is valid."
        
        self.expiry = time.perf_counter() + bump_by

        if self.dead is True:
            return False

        if bindings.sodium_memcmp(self.token, sha3_512(bytes(sent, "utf8")).digest()) is True:
            return True
        return False
    
    async def close(self):
        "Close the session and mark it invalid, running all close hooks afterwards."

        self.dead = True
        self.expiry = 0

        for i in self.__close_hook:
            await i()

# session handler

class SessionHandler:
    __ses: dict[int,Session]

    def __init__(self, key:str|bytes, hasher:PasswordHasher|None=None):
        if hasher is None:
            hasher = PasswordHasher()

        self.__id_prog = 0
        self.__ses = {}
        self.__key = key
        self.__hasher = hasher
    
    async def test_session(self, id:int, token:str) -> Session:
        """Test a session ID and token, returning it on success.  
        Raises `ValueError` if the session is invalid."""

        if id in self.__ses:
            if await self.__ses[id].validate(token) is True:
                return self.__ses[id]
        
        raise ValueError("Invalid session")

    async def start_session(self) -> Session:
        "Start a new uninitialized session."

        ses = Session(cur_id)

        cur_id = self.__id_prog + 1
        self.__id_prog = cur_id

        self.__ses[cur_id] = ses
        return ses
    
    async def authenticate(self, key:str|bytes) -> Session:
        "Start an uninitialized session if the key is valid."

        if await asyncio.to_thread(self.__hasher.verify, self.__key, key) is True:
            return await self.start_session()

# base duplex handler

class BaseDuplexHandler:
    def __init__(self):
        raise RuntimeError("Do not use BaseDuplexHandler")
    
    async def send(self, data:bytes):
        "Send binary data to the client."
        pass

    async def recv(self, cmd:bytes) -> bytes:
        "Receive binary data from the client."
        pass

    async def clean(self, cmd:bytes):
        "Clean any data used to handle messages for a specific command."
        pass

# commands

class CommandDuplexContext:
    """Communication manager for active commands.  
    Can be used as an async context manager, that is:
    ```
    async with context as c:
        await c.send(data)
        # Do something else
    ```

    This automatically sends an OK response afterwards.  
    Alternatively, `context.close()` can be called with a custom status and reason."""

    def __init__(self, wraps:BaseDuplexHandler, cmd_id:bytes):
        self.__wraps = wraps
        self.__cmd = cmd_id
    
    async def send(self, data:str|bytes|dict|list|int|float):
        await self.__wraps.send(self.__cmd + await pack_frame(data))

    async def recv(self) -> str|bytes|dict|list|int|float|None:
        data = await self.__wraps.recv(self.__cmd)
        frame = data[:1]
        data = data[1:]

        match frame:
            case b"\x00":
                return None
            case b"\x40":
                return data
            case b"\x41":
                return str(data, "utf8")
            case b"\x50":
                return json.loads(data)
    
    async def close(self, status:bytes=b"\x00", reason:str="pbj:ok"):
        await self.__wraps.send(await pack_eof(status, reason))

    async def __aenter__(self):
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if exc_type is not None:
            raise InternalCommandError(
                f"Error while handling command ID {int.from_bytes(self.__cmd, 'little', signed=False)}"
            ) from exc_val

        await self.close()
        return False

class CommandHandler:
    def __init__(self):
        self.__commands = {}

    def command(self, id:str|bytes):
        """Define a command handler.  
        The callback must accept a single `CommandDuplexContext` argument."""

        if isinstance(id, str):
            id = bytes(id, "utf8")

        def wrapper(callback:typing.Callable[[CommandDuplexContext],typing.Awaitable[None]]):
            self.__commands[id] = callback
            return callback
        return wrapper
    
    def has(self, cmd:bytes):
        return cmd in self.__commands
    
    def get(self, cmd:bytes):
        return self.__commands[cmd]


class CommandManager:
    def __init__(self, around:BaseDuplexHandler, commands:CommandHandler):
        self.__wraps = around
        self.__commands = commands

    async def run(self):
        "Start listening for commands."

        while True:
            initiator = io.BytesIO(await self.__wraps.recv(COMMAND_ROOT))
            cmd_id = initiator.read(4)
            handler = initiator.read(int.from_bytes(initiator.read(1), "little", signed=False))

            stream = CommandDuplexContext(self.__wraps, cmd_id)

            if self.__commands.has(handler):
                asyncio.create_task(self.__commands.get(handler)(stream))
            else:
                await stream.send(await pack_eof(STATUS_NOTFOUND, "pbj:command_not_exist"))
