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

-- final utils

local pack_frame = function(type:number, content:string): util.ExplicitFramePackage
    return string.char(type).. content
end

-- module

return {
    -- Construct a new `PbjApi` object.
    -- * @constructor
    -- * @param {string} base_url The base URL to use for requests.
    -- * @returns {PbjApi}
    new = function(base_url:string): PbjApi
        return PbjApi(base_url)
    end,

    -- Pack a frame using an explicitly defined type.
    -- * @constructor
    -- * @param {number} type The frame type to use. Must be in the range 0 to 255, inclusive.
    -- * @param {string} content The data to package with the frame.
    -- * @returns {ExplicitFramePackage}
    frame = pack_frame,

    -- Pack a text frame. Equivalent to calling `frame()` with type `0x41`.
    -- * @param {string} ctn The text contents.
    -- * @returns {ExplicitFramePackage}
    text_frame = function(ctn) return pack_frame(0x41, ctn) end,

    -- Pack a binary frame. Equivalent to calling `frame()` with type `0x40`.
    -- * @param {string} ctn The binary contents.
    -- * @returns {ExplicitFramePackage}
    binary_frame = function(ctn) return pack_frame(0x40, ctn) end,

    -- Pack a JSON frame, encoding the content.
    -- * @param {string} ctn The object to encode.
    -- * @returns {ExplicitFramePackage}
    json_frame = function(ctn)
        return pack_frame(0x50, http:JSONEncode(ctn))
    end,
}
