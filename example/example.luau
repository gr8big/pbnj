local pbj = require(game.ServerStorage.libpbj.libpbj)

-- Connect to the server

local api = pbj.new("http://localhost:8080/pbj")
api:connect("my key", "http://localhost:8080/auth")

-- Run a command

local ctx = api:run("example")
print(ctx:recv())
ctx:close()
