package luahx.lib;

import haxe.Int64;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * lauxlib.c — Argument-checking helpers used by native library functions.
 *
 * Argument indices are **0-based** (`i`); the resulting error messages use
 * `i + 1` to match Lua's 1-based convention.
 */
class LAux {
	/**
	 * Raises a `"bad argument #N to '<fname>' (<msg>)"` error.
	 *
	 * @param L Lua state (for error reporting).
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @param msg Description of the problem.
	 */
	public static function argError(L:LuaState, i:Int, fname:String, msg:String):Dynamic
		return L.error("bad argument #" + (i + 1) + " to '" + fname + "' (" + msg + ")");

	/**
	 * Raises a type-mismatch error mentioning the actual type of the
	 * offending argument (or `"no value"` if it was not provided).
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @param expected Expected type name.
	 */
	public static function typeError(L:LuaState, args:Array<Dynamic>, i:Int, fname:String, expected:String):Dynamic {
		var got = i >= args.length ? "no value" : L.typeNameOf(args[i]);
		return argError(L, i, fname, expected + " expected, got " + got);
	}

	/**
	 * Ensures the argument at `i` exists; returns it unchanged otherwise.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The argument value.
	 */
	public static function checkAny(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):Dynamic {
		if (i >= args.length)
			argError(L, i, fname, "value expected");
		return args[i];
	}

	/**
	 * Ensures the argument at `i` is a table.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The table.
	 */
	public static function checkTable(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):LTable {
		if (i >= args.length || !Std.isOfType(args[i], LTable))
			typeError(L, args, i, fname, "table");
		return cast args[i];
	}

	/**
	 * Ensures the argument at `i` is a number with an exact integer form and
	 * returns it as `Int64`.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The integer value.
	 */
	public static function checkInteger(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):Int64 {
		var v = i < args.length ? args[i] : null;
		var n = LNum.toNumber(v);
		if (n == null)
			typeError(L, args, i, fname, "number");
		var r = LNum.toInteger(n);
		if (r == null)
			argError(L, i, fname, "number has no integer representation");
		return LNum.toI64(r);
	}

	/**
	 * Ensures the argument at `i` is an integer and returns it as a 32-bit
	 * `Int`, clamping to the signed 32-bit range if necessary.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The value clamped to `Int`.
	 */
	public static function checkInt(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):Int {
		var v = i < args.length ? args[i] : null;
		if (Std.isOfType(v, Int))
			return cast v;
		var x = checkInteger(L, args, i, fname);
		return clamp(x);
	}

	/**
	 * Clamps an `Int64` to the signed 32-bit range.
	 *
	 * @param x Value to clamp.
	 * @returns The clamped value as an `Int`.
	 */
	public static function clamp(x:Int64):Int {
		if (x > Int64.ofInt(2147483647))
			return 2147483647;
		if (x < Int64.ofInt(-2147483647))
			return -2147483647;
		return x.low;
	}

	/**
	 * Like {@link checkInt} but returns `def` when the argument is missing or
	 * `nil`.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @param def Default value.
	 * @returns The argument value or `def`.
	 */
	public static function optInt(L:LuaState, args:Array<Dynamic>, i:Int, fname:String, def:Int):Int
		return (i >= args.length || args[i] == null) ? def : checkInt(L, args, i, fname);

	/**
	 * Ensures the argument at `i` is a number and returns it as a Haxe
	 * `Float` (coercing numeric strings).
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The numeric value as a `Float`.
	 */
	public static function checkNum(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):Float {
		var n = LNum.toNumber(i < args.length ? args[i] : null);
		if (n == null)
			typeError(L, args, i, fname, "number");
		return LNum.toFloat(n);
	}

	/**
	 * Ensures the argument at `i` is a number, preserving the Lua integer /
	 * float subtype.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The numeric value (`Int`, `LInt64` or `LFloat`).
	 */
	public static function checkNumber(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):Dynamic {
		var n = LNum.toNumber(i < args.length ? args[i] : null);
		if (n == null)
			typeError(L, args, i, fname, "number");
		return n;
	}

	/**
	 * Like {@link checkNum} but returns `def` when the argument is missing
	 * or `nil`.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @param def Default value.
	 * @returns The numeric value or `def`.
	 */
	public static function optNum(L:LuaState, args:Array<Dynamic>, i:Int, fname:String, def:Float):Float
		return (i >= args.length || args[i] == null) ? def : checkNum(L, args, i, fname);

	/**
	 * Ensures the argument at `i` is a string, coercing numbers to their
	 * textual form as Lua does.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @returns The string value.
	 */
	public static function checkStr(L:LuaState, args:Array<Dynamic>, i:Int, fname:String):String {
		var v = i < args.length ? args[i] : null;
		if (Std.isOfType(v, String))
			return v;
		if (LNum.isNumber(v))
			return LNum.numToString(v);
		typeError(L, args, i, fname, "string");
		return null;
	}

	/**
	 * Like {@link checkStr} but returns `def` when the argument is missing
	 * or `nil`.
	 *
	 * @param L Lua state.
	 * @param args Argument array.
	 * @param i 0-based argument index.
	 * @param fname Function name.
	 * @param def Default value.
	 * @returns The string value or `def`.
	 */
	public static function optStr(L:LuaState, args:Array<Dynamic>, i:Int, fname:String, def:String):String
		return (i >= args.length || args[i] == null) ? def : checkStr(L, args, i, fname);

	/**
	 * Creates a native function and stores it under `name` in `t`.
	 *
	 * @param t Target table (usually a library table).
	 * @param name Function name.
	 * @param fn Callback implementation.
	 * @param special VM special semantics (`0` normal, `1` pcall, `2` xpcall, `3` yield).
	 * @returns The created native function (useful for caching, e.g. `L.nextFn`).
	 */
	public static function reg(t:LTable, name:String, fn:Array<Dynamic>->Array<Dynamic>, special:Int = 0):NativeFunction {
		var f = new NativeFunction(name, fn, special);
		t.setStr(name, f);
		return f;
	}

	/**
	 * Convenience wrapper that packs a single value into a result array.
	 *
	 * @param v Value to return to Lua.
	 * @returns `[v]`.
	 */
	public static inline function ret1(v:Dynamic):Array<Dynamic>
		return [v];
}
