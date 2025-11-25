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

import io
import time
import typing
import asyncio
from . import main
from quart import Quart, request, websocket

# websocket

class QuartWebsocketHandler(main.BaseDuplexHandler):
    __queues: dict[bytes,asyncio.Queue]

    def __init__(self):
        self.__queues = {}
        asyncio.create_task(self.__producer())

    def __get_queue(self, cmd:bytes) -> asyncio.Queue:
        if not cmd in self.__queues:
            self.__queues[cmd] = asyncio.Queue()

    async def __producer(self):
        while True:
            data = await websocket.receive()
            cmd = data[:4]
            data = data[4:]

            if cmd in self.__queues:
                self.__queues[cmd].put_nowait(data)


    async def send(self, data:bytes):
        await websocket.send(data)

    async def recv(self, cmd:bytes):
        return await self.__get_queue(cmd).get()

    async def clean(self, cmd:bytes):
        if cmd in self.__queues:
            self.__queues[cmd].shutdown(True)
            del self.__queues[cmd]

# long-polling (necessary until live game support for ws)

async def consume_request_body(to:asyncio.StreamReader):
    async for chunk in request.body:
        to.feed_data(chunk)
    
    to.feed_eof()

async def dump_request_body(f:asyncio.StreamReader, chunk_size:int=8192):
    while True:
        chunk = await f.read(chunk_size)

        if chunk:
            yield chunk
        else:
            break
    
    f.feed_eof()

class QuartLongPollManager:
    def __init__(self, cooldown:float=.2, conn_ttl=45.0):
        self.__outgoing = asyncio.Queue()
        self.__incoming = asyncio.Queue()
        self.__cooldown = cooldown
        self.__ttl = conn_ttl

    async def put(self, data:bytes):
        "Place data in the outgoing queue."

        self.__outgoing.put_nowait(data)

    async def pack_outgoing(self, to:asyncio.StreamReader):
        data = []

        try:
            async with asyncio.timeout(self.__ttl):
                data.append(await self.__outgoing.get())

                while not self.__outgoing.empty():
                    data.append(self.__outgoing.get_nowait())
        except asyncio.TimeoutError:
            pass

        to.feed_data(len(data).to_bytes(4, "little", signed=False))
        for i in data:
            to.feed_data(len(i).to_bytes(4, "little", signed=False))
            to.feed_data(i)
        
        to.feed_eof()

    async def parse_incoming(self):
        reader = asyncio.StreamReader()
        asyncio.create_task(consume_request_body(reader))

        for i in range(int.from_bytes(await reader.readexactly(4), "little", signed=False)):
            length = int.from_bytes(await reader.readexactly(4), "little", signed=False)
            self.__incoming.put_nowait(await reader.readexactly(length))

    async def recv(self) -> typing.AsyncGenerator[bytes]:
        """Parse data in a request and place into the incoming queue.  
        Then, wait until at lesat one outgoing message is available,  
        and generate a returned response."""

        start = time.perf_counter()

        await self.parse_incoming()
        elapsed = time.perf_counter() - start
        await asyncio.sleep(max(.008, self.__cooldown - elapsed))

        result = asyncio.StreamReader()
        asyncio.create_task(self.pack_outgoing(result))

        return dump_request_body(result)

    async def get(self) -> bytes:
        return await self.__incoming.get()

    async def shutdown(self):
        self.__outgoing.shutdown(True)
        self.__incoming.shutdown(True)

class QuartLongPollHandler(main.BaseDuplexHandler):
    __queues: dict[bytes,asyncio.Queue]

    def __init__(self):
        self.__manager = QuartLongPollManager()
        self.__queues = {}
        self.__active_producer = None

    def __get_queue(self, cmd:bytes) -> asyncio.Queue:
        if not cmd in self.__queues:
            self.__queues[cmd] = asyncio.Queue()
        return self.__queues[cmd]

    async def __producer(self):
        while True:
            data = await self.__manager.get()
            cmd = data[:4]
            data = data[4:]

            if cmd in self.__queues:
                self.__queues[cmd].put_nowait(data)


    async def unpack_extra_incoming(self):
        await self.__manager.parse_incoming()


    async def start(self):
        if self.__active_producer is None:
            self.__active_producer = asyncio.create_task(self.__producer())

    async def handle_request(self) -> typing.AsyncIterable[bytes]:
        if self.__active_producer is None:
            self.__active_producer = asyncio.create_task(self.__producer)

        return await self.__manager.recv()

    async def send(self, data:bytes):
        await self.__manager.put(data)

    async def recv(self, cmd:bytes):
        return await self.__get_queue(cmd).get()

    async def clean(self, cmd:bytes):
        if cmd in self.__queues:
            self.__queues[cmd].shutdown(True)
            del self.__queues[cmd]

    async def shutdown(self):
        if self.__active_producer is not None:
            self.__active_producer.cancel()
        
        await self.__manager.shutdown()

    async def get_response_body(self) -> bytes:
        return await self.__manager.recv()

class QuartLongPollSessionManager(main.SessionHandler):
    __poll_managers: dict[int,QuartLongPollHandler]
    __cmd_managers: dict[int,main.CommandManager]
    __tasks: dict[int,asyncio.Task]

    def __init__(self, cmd_hndl:main.CommandHandler, key, hasher=None):
        super().__init__(key, hasher)
        self.__cmd_hndl = cmd_hndl
        self.__poll_managers = {}
        self.__cmd_managers = {}
        self.__tasks = {}


    async def clean_session(self, ses:main.Session):
        handler = self.__poll_managers[ses.id]
        manager = self.__cmd_managers[ses.id]
        task = self.__tasks[ses.id]

        await handler.shutdown()
        task.cancel()

    async def start_session(self):
        ses = await super().start_session()

        handler = QuartLongPollHandler()
        manager = main.CommandManager(handler, self.__cmd_hndl)
        self.__poll_managers[ses.id] = handler
        self.__cmd_managers[ses.id] = manager
        await handler.start()
        self.__tasks[ses.id] = asyncio.create_task(manager.run())

        ses.on_close(self.clean_session)

        return ses
    
    async def request_handler(self):
        "Request handler. Can be used directly as a Quart endpoint."

        try:
            ses_id = int(request.headers.get("X-Pbj-Session-Id"))
        except (ValueError, TypeError):
            return "Bad Request", 400

        ses_token = request.headers.get("X-Pbj-Session", "")

        try:
            ses = await self.test_session(ses_id, ses_token)
        except ValueError:
            return "Unauthorized", 401
        
        manager = self.__poll_managers[ses.id]
        return await manager.get_response_body()
    
    async def push_handler(self):
        "Request handler. Can be used directly as a Quart endpoint."

        try:
            ses_id = int(request.headers.get("X-Pbj-Session-Id"))
        except ValueError:
            return "Bad Request", 400

        ses_token = request.headers.get("X-Pbj-Session", "")

        try:
            ses = await self.test_session(ses_id, ses_token)
        except ValueError:
            return "Unauthorized", 401
        
        manager = self.__poll_managers[ses.id]
        await manager.unpack_extra_incoming()

        return ""
