--!native

--[[
This file is part of PB\&J.

PB\&J is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation; either version 3, or (at your option) any later
version.

PB\&J is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with PB\&J; see the file LICENSE.md.  If not see
<http://www.gnu.org/licenses/>.
]]

-- imports

local http = game:GetService("HttpService")

-- constants

COMMAND_ROOT = "\xff\xff\xff\xff"

FRAME_NULL = "\x00"
FRAME_BINARY = "\x40"
FRAME_TEXT = "\x41"
FRAME_JSON = "\x50"
FRAME_EOF = "\xff"

STATUS_OK = 0x00
STATUS_NOTFOUND = 0xa0

-- classes

export type Queue = {
    __queue: {any},
    __waiting: {(v:any) -> nil},
    __locked: boolean,

    put: (self:Queue, v:any) -> nil,
    get: (self:Queue) -> any,
    get_nowait: (self:Queue) -> any,

    shutdown: (self:Queue) -> nil
}

export type DuplexHandler = {
    __outgoing: Queue,
    __incoming: Queue,
    __queues: {[number]:Queue},
    __cmd_progress: number,
    __get_queue: (self:DuplexHandler, cmd:string) -> Queue,
    __task_i: thread,
    __task_o: thread,
    __session_id: string?,
    __session_token: string?,
    __fail_count: number,
    __max_fail_count: number,
    __on_error: {(msg:string) -> nil},

    base_url: string,
    send: (self:DuplexHandler, v:string) -> nil,
    recv: (self:DuplexHandler, cmd:string) -> nil,
    clean: (self:DuplexHandler, cmd:string) -> nil,
    connect: (self:DuplexHandler, key:string, auth_endpoint:string) -> nil,
    shutdown: (self:DuplexHandler) -> nil,

    on_error: (self:DuplexHandler, callback:(msg:string) -> nil) -> nil
}

export type CommandWrapper = {
    __wraps: DuplexHandler,
    __command: string,
    __locked: boolean,
    __onclose: {(self:CommandWrapper) -> nil},
    __final_queue: Queue,
    __task: thread,

    send: (self:CommandWrapper, v:any) -> nil,
    recv: (self:CommandWrapper) -> any,
    close: (self:CommandWrapper) -> nil,

    on_close: (self:CommandWrapper, callback:(self:CommandWrapper) -> nil) -> nil
}

export type ExplicitFramePackage = {
    frame: string,
    content: string,
    __explicit_frame: true
}

-- utility

local unpack_eof = function(data:string): (number,string)
    return string.unpack("B<s1", data)
end


local dispatch_request = function(opts): {[string]:any}
    return http:RequestAsync(opts)
end

local duplex_recv_handler = function(self:DuplexHandler)
    while true do
        local s, res = pcall(dispatch_request,
            {
                Url = self.base_url,
                Method = "POST",
                Body = "\0\0\0\0",
                Headers = {
                    ["X-Pbj-Session-Id"] = self.__session_id,
                    ["X-Pbj-Session"] = self.__session_token,
                    ["Content-Type"] = "application/x-pbj-messages"
                }
            }
        )

        if s and res.Success then
            self.__fail_count = 0

            local ctn: string = res.Body
            local count = string.unpack("<I4", ctn)
            local cursor = 5

            for i = 1, count do
                local length = string.unpack("<I4", ctn, cursor)
                local content = string.sub(ctn, cursor + 4, cursor + 4 + length)
                cursor += 4 + length

                --self.__incoming:put(content)
                local command = string.sub(content, 1, 4)
                local data = string.sub(content, 5)
                if self.__queues[command] then
                    self.__queues[command]:put(data)
                end
            end
        else
            self.__fail_count += 1
            if s then
                warn(`PBJ API hit failed (status {res.StatusCode})`)
            else
                warn(`PBJ API hit failed (error: "{res}")`)
            end

            if self.__fail_count >= self.__max_fail_count then
                for _, v in pairs(self.__on_error) do
                    task.spawn(v, "Max HTTP failures exceeded error threshold")
                end
                error("Max HTTP failures exceeded error threshold", 0)
            end
        end
    end
end

