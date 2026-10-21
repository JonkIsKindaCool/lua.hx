package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * lcorolib.c — Implementation of the `coroutine` library.
 */
class LCoLib {
	/**
	 * Extracts a `Coroutine` from `a[0]`, raising a type error otherwise.
	 *
	 * @param L Lua state (for error reporting).
	 * @param a Argument array.
	 * @param fname Function name (for error messages).
	 * @returns The coroutine.
	 */
	static function getCo(L:LuaState, a:Array<Dynamic>, fname:String):Coroutine {
		if (a.length > 0 && Std.isOfType(a[0], Coroutine))
			return cast a[0];
		return LAux.typeError(L, a, 0, fname, "coroutine");
	}

	/**
	 * Registers the `coroutine` module and its functions.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var C = new LTable();
		L.globals.setStr("coroutine", C);
		LAux.reg(C, "create", function(a) {
			if (a.length == 0 || !Std.isOfType(a[0], LuaFunction))
				LAux.typeError(L, a, 0, "create", "function");
			return [L.newThread(a[0])];
		});
		LAux.reg(C, "resume", function(a) {
			var co = getCo(L, a, "resume");
			return L.resume(co, a.slice(1));
		});
		// Special=3: the VM intercepts `yield` before dispatching to this
		// native (in `precall`). If we ever reach this body, it means the
		// call originated from a native frame or from outside a coroutine,
		// neither of which can yield.
		LAux.reg(C, "yield", function(a) {
			if (L.cur.isMain)
				return L.error("attempt to yield from outside a coroutine");
			return L.error("attempt to yield across a C-call boundary");
		}, 3);
		LAux.reg(C, "status", function(a) {
			var co = getCo(L, a, "status");
			return [
				switch (co.status) {
					case Coroutine.SUSPENDED:
						"suspended";
					case Coroutine.RUNNING:
						"running";
					case Coroutine.NORMAL:
						"normal";
					default:
						"dead";
				}
			];
		});
		LAux.reg(C, "isyieldable", function(a) {
			var co = a.length > 0 && Std.isOfType(a[0], Coroutine) ? (cast a[0] : Coroutine) : L.cur;
			// A coroutine is yieldable when it is not the main one and we are
			// not inside a native call that forbids yielding (`nny > 0`).
			return [!co.isMain && co.nny == 0];
		});
		LAux.reg(C, "running", function(a) return [L.cur, L.cur.isMain]);
		LAux.reg(C, "wrap", function(a) {
			if (a.length == 0 || !Std.isOfType(a[0], LuaFunction))
				LAux.typeError(L, a, 0, "wrap", "function");
			var co = L.newThread(a[0]);
			return [
				new NativeFunction("wrap", function(args) {
					var r = L.resume(co, args);
					if (r[0] == true)
						return r.slice(1);
					var err = r[1];
					// If the coroutine is now dead (e.g. it raised an error), clean
					// up any to-be-closed variables before propagating the error.
					if (co.status == Coroutine.DEAD)
						L.closeThread(co);
					if (Std.isOfType(err, String))
						err = L.where(1) + err;
					throw new LuaError(err);
				})
			];
		});
		LAux.reg(C, "close", function(a) {
			var co = getCo(L, a, "close");
			return L.closeThread(co);
		});
	}
}
