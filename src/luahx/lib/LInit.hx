package luahx.lib;

import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * linit.c — Opens the standard Lua libraries.
 *
 * Called once per state by `Lua.new()` when `openLibs` is `true`. After
 * opening each module, it also registers the module tables in
 * `package.loaded` so `require` returns them without re-loading.
 */
class LInit {
	/**
	 * Opens every standard library and populates `package.loaded`.
	 *
	 * @param L Target Lua state.
	 */
	public static function openAll(L:LuaState):Void {
		LBaseLib.open(L);
		LStrLib.open(L);
		LTabLib.open(L);
		LMathLib.open(L);
		LCoLib.open(L);
		LUtf8Lib.open(L);
		LOsLib.open(L);
		LIoLib.open(L);
		LDebugLib.open(L);
		
		// Cache the module tables in `package.loaded[name]` so `require`
		// short-circuits and returns the already-open table.
		var pkg:LTable = cast L.globals.getStr("package");
		var loaded:LTable = cast pkg.getStr("loaded");
		for (n in ["string", "table", "math", "coroutine", "utf8", "os", "io", "debug"]) loaded.setStr(n, L.globals.getStr(n));
	}
}