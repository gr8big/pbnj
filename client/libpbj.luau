--!native

export type _Queue = {}

local function Queue(): _Queue
    local queue: _Queue = {}
    queue.content = {}

    -- * Generate a formatted string for a modifier and baseline.
    -- * @param {string} modifier The modifier.
    -- * @param {string} baseline The baseline.
    -- * @returns {string} The formatted string
    function queue:first(self)
        return self.content[1]
    end

    local mt = {
		__tostring = function (self)
			return self.Name
		end,
        __index = function(self, index)
            return self.content[index]
        end,

	}
    setmetatable(queue,mt)
    return queue
end

export type PbjApi = {}

local Pbjapi = {} :: PbjApi -- delete?
Pbjapi.__index = Pbjapi -- delete?

local a_template = {
    -- * Generate a formatted string for a modifier and baseline.
    -- * @param {string} modifier The modifier.
    -- * @param {string} baseline The baseline.
    -- * @returns {string} The formatted string
    start_connection = function(self)
        
    end,

    -- * Generate a formatted string for a modifier and baseline.
    -- * @param {string} modifier The modifier.
    -- * @param {string} baseline The baseline.
    -- * @returns {string} The formatted string
    send_command = function(self)
        
    end,

    -- * Generate a formatted string for a modifier and baseline.
    -- * @param {string} modifier The modifier.
    -- * @param {string} baseline The baseline.
    -- * @returns {string} The formatted string
    disconnect = function(self)
        
    end,
    -- * Generate a formatted string for a modifier and baseline.
    -- * @param {string} modifier The modifier.
    -- * @param {string} baseline The baseline.
    -- * @returns {string} The formatted string
    init = function(self)
        local pbjapi: PbjApi = {}
        pbjapi.connection = nil
        pbjapi.cmd_queue = Queue()
        pbjapi.res_queue = Queue()

	    return pbjapi
    end
}
function deep_copy(v)
    local res = {}
    for i, j in pairs(v) do
        if type(j) == "table" then
            res[i] = deep_copy(j)
        else
            res[i] = j
        end
    end
    return res
end

local PbjApi : PbjApi = deep_copy(a_template)

return  {new = PbjApi}
