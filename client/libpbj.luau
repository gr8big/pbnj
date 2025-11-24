--!native

-- imports

local util = require(script.Parent:WaitForChild("util"))

-- the class

export type PbjApi = {
    __id_prog: number,

    wraps: util.DuplexHandler,
    connect: (self:PbjApi, key:string, auth_endpoint:string?) -> nil,
    run: (self:PbjApi, command:string) -> util.CommandWrapper
}

-- the template

local tmp_pbjapi: PbjApi = {
    __init__ = function(self:PbjApi, base_url:string)
        self.__id_prog = 0
        self.wraps = util.DuplexHandler(base_url)
    end,

    connect = function(self:PbjApi, key:string, auth_endpoint:string?)
        self.wraps:connect(key, auth_endpoint)
    end,
    run = function(self:PbjApi, command:string): util.CommandWrapper
        local id = self.__id_prog
        self.__id_prog = (self.__id_prog + 1) % 2147483648

        self.wraps:send(string.pack("c4<I4s1", "\xff\xff\xff\xff", id, command))
        return util.CommandWrapper(self.wraps, string.pack("<I4", id))
    end
}

-- the constructor

local PbjApi = util.constructor(tmp_pbjapi)

-- module

return {
    new = function(base_url:string): PbjApi
        return PbjApi(base_url)
    end
}
