package luahx.lib;

import haxe.Int64;
import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LStr;
import luahx.vm.LTable;

/**
 * lbaselib.c + loadlib.c (simplified `require`).
 *
 * Provides the global environment: type/printing primitives, numeric
 * conversions, iteration helpers, raw accessors, metatable access,
 * error/pcall/xpcall, code loading, and a minimal `package`/`require`.
 */
class LBaseLib {
	static var warnOn:Bool = false;

	/**
	 * Registers the base library functions into the given state's globals.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var G = L.globals;
		var E = LuaState.EMPTY;
		G.setStr("_G", G);
		G.setStr("_VERSION", "Lua 5.5");

		LAux.reg(G, "print", function(a) {
			var sb = new StringBuf();
			for (i in 0...a.length) {
				if (i > 0) sb.addChar(9);
				sb.add(L.tostring(a[i]));
			}
			sb.addChar(10);
			L.stdout(sb.toString());
			return E;
		});
		LAux.reg(G, "type", function(a) {
			LAux.checkAny(L, a, 0, "type");
			return [LNum.typeName(a[0])];
		});
		LAux.reg(G, "tostring", function(a) {
			LAux.checkAny(L, a, 0, "tostring");
			return [L.tostring(a[0])];
		});
		LAux.reg(G, "tonumber", function(a) {
			if (a.length < 2 || a[1] == null) {
				LAux.checkAny(L, a, 0, "tonumber");
				var v = a[0];
				if (LNum.isNumber(v)) return [v];
				if (Std.isOfType(v, String)) return [LNum.str2number(v)];
				return [null];
			}
			var base = LAux.checkInt(L, a, 1, "tonumber");
			if (!Std.isOfType(a[0], String)) LAux.typeError(L, a, 0, "tonumber", "string");
			if (base < 2 || base > 36) LAux.argError(L, 1, "tonumber", "base out of range");
			var s = StringTools.trim(a[0]);
			var neg = false;
			var i = 0;
			if (s.charAt(0) == "-") { neg = true; i++; }
			else if (s.charAt(0) == "+") i++;
			if (i >= s.length) return [null];
			var acc = Int64.ofInt(0);
			while (i < s.length) {
				var c = s.charCodeAt(i);
				// Accept 0-9, a-z (case-insensitive). Invalid digits become 99.
				var d = (c >= 48 && c <= 57) ? c - 48 : ((c | 32) >= 97 && (c | 32) <= 122 ? (c | 32) - 87 : 99);
				if (d >= base) return [null];
				acc = acc * Int64.ofInt(base) + Int64.ofInt(d);
				i++;
			}
			return [LNum.mkInt(neg ? -acc : acc)];
		});
		// Cache `next` so `pairs` and the VM can short-circuit standard iteration.
		L.nextFn = LAux.reg(G, "next", function(a) {
			var t = LAux.checkTable(L, a, 0, "next");
			var r = t.next(a.length > 1 ? a[1] : null);
			return r == null ? [null] : r;
		});
		LAux.reg(G, "pairs", function(a) {
			LAux.checkAny(L, a, 0, "pairs");
			// `__pairs` overrides the default `next`-based iteration.
			var h = L.getMM(a[0], "__pairs");
			if (h != null) {
				var r = L.call(h, [a[0]]);
				return [r.length > 0 ? r[0] : null, r.length > 1 ? r[1] : null, r.length > 2 ? r[2] : null];
			}
			if (!Std.isOfType(a[0], LTable)) LAux.typeError(L, a, 0, "pairs", "table");
			return [L.nextFn, a[0], null];
		});
		L.ipairsFn = new NativeFunction("ipairs_iter", function(a) {
			var i = LNum.arith(LNum.OP_ADD, a[1], 1);
			var v = L.index(a[0], i, null);
			return v == null ? [null] : [i, v];
		});
		LAux.reg(G, "ipairs", function(a) {
			LAux.checkAny(L, a, 0, "ipairs");
			return [L.ipairsFn, a[0], 0];
		});
		LAux.reg(G, "select", function(a) {
			// `select("#", ...)` returns the argument count.
			if (a.length > 0 && Std.isOfType(a[0], String) && a[0] == "#") return [a.length - 1];
			var n = LAux.checkInt(L, a, 0, "select");
			if (n < 0) n = a.length + n;
			else if (n > a.length - 1) return E;
			if (n < 1) LAux.argError(L, 0, "select", "index out of range");
			return a.slice(n);
		});
		LAux.reg(G, "rawget", function(a) {
			var t = LAux.checkTable(L, a, 0, "rawget");
			return [t.get(a.length > 1 ? a[1] : null)];
		});
		LAux.reg(G, "rawset", function(a) {
			var t = LAux.checkTable(L, a, 0, "rawset");
			L.rawSet(t, a.length > 1 ? a[1] : null, a.length > 2 ? a[2] : null);
			return [t];
		});
		LAux.reg(G, "rawequal", function(a) {
			LAux.checkAny(L, a, 0, "rawequal");
			LAux.checkAny(L, a, 1, "rawequal");
			return [LNum.rawEquals(a[0], a[1])];
		});
		LAux.reg(G, "rawlen", function(a) {
			if (Std.isOfType(a[0], LTable)) return [(cast a[0] : LTable).length()];
			if (Std.isOfType(a[0], String)) return [(cast a[0] : String).length];
			return LAux.argError(L, 0, "rawlen", "table or string expected");
		});
		LAux.reg(G, "setmetatable", function(a) {
			var t = LAux.checkTable(L, a, 0, "setmetatable");
			if (a.length < 2 || !(a[1] == null || Std.isOfType(a[1], LTable))) LAux.typeError(L, a, 1, "setmetatable", "nil or table");
			// `__metatable` locks the metatable: any further attempt raises an error.
			if (t.meta != null && t.meta.getStr("__metatable") != null) L.error("cannot change a protected metatable");
			t.meta = a[1];
			return [t];
		});
		LAux.reg(G, "getmetatable", function(a) {
			LAux.checkAny(L, a, 0, "getmetatable");
			var mt = L.getMetatable(a[0]);
			if (mt == null) return [null];
			// Honor a `__metatable` guard when present.
			var p = mt.getStr("__metatable");
			return [p != null ? p : mt];
		});
		LAux.reg(G, "assert", function(a) {
			if (a.length == 0) LAux.argError(L, 0, "assert", "value expected");
			if (LuaState.isFalse(a[0])) {
				// Custom message: propagate it verbatim (no position prefix).
				if (a.length > 1) throw new LuaError(a[1]);
				L.error("assertion failed!");
			}
			return a;
		});
		LAux.reg(G, "error", function(a) {
			var v = a.length > 0 ? a[0] : null;
			var level = LAux.optInt(L, a, 1, "error", 1);
			// Only strings get the position prefix, and only at level > 0.
			if (Std.isOfType(v, String) && level > 0) v = L.where(level) + v;
			throw new LuaError(v);
		});
		/**
		 * Normalizes a `LuaError` about to escape `pcall`/`xpcall`: if the
		 * error value is a string and its position has not been added yet,
		 * prepend the current source position.
		 *
		 * @param e Error to normalize.
		 */
		var fixup = function(e:LuaError) {
			if (e.pending) {
				e.pending = false;
				if (Std.isOfType(e.value, String)) e.value = L.where(1) + e.value;
			}
		};
		// Special=1: the VM's call dispatcher handles pcall natively so that
		// Lua->Lua errors are caught without an extra boundary frame.
		LAux.reg(G, "pcall", function(a) {
			LAux.checkAny(L, a, 0, "pcall");
			var saved = L.cur.ci;
			var sv = L.noPos;
			L.noPos = Std.isOfType(a[0], NativeFunction);
			try {
				var r = LuaState.okRes(L.call(a[0], a.slice(1)));
				L.noPos = sv;
				return r;
			} catch (e:LuaError) {
				L.cur.ci = saved;
				fixup(e);
				L.noPos = sv;
				return [false, e.value];
			}
		}, 1);
		// Special=2: same as pcall but with an error handler (xpcall).
		LAux.reg(G, "xpcall", function(a) {
			LAux.checkAny(L, a, 1, "xpcall");
			var saved = L.cur.ci;
			try {
				return LuaState.okRes(L.call(a[0], a.slice(2)));
			} catch (e:LuaError) {
				L.cur.ci = saved;
				fixup(e);
				return [false, LuaState.first(L.call(a[1], [e.value]))];
			}
		}, 2);
		LAux.reg(G, "collectgarbage", function(a) {
			var opt = LAux.optStr(L, a, 0, "collectgarbage", "collect");
			// GC is a no-op: report plausible values so scripts that probe
			// these options don't crash.
			switch (opt) {
				case "count": return [new LFloat(256.0), 0];
				case "isrunning": return [true];
				case "incremental", "generational": return ["incremental"];
				case "collect", "step", "stop", "restart", "setpause", "setstepmul", "param": return [0];
				default: return LAux.argError(L, 0, "collectgarbage", "invalid option '" + opt + "'");
			}
		});
		LAux.reg(G, "load", function(a) {
			var chunk = a.length > 0 ? a[0] : null;
			var src:String;
			if (Std.isOfType(chunk, String)) src = chunk;
			else if (Std.isOfType(chunk, LuaFunction)) {
				// The chunk can be provided by a reader function that returns
				// successive pieces; an empty string or `nil` ends the stream.
				var sb = new StringBuf();
				while (true) {
					var piece = LuaState.first(L.call(chunk, LuaState.EMPTY));
					if (piece == null || (Std.isOfType(piece, String) && piece == "")) break;
					if (!Std.isOfType(piece, String)) return [null, "reader function must return a string"];
					sb.add(piece);
				}
				src = sb.toString();
			} else return LAux.typeError(L, a, 0, "load", "string");
			var name = LAux.optStr(L, a, 1, "load", Std.isOfType(chunk, String) ? chunk : "=(load)");
			// The 4th argument (if present) overrides the environment.
			var env:Dynamic = a.length >= 4 ? a[3] : L.globals;
			try {
				return [L.load(src, name, env)];
			} catch (e:LuaError) {
				return [null, e.value];
			}
		});
		/**
		 * Loads a chunk from a named file via `L.sourceLoader`.
		 *
		 * @param fname File path.
		 * @param env Environment value to bind to the chunk.
		 * @returns The compiled closure.
		 * @throws LuaError If the loader cannot find `fname`.
		 */
		var loadFile = function(fname:String, env:Dynamic):Dynamic {
			var src = L.sourceLoader(fname);
			if (src == null) throw new LuaError("cannot open " + fname);
			return L.load(src, "@" + fname, env);
		};
		LAux.reg(G, "loadfile", function(a) {
			try {
				return [loadFile(LAux.checkStr(L, a, 0, "loadfile"), a.length >= 3 ? a[2] : L.globals)];
			} catch (e:LuaError) {
				return [null, e.value];
			}
		});
		LAux.reg(G, "dofile", function(a) {
			var f = loadFile(LAux.checkStr(L, a, 0, "dofile"), L.globals);
			return L.call(f, E);
		});
		LAux.reg(G, "warn", function(a) {
			var msg = "";
			for (i in 0...a.length) msg += LAux.checkStr(L, a, i, "warn");
			// A single `@on` / `@off` argument toggles warnings.
			if (a.length == 1 && msg.charAt(0) == "@") {
				if (msg == "@on") warnOn = true;
				else if (msg == "@off") warnOn = false;
			} else if (warnOn) L.stderr("Lua warning: " + msg + "\n");
			return E;
		});

