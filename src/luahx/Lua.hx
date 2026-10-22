package luahx;

import haxe.Int64;
import luahx.lib.LInit;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LStr;
import luahx.vm.LTable;

/**
 * Friendly Haxe wrapper over the Lua 5.5 VM.
 *
 * ```haxe
 * var lua = new Lua();
 
 * lua.register("suma", (a:Array<Dynamic>) -> a[0] + a[1]);
 * lua.doString('print(suma(1, 2))');

 * var r = lua.doString('return {1,2,3}');
 * ```
 */
class Lua {
	/** Low-level state (full access to the VM). */
	public var state(default, null):LuaState;

	var outBuf:String = "";

	/**
	 * Creates a new Lua instance.
	 *
	 * @param openLibs If `true` (default), opens all standard Lua libraries (`LInit.openAll`).
	 */
	public function new(openLibs:Bool = true) {
		state = new LuaState();
		state.stdout = defaultOut;
		state.stderr = defaultErr;
		if (openLibs)
			LInit.openAll(state);
	}

	/**
	 * Default stdout handler. On `sys` targets writes to `Sys.stdout()`;
	 * on `js` forwards line-by-line to `console.log`; otherwise uses `trace`.
	 *
	 * @param s Lua string buffer (may contain partial lines).
	 */
	function defaultOut(s:String):Void {
		var h = LStr.toHaxe(s);
		#if sys
		Sys.stdout().writeString(h);
		#elseif js
		outBuf += h;
		var i = outBuf.lastIndexOf("\n");
		if (i >= 0) {
			js.Syntax.code("console.log({0})", outBuf.substr(0, i));
			outBuf = outBuf.substr(i + 1);
		}
		#else
		outBuf += h;
		var i = outBuf.lastIndexOf("\n");
		if (i >= 0) {
			trace(outBuf.substr(0, i));
			outBuf = outBuf.substr(i + 1);
		}
		#end
	}

	/**
	 * Default stderr handler. Writes to `Sys.stderr()` on `sys` targets,
	 * otherwise falls back to {@link defaultOut}.
	 *
	 * @param s Error text emitted by Lua.
	 */
	function defaultErr(s:String):Void {
		var h = LStr.toHaxe(s);
		#if sys
		Sys.stderr().writeString(h);
		#else
		defaultOut(s);
		#end
	}

	/**
	 * Redirects `print` / `io.write` output.
	 *
	 * @param f Callback receiving plain Unicode text (already decoded from Lua strings).
	 */
	public function setOutput(f:String->Void):Void
		state.stdout = function(s) f(LStr.toHaxe(s));

	/**
	 * Redirects Lua stderr output.
	 *
	 * @param f Callback receiving plain Unicode text.
	 */
	public function setErrorOutput(f:String->Void):Void
		state.stderr = function(s) f(LStr.toHaxe(s));

	/**
	 * Sets the line provider used by `io.read`.
	 *
	 * @param f Callback returning the next line, or `null` to signal EOF.
	 */
	public function setInput(f:Void->String):Void
		state.stdin = function() {
			var l = f();
			return l == null ? null : LStr.fromHaxe(l);
		};

	/**
	 * Sets the source loader used by `require`/`dofile`/`loadfile`.
	 *
	 * @param f Callback that maps a path to source code, or `null` if the file does not exist.
	 */
	public function setSourceLoader(f:String->String):Void
		state.sourceLoader = function(path) {
			var s = f(path);
			return s == null ? null : LStr.fromHaxe(s);
		};

	/**
	 * Compiles a chunk and returns the resulting Lua function.
	 *
	 * @param code Lua source code.
	 * @param chunkName Chunk name shown in error messages.
	 * @returns The compiled Lua closure, ready to be invoked via {@link call}.
	 */
	public function load(code:String, chunkName:String = "=(string)"):LuaClosure
		return state.load(LStr.fromHaxe(code), LStr.fromHaxe(chunkName), state.globals);

	/**
	 * Compiles and runs code.
	 *
	 * @param code Lua source code.
	 * @param chunkName Optional chunk name (defaults to `code`).
	 * @returns Array of return values already converted to Haxe.
	 * @throws LuaError If the chunk fails to compile or run.
	 */
	public function doString(code:String, chunkName:String = null):Array<Dynamic> {
		var f = load(code, chunkName == null ? code : chunkName);
		return call(f, []);
	}

	/**
	 * Calls any callable Lua value with Haxe arguments.
	 *
	 * @param f Lua function (or callable value).
	 * @param args Arguments passed through {@link fromHaxe} before being pushed.
	 * @returns Array of results converted via {@link toHaxe}.
	 */
	public function call(f:Dynamic, args:Array<Dynamic>):Array<Dynamic> {
		var la = [for (a in args) fromHaxe(a)];
		var res = state.call(f, la);
		return [for (r in res) toHaxe(r)];
	}

