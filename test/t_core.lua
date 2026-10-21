print(1, 1.0, -0.0, 1e100, 2 ^ 53, 2 ^ 63, math.maxinteger, math.mininteger, math.maxinteger + 1 == math.mininteger)
print(7 // 2, -7 // 2, 7 // -2, 7 % 3, -7 % 3, 7 % -3, 7.5 // 2, -7.5 % 2, 1 / 0, -1 / 0, 3 / 2, 4 / 2)
print(1 == 1.0, math.type(1), math.type(1.0), math.type("1"), 10 // 0.0, 0x10, 0xff, 0x7fffffffffffffff,
  0xffffffffffffffff)
print(5 & 3, 5 | 3, 5 ~ 3, ~5, 1 << 62, 1 << 63, 1 << 64, -1 >> 1, 2 ^ 0.5, 8 // 3.0)
print("10" + 5, "0x10" + 0, "3.5" * 2, 10 .. 20, 1.5 .. "")
print(tostring(1e15), tostring(1e14), 123456789012345678, 0.1 + 0.2, 100 * 1.1, 3.14159265358979)
print(string.format("%5.2f|%d|%5d|%-5d|%05d|%x|%X|%o|%e|%g|%g|%s|%q", 3.14159, 42, 42, 42, 42, 255, 255, 8, 12345.6789,
  0.0001, 1e20, "hi", "a\nb\"c"))
print(string.format("%10s|%-10s|%.3s|%c%c|%i|%+d|% d|%#x|%.0f|%5.1f", "r", "l", "abcdef", 72, 105, 7, 5, 5, 255, 2.5,
  9.96))
print(math.floor(3.7), math.ceil(3.2), math.floor(-3.5), math.abs(-4), math.max(1, 2.5, 2), math.min(3, 1, 2), math.huge,
  -math.huge)
print(math.fmod(7, 3), math.fmod(-7, 3), math.sqrt(16), math.tointeger(3.0), math.tointeger(3.5), math.ult(1, -1),
  math.pi)
print(tostring(3) == "3", tonumber("  0x1p4  "), tonumber("1e"), tonumber("abc"), tonumber("10", 2), tonumber("ff", 16),
  tonumber("8", 8))
print(#"héllo", ("x"):rep(3, ","), ("abc"):upper(), ("ABC"):lower(), ("abc"):reverse(), ("abc"):byte(1, -1))
print(("hello world"):find("o w"), ("hello world"):find("o", 6), ("hello"):find("l+"), ("hello"):match("(h)(e)"),
  ("abc"):find("b", 1, true))
print(("key=value"):match("(%w+)=(%w+)"), ("  trim  "):match("^%s*(.-)%s*$"), ("2024-01-15"):match("(%d+)-(%d+)-(%d+)"))
print(("hello world"):gsub("o", "0"), ("abc"):gsub("%w", "%0%0"), ("hello"):gsub("", "-"),
  ("abc"):gsub(".", { a = 1, b = false }))
print(("x=1, y=2"):gsub("(%w+)=(%w+)", "%2=%1"), ("abc"):gsub("b", function(c) return c:upper() end))
for w in ("one two  three"):gmatch("%a+") do io.write(w, ";") end
print()
for k, v in ("a=1,b=2"):gmatch("(%w+)=(%w+)") do io.write(k, "->", v, " ") end
print()
print(("THE (quick) fox"):find("%((%a+)%)"), ("f(a(b)c)d"):match("%b()"), ("THE END"):find("%f[%a]%a+%f[%A]"))
print(select("#", ("abc"):byte(1, 3)), string.char(72, 101), ("%d"):format(3.0), #string.format("%q", 0.5))
print(table.concat({ 1, 2, 3 }, ", "), table.unpack({ 1, 2, 3 }), select(-1, 1, 2, 3))
local t = { 5, 2, 8, 1, 9, 3 }
table.sort(t)
print(table.concat(t, " "))
table.sort(t, function(a, b) return a > b end)
print(table.concat(t, " "))
table.insert(t, 100)
table.insert(t, 1, 0)
print(table.concat(t, " "), table.remove(t), table.remove(t, 1), #t)
print(table.pack(1, nil, 3).n, #table.pack(), table.move({ 1, 2, 3 }, 1, 3, 2)[3])
local words = { "banana", "apple", "Cherry" }
table.sort(words)
print(table.concat(words, ","))

local function counter()
  local n = 0
  return function()
    n = n + 1
    return n
  end
end
local c1, c2 = counter(), counter()
print(c1(), c1(), c2())
local function va(...)
  local a, b = ...
  return select("#", ...), a, b, ...
end
print(va())
print(va(1))
print(va(1, 2, 3))
print((va(1, 2, 3)))
local obj = { n = 0 }
function obj:inc(k)
  self.n = self.n + (k or 1)
  return self
end

print(obj:inc():inc(5).n)
local Animal = {}
Animal.__index = Animal
function Animal.new(name) return setmetatable({ name = name }, Animal) end

function Animal:speak() return self.name .. " makes a sound" end

local Dog = setmetatable({}, { __index = Animal })
Dog.__index = Dog
function Dog.new(name)
  local d = Animal.new(name)
  return setmetatable(d, Dog)
end

function Dog:speak() return self.name .. " barks" end

print(Animal.new("cat"):speak(), Dog.new("rex"):speak())

local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({ x = a.x + b.x }, V) end
V.__eq = function(a, b) return a.x == b.x end
V.__lt = function(a, b) return a.x < b.x end
V.__le = function(a, b) return a.x <= b.x end
V.__tostring = function(a) return "V(" .. a.x .. ")" end
V.__len = function(a) return a.x end
V.__concat = function(a, b) return tostring(a) .. "|" .. tostring(b) end
V.__call = function(self, y) return self.x + y end
V.__unm = function(a) return setmetatable({ x = -a.x }, V) end
V.__close = nil
local a, b = setmetatable({ x = 1 }, V), setmetatable({ x = 2 }, V)
print(tostring(a + b), a == b, a < b, a <= b, a > b, #a, a .. b, a .. "s", a(10), tostring(-a))
local prox = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v * 2) end })
prox.a = 5
print(prox.a)

local s = ""
for i = 1, 3 do for j = 1, 3 do
    if j == 2 then goto continue end
    s = s .. i .. j .. " "
    ::continue::
  end end
print(s)
local n = 0
repeat
  local z = n
  n = n + 1
until z >= 3
print(n)
for i = 10, 1, -3 do io.write(i, " ") end
print()
for i = 1.0, 2 do io.write(i, " ") end
print()
for i = math.maxinteger - 1, math.maxinteger do io.write(i, " ") end
print()

print(pcall(error, { code = 1 }))
print(select(2, pcall(error, "msg", 0)), select(2, pcall(error, "msg")), select(2, pcall(error)))
print(xpcall(function() error("E") end, function(m) return "H:" .. m end))
print(pcall(function()
  local t = nil; t.x = 1
end))
print(pcall(function() return #5 end))
print(pcall(function() return {} < {} end))
print(pcall(function() return 1 < "2" end))
print(pcall(function() undefinedfn() end))
print(pcall(string.rep))
print(pcall(setmetatable, 1))
print(string.format("%s %s", 1, nil), tostring(true), #arg)
print(pcall(function() return 1 // 0 end))
print(pcall(function() return "a" + 1 end))
print(pcall(function() for i = 1, 10, 0 do end end))
print(select(2, load("x = = 1")))
print(select(2, load("for")))
print(load("return 1 + 1")())
print(next({}), type(next), rawlen({ 1, 2 }), rawequal("a", "a"), rawget(_G, "print") == print)

local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b)
  local d, e = coroutine.yield(c * 2)
  return d + e
end)
print(coroutine.resume(co, 1, 2))
print(coroutine.resume(co, 10))
print(coroutine.resume(co, 3, 4))
print(coroutine.resume(co))
print(coroutine.status(co))
local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end)
print(gen(), gen(), gen())
print(coroutine.isyieldable(), coroutine.running())
local co2 = coroutine.wrap(function()
  local ok, err = pcall(function()
    coroutine.yield(1)
    error("in")
  end)
  coroutine.yield(err)
  return "done"
end)
print(co2(), co2(), co2())
print(coroutine.resume(coroutine.create(function() error("oops") end)))
print(coroutine.resume(coroutine.create(function() error({}) end)))
local cc = coroutine.create(function() coroutine.yield() end)
coroutine.resume(cc)
print(coroutine.close(cc), coroutine.status(cc))

do
  local x <close> = setmetatable({}, { __close = function() print("closed") end })
  print("in")
end
local cst <const> = 5
print(cst)
print(load("local x <const> = 1; x = 2"))

print(utf8.char(72, 228, 8364, 128512), utf8.len("häl€"), #utf8.char(8364), utf8.codepoint("€", 1), utf8.offset("a€b", 3))
for p, c in utf8.codes("a€") do io.write(p, ":", c, " ") end
print()
print(os.time { year = 2020, month = 1, day = 1, hour = 0 } ~= nil, type(os.clock()), os.date("!%Y-%m-%d", 0),
  os.getenv("NOPE_X"))
print(string.pack("<i4", 100):byte(1, -1))
print(string.unpack("<i4", string.pack("<i4", -2)))
print(#string.pack("z", "abc"), string.unpack("s1", string.pack("s1", "hey")))
print(math.random() < 1, math.random(5) <= 5, math.random(3, 4) >= 3)
math.randomseed(42)
print(math.random(1, 100), math.random(1, 100), math.random(0))
print(string.format("%q", 1 / 3), string.format("%.14g", 2 ^ 63), 2 ^ 63 == math.maxinteger + 1.0, math.maxinteger // -1,
  math.mininteger // -1)
print(8 % 3.5, -2 ^ 2, 2 ^ -1, "a" < "b", "a" < "B", 1 < 1.5, math.maxinteger < math.huge, -0.0 == 0.0)
print(string.format("%a %a %a", 1.0, 0.1, -2.5), string.unpack("<d", string.pack("<d", 3.14159)),
  string.unpack("<f", string.pack("<f", 0.5)), string.unpack(">d", string.pack(">d", -1e300)))
local m = {}
m[1.5] = "a"
m[2 ^ 53] = "b"
m[-0.0] = "z"
m[1e300] = "c"
print(m[1.5], m[2 ^ 53], m[0], m[1e300], m[0.0])
print(string.format("%.99f", 0.1):sub(1, 40), string.format("%.30e", 1 / 3),
  string.format("%g %g %g", 1e-5, 123456, 1234567), 5e-324, 1.7976931348623157e308)
