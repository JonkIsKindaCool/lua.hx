global print, type, _G, load, table, utf8, _VERSION
global x = 10
print(x, _G.x)

global function hello() return "hi" end

print(hello())
print(load("global z; w = 2"))
print(load("global <const> k = 1; k = 2"))

do global *; q = 5; print(q) end

print(load("for i = 1, 3 do i = 5 end"))
print(load("for k, v in pairs({}) do k = 1 end"))
print(load("local c <const> = 1; c = 2"))
-- table.create and utf8.offset (5.5)

print(type(table.create(10, 5)), utf8.offset("a€b", 3))
print(_VERSION)