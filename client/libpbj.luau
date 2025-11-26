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

local util = require(script.Parent:WaitForChild("util"))

-- the class

export type PbjApi = {
    __id_prog: number,
    __locked_ids: {[number]:boolean},

    wraps: util.DuplexHandler,
    connect: (self:PbjApi, key:string, auth_endpoint:string?) -> nil,
    run: (self:PbjApi, command:string) -> util.CommandWrapper,

    on_error: (self:PbjApi, callback:(msg:string) -> nil) -> nil
}

-- the template

local tmp_pbjapi: PbjApi = {
    __init__ = function(self:PbjApi, base_url:string)
        self.__id_prog = 0
        self.__locked_ids = {}
        self.wraps = util.DuplexHandler(base_url)
    end,

    connect = function(self:PbjApi, key:string, auth_endpoint:string?)
        self.wraps:connect(key, auth_endpoint)
    end,
    run = function(self:PbjApi, command:string): util.CommandWrapper
        self.__id_prog = (self.__id_prog + 1) % 4294967295
        while self.__locked_ids[self.__id_prog] do
            self.__id_prog = (self.__id_prog + 1) % 4294967295
        end

        local id = self.__id_prog
        self.__locked_ids[id] = true

        self.wraps:send(string.pack("c4<I4s1", "\xff\xff\xff\xff", id, command))
        local res = util.CommandWrapper(self.wraps, string.pack("<I4", id))

        res:on_close(function(this)
            self.__locked_ids[id] = false
        end)

        return res
    end,

    on_error = function(self:PbjApi, callback:(msg:string) -> nil)
        self.wraps:on_error(callback)
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