	/**
	 * Wraps a Lua function into a variadic Haxe function.
	 *
	 * @param f Lua function (or callable value).
	 * @returns A variadic Haxe function returning the first Lua result, or `null`.
	 */
	public function toFunction(f:Dynamic):Dynamic
		return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic {
			var r = call(f, args);
			return r.length > 0 ? r[0] : null;
		});

	/**
	 * Sets a global, converting the value via {@link fromHaxe}.
	 *
	 * @param name Global name.
	 * @param value Value to store.
	 */
	public function setGlobal(name:String, value:Dynamic):Void
		state.globals.setStr(LStr.fromHaxe(name), fromHaxe(value));

	/**
	 * Reads a global, converting the value via {@link toHaxe}.
	 *
	 * @param name Global name.
	 * @returns The converted value, or `null` if the global is `nil`.
	 */
	public function getGlobal(name:String):Dynamic
		return toHaxe(state.globals.getStr(LStr.fromHaxe(name)));

	/**
	 * Registers a Haxe function as a global that returns a single value.
	 *
	 * @param name Global name.
	 * @param fn Callback receiving Lua arguments converted to Haxe. Return `null` for no result;
	 *           use {@link registerMulti} to return multiple values.
	 */
	public function register(name:String, fn:Array<Dynamic>->Dynamic):Void
		setGlobal(name, makeFunction(name, fn));

	/**
	 * Registers a Haxe function as a global that can return multiple values.
	 *
	 * @param name Global name.
	 * @param fn Callback receiving Lua arguments converted to Haxe and returning an array of results.
	 */
	public function registerMulti(name:String, fn:Array<Dynamic>->Array<Dynamic>):Void
		setGlobal(name, makeFunctionMulti(name, fn));

	/**
	 * Builds a Lua native function from a Haxe callback returning a single value.
	 *
	 * @param name Function name (for diagnostics).
	 * @param fn Callback receiving converted Haxe arguments; return `null` for no result.
	 * @returns A {@link NativeFunction} usable from Lua.
	 */
	public function makeFunction(name:String, fn:Array<Dynamic>->Dynamic):NativeFunction
		return new NativeFunction(name, function(a) {
			var r = fn([for (x in a) toHaxe(x)]);
			return r == null ? LuaState.EMPTY : [fromHaxe(r)];
		});

	/**
	 * Builds a Lua native function from a Haxe callback returning multiple values.
	 *
	 * @param name Function name (for diagnostics).
	 * @param fn Callback receiving converted Haxe arguments and returning an array of results.
	 * @returns A {@link NativeFunction} usable from Lua.
	 */
	public function makeFunctionMulti(name:String, fn:Array<Dynamic>->Array<Dynamic>):NativeFunction
		return new NativeFunction(name, function(a) {
			var r = fn([for (x in a) toHaxe(x)]);
			return r == null ? LuaState.EMPTY : [for (x in r) fromHaxe(x)];
		});

	/**
	 * Creates a coroutine from a Lua function.
	 *
	 * @param f Lua function to run inside the coroutine.
	 * @returns The new coroutine (in `suspended` state).
	 */
	public function newCoroutine(f:Dynamic):Coroutine
		return state.newThread(f);

	/**
	 * Resumes a coroutine.
	 *
	 * @param co Coroutine to resume.
	 * @param args Optional values passed to `coroutine.resume`.
	 * @returns An object with `ok` status and the returned/yielded values.
	 *          On failure, `ok=false` and `values[0]` holds the error message.
	 */
	public function resume(co:Coroutine, ?args:Array<Dynamic>):{ok:Bool, values:Array<Dynamic>} {
		var r = state.resume(co, [for (a in (args == null ? [] : args)) fromHaxe(a)]);
		var vals = [for (i in 1...r.length) toHaxe(r[i])];
		return {ok: r[0] == true, values: vals};
	}

	/**
	 * Returns the coroutine status as a string.
	 *
	 * @param co Coroutine to inspect.
	 * @returns One of `"suspended"`, `"running"`, `"normal"` or `"dead"`.
	 */
	public function status(co:Coroutine):String
		return switch (co.status) {
			case Coroutine.SUSPENDED: "suspended";
			case Coroutine.RUNNING: "running";
			case Coroutine.NORMAL: "normal";
			default: "dead";
		};

	/**
	 * Reads `t[key]` with Haxe<->Lua conversion (respects metamethods).
	 *
	 * @param t Target table.
	 * @param key Key converted via {@link fromHaxe}.
	 * @returns Converted value from {@link toHaxe}.
	 */
	public function tableGet(t:LTable, key:Dynamic):Dynamic
		return toHaxe(state.index(t, fromHaxe(key)));

	/**
	 * Sets `t[key] = value` with Haxe<->Lua conversion (respects metamethods).
	 *
	 * @param t Target table.
	 * @param key Key converted via {@link fromHaxe}.
	 * @param value Value converted via {@link fromHaxe}.
	 */
	public function tableSet(t:LTable, key:Dynamic, value:Dynamic):Void
		state.setIndex(t, fromHaxe(key), fromHaxe(value));

	/**
	 * Creates an empty Lua table.
	 *
	 * @returns A new empty {@link LTable}.
	 */
	public function newTable():LTable
		return new LTable();

	/**
	 * Converts a Lua value to Haxe.
	 *
	 * @param v Lua value: `nil` -> `null`, number -> `Int`/`Float`/`Int64`,
	 *          string -> `String` (Unicode), table -> `LTable` (or a plain Haxe
	 *          structure when `deep` is `true`).
	 * @param deep When `true`, recursively converts `LTable` values into `Array` or anonymous objects.
	 * @returns The converted Haxe value.
	 */
	public function toHaxe(v:Dynamic, deep:Bool = false):Dynamic {
		if (v == null)
			return null;
		if (Std.isOfType(v, LFloat))
			return (cast v : LFloat).v;
		if (Std.isOfType(v, LInt64))
			return (cast v : LInt64).v;
		if (Std.isOfType(v, String))
			return LStr.toHaxe(v);
		if (deep && Std.isOfType(v, LTable))
			return tableToHaxe(cast v);
		return v;
	}

	/**
	 * Converts a Haxe value to Lua.
	 *
	 * @param v Haxe value: `Int` -> integer, `Float` -> float, `String`/`Bool` pass through,
	 *          `Array` -> sequence table, `IMap` / anonymous object -> table,
	 *          function -> Lua function. `LuaFunction`, `LTable`, `Coroutine`,
	 *          `LFloat` and `LInt64` are returned unchanged.
	 * @returns The equivalent Lua value.
	 */
	public function fromHaxe(v:Dynamic):Dynamic {
		if (v == null)
			return null;
		if (Std.isOfType(v, Bool))
			return v;
		if (Std.isOfType(v, Int))
			return v;
		if (Std.isOfType(v, Float))
			return new LFloat(v);
		if (Std.isOfType(v, String))
			return LStr.fromHaxe(v);
		if (Std.isOfType(v, LuaFunction) || Std.isOfType(v, LTable) || Std.isOfType(v, Coroutine) || Std.isOfType(v, LFloat) || Std.isOfType(v, LInt64))
			return v;
		if (Std.isOfType(v, Array)) {
			var t = new LTable();
			var arr:Array<Dynamic> = v;
			for (i in 0...arr.length)
				t.setInt(i + 1, fromHaxe(arr[i]));
			return t;
		}
		if (Reflect.isFunction(v))
			return new NativeFunction("haxe", function(a) {
				var r = Reflect.callMethod(null, v, [for (x in a) toHaxe(x)]);
				return r == null ? LuaState.EMPTY : [fromHaxe(r)];
			});
		if (Std.isOfType(v, haxe.Constraints.IMap)) {
			var t = new LTable();
			var m:haxe.Constraints.IMap<Dynamic, Dynamic> = v;
			for (k in m.keys())
				state.rawSet(t, fromHaxe(k), fromHaxe(m.get(k)));
			return t;
		}
		// Anonymous object: copy each field into the table.
		if (Reflect.isObject(v) && Type.getClass(v) == null) {
			var t = new LTable();
			for (f in Reflect.fields(v))
				t.setStr(LStr.fromHaxe(f), fromHaxe(Reflect.field(v, f)));
			return t;
		}
		return v; // Opaque userdata.
	}

	/**
	 * Converts a Haxe `Int64` into a 64-bit Lua integer.
	 *
	 * @param v Value to convert.
	 * @returns The Lua integer value.
	 */
	public function fromInt64(v:Int64):Dynamic
		return LNum.mkInt(v);

	/**
	 * Deeply converts a Lua table into a Haxe `Array` (pure sequence) or anonymous object.
	 *
	 * @param t Table to convert.
	 * @returns Converted table.
	 */
	function tableToHaxe(t:LTable):Dynamic {
		var n = t.length();
		var hashN = t.hashCount();
		if (hashN == 0)
			return [for (i in 1...n + 1) toHaxe(t.getInt(i), true)]; // Pure sequence -> Array.
		var o:Dynamic = {};
		var k:Dynamic = null;
		while (true) {
			var r = t.next(k);
			if (r == null)
				break;
			k = r[0];
			var key = Std.isOfType(k, String) ? LStr.toHaxe(k) : LNum.isNumber(k) ? LNum.numToString(k) : Std.string(k);
			Reflect.setField(o, key, toHaxe(r[1], true));
		}
		return o;
	}
}
