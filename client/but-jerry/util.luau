--!native

-- imports

local http = game:GetService("HttpService")

-- classes

export type Queue = {
    __queue: {any},
    __waiting: {(v:any) -> nil},

    put: (self:Queue, v:any) -> nil,
    get: (self:Queue) -> any,
    get_nowait: (self:Queue) -> any
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

    base_url: string,
    send: (self:DuplexHandler, v:string) -> nil,
    recv: (self:DuplexHandler, cmd:string) -> nil,
    clean: (self:DuplexHandler, cmd:string) -> nil
}

-- utility

local duplex_recv_handler = function(self:DuplexHandler)
    while true do
        local res = http:RequestAsync(
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

        if res.Success then
            local ctn: string = res.Body
            local count = string.unpack("<I4", ctn)
            local cursor = 4

            for i = 1, count do
                local length = string.unpack("<I4", ctn, cursor)
                local content = string.sub(ctn, cursor + 4, cursor + 4 + length)
                cursor += 4 + length

                self.__incoming:put(content)
            end
        else
            warn(`PBJ API hit failed (status {res.StatusCode})`)
        end
    end
end

local duplex_send_handler = function(self:DuplexHandler)
    while true do
        local ctn = {}

        task.wait(.2) -- safety barrier for http service limits
        local messages = {self.__outgoing:get()}
        while #self.__outgoing.__queue > 0 do
            messages[#messages+1] = self.__outgoing:get_nowait()
        end

        ctn[#ctn+1] = string.pack("<I4", #messages)
        for _, v in pairs(messages) do
            ctn[#ctn+1] = string.pack("<I4", #v)
            ctn[#ctn+1] = v
        end

        local res = http:RequestAsync(
            {
                Url = self.base_url,
                Method = "PUT",
                Body = table.concat(ctn, ""),
                Headers = {
                    ["X-Pbj-Session-Id"] = self.__session_id,
                    ["X-Pbj-Session"] = self.__session_token,
                    ["Content-Type"] = "application/x-pbj-messages"
                }
            }
        )

        if not res.Success then
            warn(`PBJ API hit failed (status {res.StatusCode})`)
        end
    end
end

-- templates

local tmp_queue: Queue = {
    __init__ = function(self:Queue)
        self.__queue = {}
        self.__waiting = {}
    end,

    put = function(self:Queue, v:any)
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
    end
}

local tmp_duplexhandler: DuplexHandler = {
    __init__ = function(self:DuplexHandler, base_url:string)
        while string.sub(base_url, #base_url) == "/" do
            base_url = string.sub(base_url, 1, #base_url - 1)
        end

        self.__outgoing = cnstr.Queue()
        self.__incoming = cnstr.Queue()
        self.__queues = {}
        self.__cmd_progress = 0
        self.base_url = base_url

        self.__task_i = task.spawn(duplex_recv_handler)
        self.__task_o = task.spawn(duplex_send_handler)
    end,

    __get_queue = function(self:DuplexHandler, cmd:string): Queue
        if not self.__queues[cmd] then
            self.__queues[cmd] = cnstr.Queue()
        end
        return self.__queues[cmd]
    end,

    send = function(self:DuplexHandler, v:string)
        self.__outgoing[#self.__outgoing+1] = v
    end,
    recv = function(self:DuplexHandler, cmd:string): any
        return self:__get_queue(cmd):get()
    end,
    clean = function(self:DuplexHandler, cmd:string)
        if self.__queues[cmd] then
            table.clear(self.__queues[cmd])
            self.__queues[cmd] = nil
        end
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
    DuplexHandler = constructor(tmp_duplexhandler)
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
    end
}
