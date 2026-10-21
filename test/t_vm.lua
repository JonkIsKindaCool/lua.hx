local function loop(n)
  if n == 0 then return "done" end
  return loop(n - 1)
end
print(loop(1000000))
local function rec(n) return 1 + rec(n + 1) end
local ok, err = pcall(rec, 1)
print(ok, tostring(err):match("stack overflow") ~= nil)
local a, b, c = 1, 2
a, b = b, a
print(a, b, c)
local t = {}
local i = 1
i, t[i] = i + 1, 20
print(i, t[1], t[2])
local x, y, z = (function() return 1, 2, 3 end)()
print(x, y, z)
local p, q = ((function() return 1, 2 end)())
print(p, q)
local tt = { (function() return 1, 2, 3 end)(), (function() return 1, 2, 3 end)() }
print(#tt)
local fns = {}
for i = 1, 3 do
  local j = i * 10
  fns[#fns + 1] = { get = function() return j end, set = function(v) j = v end }
end
fns[1].set(99)
print(fns[1].get(), fns[2].get(), fns[3].get())
local function mk()
  local v = 0
  local function inc() v = v + 1 end
  local function get() return v end
  return inc, get
end
local inc, get = mk()
inc()
inc()
print(get())

local ws = {}
local k = 0
while k < 3 do
  k = k + 1
  local m = k
  ws[k] = function() return m end
end
print(ws[1](), ws[2](), ws[3]())

do
  local log = {}
  do
    local a <close> = setmetatable({}, { __close = function() log[#log + 1] = "a" end })
    local b <close> = setmetatable({}, { __close = function() log[#log + 1] = "b" end })
  end
  print(table.concat(log, ","))
  local function f()
    local c <close> = setmetatable({}, { __close = function(_, e) print("closing, err:", e) end })
    error("E1", 0)
  end
  print(pcall(f))
  local function g()
    local c <close> = setmetatable({}, { __close = function() print("close in return") end })
    return 1, 2
  end
  print(g())
  for i = 1, 2 do
    local d <close> = setmetatable({}, { __close = function() print("close iter", i) end })
    if i == 1 then goto cont end
    print("body", i)
    ::cont::
  end
end

local function iter() return function(_, c) if c < 3 then return c + 1 end end, nil, 0,
      setmetatable({}, { __close = function() print("for closed") end }) end
for v in iter() do io.write(v, " ") end
print()
for v in iter() do if v == 2 then break end end

do
  local i = 1
  ::top::
  if i <= 3 then
    io.write(i, " ")
    i = i + 1
    goto top
  end
  print()
end

local base = { x = 1 }
local mid = setmetatable({ y = 2 }, { __index = base })
local top = setmetatable({}, { __index = mid })
print(top.x, top.y, top.z)
local pp = setmetatable({},
  { __pairs = function(t) return function(_, k) if not k then return 1, "one" end end, t, nil end })
for k, v in pairs(pp) do print(k, v) end
local prot = setmetatable({}, { __metatable = "locked" })
print(getmetatable(prot), pcall(setmetatable, prot, {}))
print(getmetatable("abc").__index == string, ("x"):len())

local co = coroutine.wrap(function()
  for i in (function() return function(_, c)
      c = (c or 0) + 1
      coroutine.yield("it" .. c)
      if c < 2 then return c end
    end end)() do end
  return "end"
end)
print(co(), co(), co())
print(select("#", coroutine.resume(coroutine.create(function(...) return ... end), 1, nil, nil)))
local cw = coroutine.wrap(function() error("wrapped err") end)
print(pcall(cw))
print(coroutine.resume(coroutine.running()))
local outer = coroutine.wrap(function()
  local inner = coroutine.wrap(function()
    coroutine.yield(1)
    coroutine.yield(2)
  end)
  coroutine.yield(inner())
  coroutine.yield(inner())
end)
print(outer(), outer())

local arr = {}
for i = 1, 200 do arr[i] = (i * 7919) % 211 end
table.sort(arr)
local okk = true
for i = 2, #arr do if arr[i - 1] > arr[i] then okk = false end end
print(okk, #arr)
print(pcall(table.sort, { 3, 2, 1, 4, 5, 6 }, function(a, b) return true end))
-- strings largos y patrones
local big = ("ab"):rep(10000)
print(#big, #big:gsub("a", "xx"), big:find("ba", 19990, true))
print(("abc"):find("(b)(c)"), ("aaa"):gsub("a*", "-"), ("abc"):match("()b()"))
print(pcall(string.find, "a", "[a"), pcall(string.find, "a", "%"), pcall(string.rep, "x", -1))
print(string.format("%-8s|%8.3f|%+.2e|%g|%g|%g", "ab", math.pi, 12345.678, 100, 1e15, 0.1))
print(#tostring(12345.678), 2 ^ 31, 2 ^ 31 | 0, math.tointeger(2 ^ 53), 1e308 * 10, -1e308 * 10)
print(string.format("%.20f", 0.1), string.format("%.3f", 2 / 3), string.format("%10.4f|", -1.5),
  string.format("%g", 123456789))
print(table.unpack({}, 1, 3))
print(#{ n = 1 }, #{ 1, 2, nil, 4 })
print(next({}, nil), pcall(next, {}, "nokey"))
local s = 0
for i = 1, 100000 do s = s + i % 7 end
print(s)
local str = {}
for i = 1, 100 do str[#str + 1] = tostring(i) end
print(#table.concat(str))
print(tostring(2 ^ 63), math.tointeger("9223372036854775807"), 9223372036854775807 // 1, 9223372036854775808,
  -9223372036854775808)
print(7 // 0.0, -7 // 0.0, 0.0 / 0.0 ~= 0.0 / 0.0, math.fmod(5.5, 2), math.fmod(-5, 2), 5 // -2.0)
print(string.format("[%s]", table.concat({}, ",")), tostring(nil) .. "x", #"\u{10FFFF}", "\65\066\x43\z
       D")
