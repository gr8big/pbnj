--!native

-- classes

export type Queue = {
    __queue: {any},
    __waiting: {(v:any) -> nil},

    put: (self:Queue, v:any) -> nil,
    get: (self:Queue) -> any,
    get_nowait: (self:Queue) -> any
}

export type DuplexHandler = {
    __outgoing: {string},
    __incoming: {string},
    __cmd_progress: number,

    base_url: string,
    send: (self:DuplexHandler, v:string) -> nil,
    recv: (self:DuplexHandler, cmd:string) -> nil,
    clean: (self:DuplexHandler, cmd:string) -> nil
}

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
        self.__outgoing = {}
        self.__incoming = 0
        self.__cmd_progress = 0
        self.base_url = base_url
    end,

    send = function(self:DuplexHandler, v:string)
        self.__outgoing[#self.__outgoing+1] = v
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

local cnstr = {
    Queue = constructor(tmp_queue)
}

-- module

return {
    constructor = constructor,

    Queue = function(): Queue
        return cnstr.Queue()
    end
}
