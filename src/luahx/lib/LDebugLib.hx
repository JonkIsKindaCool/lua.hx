package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * ldblib.c — Partial implementation of the `debug` library.
 *
 * Provides `traceback`, `getinfo`, `getmetatable`/`setmetatable`,
 * `getregistry`, `getupvalue` and the hook-related stubs. Hooks are accepted
 * for API compatibility but never fire.
 */
class LDebugLib {
	/**
	 * Walks the current coroutine's call stack up to `level` frames.
	 *
	 * @param L Lua state whose current coroutine is inspected.
	 * @param level 1-based stack level (`1` = current frame).
	 * @returns The matching `CallInfo`, or `null` if `level < 1` or the stack is shallower.
	 */
	static function frameAt(L:LuaState, level:Int):CallInfo {
		var ci = L.cur.ci;
		var l = level;
		while (ci != null && l > 1) {
			ci = ci.prev;
			l--;
		}
		return level < 1 ? null : ci;
	}

	/**
	 * Registers the `debug` module and its functions.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var D = new LTable();
		L.globals.setStr("debug", D);
		LAux.reg(D, "traceback", function(a) {
			// Optional leading thread argument shifts all the other indices.
			var i = 0;
			if (a.length > 0 && Std.isOfType(a[0], Coroutine)) i = 1;
			var msg:Dynamic = a.length > i ? a[i] : null;
			// Non-string, non-number messages are returned verbatim (no traceback).
			if (msg != null && !Std.isOfType(msg, String) && !luahx.vm.LNum.isNumber(msg)) return [msg];
			var level = LAux.optInt(L, a, i + 1, "traceback", 1);
			var sb = new StringBuf();
			if (msg != null) {
				sb.add(L.tostring(msg));
				sb.add("\n");
			}
			sb.add("stack traceback:");
			var ci = frameAt(L, level);
			while (ci != null) {
				var p = ci.cl.p;
				// `pc` points to the *next* instruction; the currently running
				// one is at `pc - 1` (clamped to 0 to tolerate interrupted frames).
				var ln = p.lines[ci.pc > 0 ? ci.pc - 1 : 0];
				sb.add("\n\t" + p.source + ":" + ln + ": in " + (p.lineDefined == 0 ? "main chunk" : "function <" + p.source + ":" + p.lineDefined + ">"));
				ci = ci.prev;
			}
			// Terminating C frame, mirroring the reference output.
			sb.add("\n\t[C]: in ?");
			return [sb.toString()];
		});
		LAux.reg(D, "getinfo", function(a) {
			var t = new LTable();
			var f:Dynamic = a.length > 0 ? a[0] : null;
			var ci:CallInfo = null;
			if (luahx.vm.LNum.isNumber(f)) {
				var lv = LAux.checkInt(L, a, 0, "getinfo");
				// Level 0 is a C function (the call itself).
				if (lv == 0) {
					t.setStr("what", "C");
					t.setStr("source", "=[C]");
					t.setStr("short_src", "[C]");
					t.setStr("currentline", -1);
					return [t];
				}
				ci = frameAt(L, lv);
				if (ci == null) return [null];
				f = ci.cl;
			}
			if (Std.isOfType(f, LuaClosure)) {
				var cl:LuaClosure = cast f;
				var p = cl.p;
				t.setStr("source", "@" + p.source);
				t.setStr("short_src", p.source);
				t.setStr("linedefined", p.lineDefined);
				t.setStr("lastlinedefined", p.lastLine);
				// `lineDefined == 0` marks the main chunk.
				t.setStr("what", p.lineDefined == 0 ? "main" : "Lua");
				t.setStr("currentline", ci != null ? p.lines[ci.pc > 0 ? ci.pc - 1 : 0] : -1);
				t.setStr("nups", cl.upvals.length);
				t.setStr("nparams", p.nparams);
				t.setStr("isvararg", p.isVararg);
				t.setStr("func", cl);
			} else if (Std.isOfType(f, NativeFunction)) {
				t.setStr("what", "C");
				t.setStr("source", "=[C]");
				t.setStr("short_src", "[C]");
				t.setStr("currentline", -1);
				t.setStr("linedefined", -1);
				t.setStr("func", f);
			} else return LAux.argError(L, 0, "getinfo", "function or level expected");
			return [t];
		});
		LAux.reg(D, "getmetatable", function(a) return [L.getMetatable(LAux.checkAny(L, a, 0, "getmetatable"))]);
		LAux.reg(D, "setmetatable", function(a) {
			if (Std.isOfType(a[0], LTable)) (cast a[0] : LTable).meta = a.length > 1 ? a[1] : null;
			return [a[0]];
		});
		// Hooks are accepted for API compatibility but never fire.
		LAux.reg(D, "sethook", function(a) return LuaState.EMPTY);
		LAux.reg(D, "gethook", function(a) return [null]);
		LAux.reg(D, "getregistry", function(a) return [L.registry]);
		// Local-variable introspection is not modeled.
		LAux.reg(D, "getlocal", function(a) return [null]);
		LAux.reg(D, "getupvalue", function(a) {
			var f = a[0];
			var n = LAux.checkInt(L, a, 1, "getupvalue");
			if (Std.isOfType(f, LuaClosure)) {
				var cl:LuaClosure = cast f;
				if (n >= 1 && n <= cl.upvals.length) return [cl.p.upvals[n - 1].name, cl.upvals[n - 1].v];
			}
			return [null];
		});
	}
}