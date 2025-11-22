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
    def __init__(self, cooldown:float=.2):
        self.__outgoing = asyncio.Queue()
        self.__incoming = asyncio.Queue()
        self.__cooldown = cooldown

    async def put(self, data:bytes):
        "Place data in the outgoing queue."

        self.__outgoing.put_nowait(data)

    async def pack_outgoing(self, to:asyncio.StreamReader):
        data = []
        await self.__outgoing.get()

        while not self.__outgoing.empty():
            data.append(self.__outgoing.get_nowait())

        to.feed_data(len(data).to_bytes(4, "little", signed=False))
        for i in data:
            to.feed_data(len(i).to_bytes(4, "little", signed=False))
            to.feed_data(i)
        
        to.feed_eof()

    async def recv(self) -> typing.AsyncIterable[bytes]:
        """Parse data in a request and place into the incoming queue.  
        Then, wait until at lesat one outgoing message is available,  
        and generate a returned response."""

        start = time.perf_counter()

        reader = asyncio.StreamReader()
        asyncio.create_task(consume_request_body(reader))

        for i in range(int.from_bytes(await reader.readexactly(4), "little", signed=False)):
            length = int.from_bytes(reader.readexactly(4), "little", signed=False)
            self.__incoming.put_nowait(await reader.readexactly(length))

        elapsed = time.perf_counter() - start
        await asyncio.sleep(max(.008, self.__cooldown - elapsed))

        result = asyncio.StreamReader()
        asyncio.create_task(self.pack_outgoing(result))

        return await dump_request_body(result)

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

    async def __producer(self):
        while True:
            data = self.__manager.get()
            cmd = data[:4]
            data = data[4:]

            if cmd in self.__queues:
                self.__queues[cmd].put_nowait(data)


    async def handle_request(self) -> typing.AsyncIterable[bytes]:
        if self.__active_producer is None:
            self.__active_producer = asyncio.create_task(self.__producer)

        return await self.__manager.recv()

    async def send(self, data:bytes):
        await self.__manager.put(data)

    async def recv(self, cmd:bytes):
        return await self.__get_queue(cmd).get()

    async def clean(self, cmd:bytes):
        if self.__active_producer is not None:
            self.__active_producer.cancel()

        await self.__manager.shutdown()
        if cmd in self.__queues:
            self.__queues[cmd].shutdown(True)
            del self.__queues[cmd]