local duplex_send_handler = function(self:DuplexHandler)
    local msg_buffer = {}
    while true do

        task.wait(.2) -- safety barrier for http service limits
        local messages = {self.__outgoing:get()}

        task.wait()
        -- that wait allows messages to accumulate over the rest of the frame

        while #self.__outgoing.__queue > 0 do
            messages[#messages+1] = self.__outgoing:get_nowait()
        end

        msg_buffer[#msg_buffer+1] = string.pack("<I4", #messages)
        for _, v in pairs(messages) do
            msg_buffer[#msg_buffer+1] = string.pack("<I4", #v)
            msg_buffer[#msg_buffer+1] = v
        end

        local s, res = pcall(dispatch_request,
            {
                Url = self.base_url,
                Method = "PUT",
                Body = table.concat(msg_buffer, ""),
                Headers = {
                    ["X-Pbj-Session-Id"] = self.__session_id,
                    ["X-Pbj-Session"] = self.__session_token,
                    ["Content-Type"] = "application/x-pbj-messages"
                }
            }
        )

        if s and res.Success then
            self.__fail_count = 0
        else
            self.__fail_count += 1
            if s then
                warn(`PBJ API hit failed (status {res.StatusCode})`)
            else
                warn(`PBJ API hit failed (error: "{res}")`)
            end

            if self.__fail_count >= self.__max_fail_count then
                for _, v in pairs(self.__on_error) do
                    task.spawn(v, "Max HTTP failures exceeded error threshold")
                end
                error("Max HTTP failures exceeded error threshold", 0)
            end
        end
        table.clear(msg_buffer)
    end
end


local cmd_wrapper_recv_handler = function(self:CommandWrapper)
    while true do
        local data = self.__wraps:recv(self.__command)

        if string.sub(data, 1, 1) == FRAME_EOF then
            local status, message = unpack_eof(string.sub(data, 2))
            -- TODO: add some handler for status & message

            self:close()
        else
            self.__final_queue:put(data)
        end
    end
end


local pack_frame = function(v:any): string
    local tpe = typeof(v)
    if tpe == "table" and v.__explicit_frame then
        return v.frame.. v.content
    elseif tpe == "string" then
        return FRAME_BINARY.. v
    elseif tpe == "table" or tpe == "number" or tpe == "boolean" then
        return FRAME_JSON.. http:JSONEncode(v)
    end

    error(`Cannot pack frame for type '{tpe}'`, 0)
end

-- templates

local tmp_queue: Queue = {
    __init__ = function(self:Queue)
        self.__queue = {}
        self.__waiting = {}
        self.__locked = false
    end,

    put = function(self:Queue, v:any)
        if self.__locked then
            error("Attempt to operate on closed queue", 0)
        end

        if #self.__waiting > 0 then
            table.remove(self.__waiting, 1)(v)
        else
            self.__queue[#self.__queue+1] = v
        end
    end,
    get = function(self:Queue): any
        if #self.__queue > 0 then
            return table.remove(self.__queue, 1)
        end

        local co = coroutine.running()
        local res

        self.__waiting[#self.__waiting+1] = function(v)
            if (not v) and self.__locked then
                error("Queue was shut down", 0)
            end

            res = v
            local ok, err = coroutine.resume(co)
            if not ok then
                error(err)
            end
        end

        coroutine.yield()
        return res
    end,
    get_nowait = function(self:Queue): any
        if #self.__queue > 0 then
            return table.remove(self.__queue, 1)
        end
        error("Queue is empty", 0)
    end,

    shutdown = function(self:Queue)
        self.__locked = true

        for _, v in pairs(self.__waiting) do
            v()
        end

        table.clear(self.__waiting)
    end
}

local tmp_duplexhandler: DuplexHandler = {
    __init__ = function(self:DuplexHandler, base_url:string, max_fails:number)
        while string.sub(base_url, #base_url) == "/" do
            base_url = string.sub(base_url, 1, #base_url - 1)
        end

        self.__outgoing = cnstr.Queue()
        self.__incoming = cnstr.Queue()
        self.__queues = {}
        self.__cmd_progress = 0
        self.__fail_count = 0
        self.__max_fail_count = max_fails or 1
        self.__on_error = {}
        self.base_url = base_url

        self:on_error(function(msg)
            pcall(self.shutdown, self)
            error(msg, 0)
        end)
    end,

    __get_queue = function(self:DuplexHandler, cmd:string): Queue
        if not self.__queues[cmd] then
            self.__queues[cmd] = cnstr.Queue()
        end
        return self.__queues[cmd]
    end,


    connect = function(self:DuplexHandler, key:string, auth_endpoint:string?)
        local res = http:RequestAsync(
            {
                Url = auth_endpoint or `{self.base_url}/auth`,
                Body = key,
                Method = "POST"
            }
        )
        if not res.Success then
            error(`Failed to connect to PB&J instance: HTTP status {res.StatusCode}`, 0)
        end

        self.__session_id = res.Headers["x-pbj-session-id"]
        self.__session_token = res.Headers["x-pbj-session"]

        self.__task_i = task.spawn(duplex_recv_handler, self)
        self.__task_o = task.spawn(duplex_send_handler, self)
    end,


    send = function(self:DuplexHandler, v:string)
        self.__outgoing:put(v)
    end,
    recv = function(self:DuplexHandler, cmd:string): any
        return self:__get_queue(cmd):get()
    end,
    clean = function(self:DuplexHandler, cmd:string)
        if self.__queues[cmd] then
            self.__queues[cmd]:shutdown()
            self.__queues[cmd] = nil
        end
    end,
    shutdown = function(self:DuplexHandler)
        self.__outgoing:shutdown()
        self.__incoming:shutdown()
        for _, v in pairs(self.__queues) do
            v:shutdown()
        end

        task.cancel(self.__task_i)
        task.cancel(self.__task_o)
    end,

    on_error = function(self:DuplexHandler, callback:(msg:string) -> nil)
        self.__on_error[#self.__on_error+1] = callback
    end
}

local tmp_commandwrapper: CommandWrapper = {
    __init__ = function(self:CommandWrapper, wraps:DuplexHandler, cmd_id:string)
        self.__wraps = wraps
        self.__command = cmd_id
        self.__locked = false
        self.__onclose = {}
        self.__final_queue = cnstr.Queue()
        self.__task = task.spawn(cmd_wrapper_recv_handler, self)
    end,

    send = function(self:CommandWrapper, v:any)
        if self.__locked then
            error("Attempt to operate on closed command wrapper", 0)
        end

        self.__wraps:send(self.__command + pack_frame(v))
    end,
    recv = function(self:CommandWrapper): any
        local data = self.__final_queue:get()
        local frame = string.sub(data, 1, 1)
        data = string.sub(data, 2)

        if frame == FRAME_NULL then
            return
        elseif frame == FRAME_BINARY or frame == FRAME_TEXT then
            return data
        elseif frame == FRAME_JSON then
            return http:JSONDecode(data)
        elseif frame == FRAME_EOF then
            error("EOF Error", 0)
        end

        error(`Server sent invalid frame type: {frame}`, 0)
    end,
    close = function(self:CommandWrapper)
        if self.__locked then
            -- no need to close, we already have!
            return
        end

        self.__locked = true

        self.__wraps:clean(self.__command)
        self.__final_queue:shutdown()

        for _, v in pairs(self.__onclose) do
            v(self)
        end
    end,

    on_close = function(self:CommandWrapper, callback:(self:CommandWrapper) -> nil)
        self.__onclose[#self.__onclose+1] = callback
    end
}

-- utility

sorta_deep_copy = function(v:any): any
    local res = {}
    for i, j in pairs(v) do
        if type(j) == "table" then
            res[i] = sorta_deep_copy(j)
        else
            res[i] = j
        end
    end

    return res
end

local constructor = function(template): (...any) -> any
    return function(...)
        local res = sorta_deep_copy(template)
        res:__init__(...)
        return res
    end
end

cnstr = {
    Queue = constructor(tmp_queue),
    DuplexHandler = constructor(tmp_duplexhandler),
    CommandWrapper = constructor(tmp_commandwrapper)
}

-- module

return {
    constructor = constructor,

    -- Minimal parity implementation of `asyncio.Queue`.
    -- * @returns {Queue} An empty queue.
    Queue = function(): Queue
        return cnstr.Queue()
    end,

    -- Class compatible with `duplex.QuartLongPollSessionManager`.
    -- * @param {string} base_url The base URL for HTTP requests.
    -- * @returns {DuplexHandler}
    DuplexHandler = function(base_url:string): DuplexHandler
        return cnstr.DuplexHandler(base_url)
    end,

    -- Wrapper around a `DuplexHandler` to manage a single command.
    -- * @param {DuplexHandler} The handler to wrap.
    -- * @param {string} command The 4-byte command ID.
    -- * @returns {CommandWrapper}
    CommandWrapper = function(wraps:DuplexHandler, command:string): CommandWrapper
        return cnstr.CommandWrapper(wraps, command)
    end
}
