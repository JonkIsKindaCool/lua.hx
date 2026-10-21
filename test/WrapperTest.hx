import luahx.Lua;
import luahx.vm.LObject;

class WrapperTest {
	static var fails = 0;

	static function eq(name:String, got:Dynamic, exp:Dynamic) {
		var ok = Std.string(got) == Std.string(exp);
		if (!ok) fails++;
		Sys_println((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  got=" + Std.string(got) + " expected=" + Std.string(exp)));
	}

	static function Sys_println(s:String) {
		#if sys
		Sys.println(s);
		#else
		trace(s);
		#end
	}

	static function main() {
		var lua = new Lua();
		var out = [];
		lua.setOutput(function(s) out.push(s));

		lua.register("suma", function(a) return a[0] + a[1]);
		lua.registerMulti("divmod", function(a) return [Std.int(a[0] / a[1]), a[0] % a[1]]);
		eq("register", lua.doString("return suma(2, 3), suma(1.5, 2)"), [5, 3.5]);
		eq("registerMulti", lua.doString("return divmod(17, 5)"), [3, 2]);

		lua.setGlobal("nombre", "Ñandú ✓");
		lua.setGlobal("datos", [1, 2, 3]);
		lua.setGlobal("cfg", {x: 1, nombre: "hola"});
		eq("unicode roundtrip", lua.doString("return nombre, #nombre, nombre:upper()"), ["Ñandú ✓", 11, "ÑANDú ✓"]);
		eq("array->table", lua.doString("return #datos, datos[2]"), [3, 2]);
		eq("object->table", lua.doString("return cfg.x, cfg.nombre"), [1, "hola"]);
		eq("getGlobal", lua.doString("resultado = 40 + 2") == null || true, true);
		eq("getGlobal value", lua.getGlobal("resultado"), 42);

		lua.doString("print('a', 1, 2.5) io.write('x', 'y', '\\n')");
		eq("output", out.join(""), "a\t1\t2.5\nxy\n");

		var t:Dynamic = lua.doString("return {1, 2, {3, 4}}")[0];
		eq("table deep", lua.toHaxe(t, true), "[1,2,[3,4]]");
		var big = lua.doString("return math.maxinteger, 2^53, 1 // 1")[0];
		eq("int64 -> Int64", haxe.Int64.toStr(big), "9223372036854775807");

		var f = lua.doString("return function(a, b) return a * b, a + b end")[0];
		eq("call", lua.call(f, [6, 7]), [42, 13]);
		var hf:Dynamic = lua.toFunction(lua.doString("return function(s) return s:rep(2) end")[0]);
		eq("toFunction", hf("ab"), "abab");

		lua.register("cmp", function(a) return a[0] > a[1]);
		eq("sort w/ haxe cmp", lua.doString("local t = {3,1,2} table.sort(t, cmp) return table.concat(t, ',')"), ["3,2,1"]);

		var msg = "";
		try {
			lua.doString("error('fallo')", "=test");
		} catch (e:LuaError) {
			msg = Std.string(e.value);
		}
		eq("LuaError", msg, "test:1: fallo");
		try {
			lua.doString("x = = 1", "=sintaxis");
		} catch (e:LuaError) {
			msg = Std.string(e.value);
		}
		eq("syntax error", msg, "sintaxis:1: unexpected symbol near '='");
		lua.register("lanza", function(a) { throw new LuaError("desde haxe"); return null; });
		eq("error from haxe fn caught by pcall", lua.doString("local ok, e = pcall(lanza) return ok, e"), [false, "desde haxe"]);

		var co = lua.newCoroutine(lua.doString("return function(a) local b = coroutine.yield(a + 1) return b * 2 end")[0]);
		var r1 = lua.resume(co, [10]);
		var r2 = lua.resume(co, [21]);
		eq("coroutine yield", r1.values, [11]);
		eq("coroutine return", r2.values, [42]);
		eq("coroutine dead", lua.status(co), "dead");

		lua.setSourceLoader(function(p) return p == "./mimod.lua" ? "return { v = 99, f = function() return 'mod' end }" : null);
		eq("require", lua.doString("local m = require('mimod') return m.v, m.f()"), [99, "mod"]);

		var tbl = lua.newTable();
		lua.tableSet(tbl, "k", "v");
		lua.tableSet(tbl, 1, 100);
		eq("tableGet/Set", [lua.tableGet(tbl, "k"), lua.tableGet(tbl, 1)], ["v", 100]);

		var bare = new Lua(false);
		eq("no libs", bare.doString("return type == nil, print == nil"), [true, true]);

		eq("oop", lua.doString("local A = {} A.__index = A function A.new(n) return setmetatable({n=n}, A) end function A:get() return self.n end return A.new(7):get()"), [7]);
		Sys_println(fails == 0 ? "ALL WRAPPER TESTS PASSED" : fails + " FAILURES");
	}
}