		// Minimal `package`/`require`: a `loaded` cache, a `preload` table and
		// a single string `path` template.
		var pkg = new LTable();
		var loaded = new LTable();
		var preload = new LTable();
		pkg.setStr("loaded", loaded);
		pkg.setStr("preload", preload);
		pkg.setStr("path", "./?.lua;./?/init.lua");
		pkg.setStr("cpath", "");
		pkg.setStr("config", "/\n;\n?\n!\n-\n");
		G.setStr("package", pkg);
		loaded.setStr("_G", G);
		loaded.setStr("package", pkg);
		LAux.reg(G, "require", function(a) {
			var name = LAux.checkStr(L, a, 0, "require");
			// Fast path: module already in `package.loaded`.
			var v = loaded.getStr(name);
			if (v != null) return [v];
			var loader:Dynamic = preload.getStr(name);
			var extra:Dynamic = ":preload:";
			if (loader == null) {
				// Substitute `.` -> `/` and try each `path` template.
				var fname = StringTools.replace(name, ".", "/");
				var tried = "\n\tno field package.preload['" + name + "']";
				var pathv = pkg.getStr("path");
				var paths = Std.isOfType(pathv, String) ? (cast pathv : String).split(";") : [];
				for (pt in paths) {
					var file = StringTools.replace(pt, "?", fname);
					var src = L.sourceLoader(file);
					if (src != null) {
						loader = L.load(src, "@" + file, L.globals);
						extra = file;
						break;
					}
					tried += "\n\tno file '" + file + "'";
				}
				if (loader == null) L.error("module '" + name + "' not found:" + tried);
			}
			// The loader may either return the module value or register it
			// itself in `package.loaded[name]`. Fall back to `true` otherwise.
			var r = LuaState.first(L.call(loader, [name, extra]));
			if (r != null) loaded.setStr(name, r);
			else if (loaded.getStr(name) == null) loaded.setStr(name, true);
			return [loaded.getStr(name), extra];
		});
	}
}