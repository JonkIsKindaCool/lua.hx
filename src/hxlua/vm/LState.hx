package luahx.vm;

import luahx.vm.LObject;

/**
 * lstate.c + ldo.c + ltm.c + part of lvm.c — Global state, calls, errors,
 * metamethods and coroutines.
 *
 * Coroutines are implemented with heap-allocated stacks (like real Lua), so
 * they work on every Haxe target without OS threads.
 */
class LuaState {
	public static final EMPTY:Array<Dynamic> = [];
	static inline var MAXDEPTH = 200000;
	static inline var MAXCCALLS = 190;
	static final EVENTS = ["__add", "__sub", "__mul", "__mod", "__pow", "__div", "__idiv", "__band", "__bor", "__bxor", "__shl", "__shr", "__unm", "__bnot"];

	public var main:Coroutine;
	public var cur:Coroutine;
	public var globals:LTable;
	public var registry:LTable;
	public var stringMeta:LTable = null;
	public var nCcalls:Int = 0;
	/** `true` while a native function is being called from another native (level 1 = C function: no position). */
	public var noPos:Bool = false;
	public var nextFn:NativeFunction = null;
	public var ipairsFn:NativeFunction = null;
	public var stdout:String->Void;
	public var stderr:String->Void;
	public var stdin:Void->String = function() return null;
	/** Module loader for `require`/`dofile` (name/path -> source code, or `null`). */
	public var sourceLoader:String->String = function(n) return null;
	var ids:haxe.ds.ObjectMap<Dynamic, Int> = new haxe.ds.ObjectMap();
	var nextId:Int = 0x1000;

	public function new() {
		main = new Coroutine();
		main.isMain = true;
		main.status = Coroutine.RUNNING;
		cur = main;
		globals = new LTable();
		registry = new LTable();
		stdout = function(s) {};
		stderr = function(s) {};
	}

	/**
	 * Prepends `true` to a result array (convenience for `pcall`-style results).
	 *
	 * @param a Result values.
	 * @returns A new array `[true, ...a]`.
	 */
	public static function okRes(a:Array<Dynamic>):Array<Dynamic> {
		var r:Array<Dynamic> = [true];
		return r.concat(a);
	}

	/**
	 * Returns the first element of `a`, or `null` if empty.
	 *
	 * @param a Source array.
	 * @returns The first element or `null`.
	 */
	public static inline function first(a:Array<Dynamic>):Dynamic
		return a.length > 0 ? a[0] : null;

	/**
	 * Lua truthiness: only `nil` and `false` are falsy.
	 *
	 * @param v Value to test.
	 * @returns `true` if the value is `nil` or `false`.
	 */
	public static inline function isFalse(v:Dynamic):Bool
		return v == null || (Std.isOfType(v, Bool) && !(cast v : Bool));

	/**
	 * Creates a native function bound to this state.
	 *
	 * @param name Function name (for diagnostics).
	 * @param fn Callback implementation.
	 * @param special Special VM call semantics (see `NativeFunction`).
	 * @returns The new native function.
	 */
	public function newNative(name:String, fn:Array<Dynamic>->Array<Dynamic>, special:Int = 0):NativeFunction
		return new NativeFunction(name, fn, special);

	/**
	 * Builds the `chunk:line: ` prefix for a call frame at `pc`.
	 *
	 * @param ci Call frame.
	 * @param pc Program counter (clamped to the valid range).
	 * @returns The location prefix string.
	 */
	public static function whereCI(ci:CallInfo, pc:Int):String {
		var p = ci.cl.p;
		if (pc < 0) pc = 0;
		if (pc >= p.lines.length) pc = p.lines.length - 1;
		return p.source + ":" + p.lines[pc] + ": ";
	}

	/**
	 * Builds a `chunk:line: ` prefix by walking up `level` frames from the
	 * current one (level 1 = current frame).
	 *
	 * @param level Stack level (1-based).
	 * @returns The location prefix, or `""` when it cannot be determined.
	 */
	public function where(level:Int):String {
		var ci = cur.ci;
		var l = level;
		while (ci != null && l > 1) {
			ci = ci.prev;
			l--;
		}
		if (ci == null || (noPos && level == 1)) return "";
		return whereCI(ci, ci.pc - 1);
	}

	/**
	 * Raises an error with the caller's source position prepended
	 * (equivalent to Lua's `luaL_error`).
	 *
	 * @param msg Error message.
	 */
	public function error(msg:String):Dynamic
		throw new LuaError(where(1) + msg);

	/**
	 * Raises a runtime error whose location prefix will be added by the VM.
	 *
	 * @param msg Error message.
	 */
	public function rtError(msg:String):Dynamic
		throw new LuaError(msg, true);

	/**
	 * Raises an error describing an invalid operation on a value.
	 *
	 * @param v Offending value.
	 * @param op Operation being attempted (e.g. `"index"`).
	 * @param desc Optional extra descriptor (e.g. field name).
	 */
	function typeError(v:Dynamic, op:String, desc:String):Dynamic {
		var m = "attempt to " + op + " a " + typeNameOf(v) + " value";
		if (desc != null) m += " (" + desc + ")";
		return rtError(m);
	}

	/**
	 * Returns the Lua type name of `v`, honoring a `__name` field on its metatable.
	 *
	 * @param v Value to inspect.
	 * @returns The type name.
	 */
	public function typeNameOf(v:Dynamic):String {
		var mt = getMetatable(v);
		if (mt != null) {
			var n = mt.getStr("__name");
			if (Std.isOfType(n, String)) return n;
		}
		return LNum.typeName(v);
	}

	/**
	 * Formats a chunk source into a short, human-readable identifier for
	 * error messages, mirroring Lua's `luaO_chunkid`.
	 *
	 * @param source Chunk source string.
	 * @returns The chunk identifier.
	 */
	public static function chunkId(source:String):String {
		if (source.charAt(0) == "=" || source.charAt(0) == "@") return source.substr(1);
		var nl = source.indexOf("\n");
		var avail = 45;
		if (nl < 0 && source.length < avail) return "[string \"" + source + "\"]";
		var s = nl >= 0 ? source.substr(0, nl) : source;
		if (s.length > avail) s = s.substr(0, avail);
		return "[string \"" + s + "...\"]";
	}

	/**
	 * Returns the metatable of a value, if any.
	 *
	 * @param v Value to inspect.
	 * @returns The metatable, or `null`.
	 */
	public function getMetatable(v:Dynamic):LTable {
		if (Std.isOfType(v, LTable)) return (cast v : LTable).meta;
		if (Std.isOfType(v, String)) return stringMeta;
		if (Std.isOfType(v, LuaUserdata)) return (cast v : LuaUserdata).meta;
		return null;
	}

	/**
	 * Returns the metamethod `name` of `v`, or `null` if absent.
	 *
	 * @param v Value to inspect.
	 * @param name Metamethod name (e.g. `"__index"`).
	 * @returns The metamethod value, or `null`.
	 */
	public inline function getMM(v:Dynamic, name:String):Dynamic {
		var mt = getMetatable(v);
		return mt == null ? null : mt.getStr(name);
	}

	/**
	 * Returns a stable pseudo-address string for `v`, used by `tostring`.
	 *
	 * @param v Value to address.
	 * @returns A hex string like `"0x00001234"`.
	 */
	public function addrOf(v:Dynamic):String {
		var id = ids.get(v);
		if (id == null) {
			id = nextId;
			nextId += 0x28;
			ids.set(v, id);
		}
		var h = StringTools.hex(id, 8).toLowerCase();
		return "0x" + h;
	}

	/**
	 * Lua `tostring`: handles `__tostring`, numbers, booleans, `nil`,
	 * functions and userdata.
	 *
	 * @param v Value to convert.
	 * @returns The string representation.
	 */
	public function tostring(v:Dynamic):String {
		if (v == null) return "nil";
		if (Std.isOfType(v, String)) return v;
		if (Std.isOfType(v, Bool)) return (cast v : Bool) ? "true" : "false";
		if (LNum.isNumber(v)) return LNum.numToString(v);
		var mt = getMetatable(v);
		if (mt != null) {
			var h = mt.getStr("__tostring");
			if (h != null) {
				var r = first(call(h, [v]));
				if (!Std.isOfType(r, String)) {
					if (LNum.isNumber(r)) return LNum.numToString(r);
					error("'__tostring' must return a string");
				}
				return r;
			}
		}
		var tn = LNum.typeName(v);
		if (mt != null) {
			var n = mt.getStr("__name");
			if (Std.isOfType(n, String)) tn = n;
		}
		if (Std.isOfType(v, NativeFunction)) return "function: builtin: " + addrOf(v);
		return tn + ": " + addrOf(v);
	}

	/**
	 * Raw table write, rejecting `nil` and `NaN` keys.
	 *
	 * @param t Target table.
	 * @param k Key.
	 * @param v Value (`null` deletes).
	 */
	public function rawSet(t:LTable, k:Dynamic, v:Dynamic):Void {
		if (k == null) rtError("table index is nil");
		if (Std.isOfType(k, LFloat)) {
			var f = (cast k : LFloat).v;
			if (f != f) rtError("table index is NaN");
		}
		t.set(k, v);
	}

	/**
	 * Indexes a value honoring `__index` metamethods. Follows chains of
	 * `__index` tables up to a safety limit to detect loops.
	 *
	 * @param obj Object being indexed.
	 * @param key Key.
	 * @param desc Optional descriptor for error messages.
	 * @returns The indexed value.
	 */
	public function index(obj:Dynamic, key:Dynamic, desc:String = null):Dynamic {
		var loop = 0;
		while (loop++ < 2000) {
			var h:Dynamic;
			if (Std.isOfType(obj, LTable)) {
				var t:LTable = cast obj;
				var v = t.get(key);
				if (v != null) return v;
				var mt = t.meta;
				if (mt == null) return null;
				h = mt.getStr("__index");
				if (h == null) return null;
			} else {
				h = getMM(obj, "__index");
				if (h == null) {
					if (desc == null && Std.isOfType(key, String)) desc = "field '" + key + "'";
					return typeError(obj, "index", desc);
				}
			}
			if (Std.isOfType(h, LuaFunction)) return first(call(h, [obj, key]));
			obj = h;
			desc = null;
		}
		return rtError("'__index' chain too long; possible loop");
	}

	/**
	 * Assigns into a value honoring `__newindex` metamethods. Follows chains
	 * of `__newindex` tables up to a safety limit to detect loops.
	 *
	 * @param obj Object being indexed.
	 * @param key Key.
	 * @param val Value to store.
	 * @param desc Optional descriptor for error messages.
	 */
	public function setIndex(obj:Dynamic, key:Dynamic, val:Dynamic, desc:String = null):Void {
		var loop = 0;
		while (loop++ < 2000) {
			var h:Dynamic;
			if (Std.isOfType(obj, LTable)) {
				var t:LTable = cast obj;
				var mt = t.meta;
				if (mt == null || (h = mt.getStr("__newindex")) == null || t.get(key) != null) {
					rawSet(t, key, val);
					return;
				}
			} else {
				h = getMM(obj, "__newindex");
				if (h == null) {
					if (desc == null && Std.isOfType(key, String)) desc = "field '" + key + "'";
					typeError(obj, "index", desc);
				}
			}
			if (Std.isOfType(h, LuaFunction)) {
				call(h, [obj, key, val]);
				return;
			}
			obj = h;
			desc = null;
		}
		rtError("'__newindex' chain too long; possible loop");
	}

	/**
	 * Applies an arithmetic metamethod (or raises a type error if none exists).
	 *
	 * @param op Arithmetic opcode (`LNum.OP_*`).
	 * @param a Left operand.
	 * @param b Right operand.
	 * @param d1 Optional descriptor for the left operand.
	 * @param d2 Optional descriptor for the right operand.
	 * @returns The result of the metamethod call.
	 */
	public function arithMeta(op:Int, a:Dynamic, b:Dynamic, d1:String, d2:String):Dynamic {
		var ev = EVENTS[op];
		var h = getMM(a, ev);
		if (h == null) h = getMM(b, ev);
		if (h != null) return first(call(h, [a, b]));
		if (op >= LNum.OP_BAND && op != LNum.OP_UNM) {
			if (LNum.isNumber(a) && LNum.isNumber(b)) return rtError("number has no integer representation");
			var badA = !LNum.isNumber(a) && LNum.toNumber(a) == null;
			return badA ? typeError(a, "perform bitwise operation on", d1) : typeError(b, "perform bitwise operation on", d2);
		}
		if (Std.isOfType(a, String) || Std.isOfType(b, String)) {
			var nm = EVENTS[op].substr(2);
			return rtError("attempt to " + nm + " a '" + typeNameOf(a) + "' with a '" + typeNameOf(b) + "'");
		}
		var bad = LNum.toNumber(a) == null;
		return bad ? typeError(a, "perform arithmetic on", d1) : typeError(b, "perform arithmetic on", d2);
	}

	/**
	 * Equality (`==`) honoring `__eq` for tables.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 * @returns Whether the values are equal.
	 */
	public function eq(a:Dynamic, b:Dynamic):Bool {
		if (LNum.rawEquals(a, b)) return true;
		if (Std.isOfType(a, LTable) && Std.isOfType(b, LTable)) {
			var h = getMM(a, "__eq");
			if (h == null) h = getMM(b, "__eq");
			if (h != null) return !isFalse(first(call(h, [a, b])));
		}
		return false;
	}

	/**
	 * Raises the standard "attempt to compare" error for incompatible types.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 */
	function compareError(a:Dynamic, b:Dynamic):Dynamic {
		var t1 = typeNameOf(a);
		var t2 = typeNameOf(b);
		if (t1 == t2) return rtError("attempt to compare two " + t1 + " values");
		return rtError("attempt to compare " + t1 + " with " + t2);
	}

	/**
	 * Less-than (`<`) honoring `__lt`.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 * @returns Whether `a < b`.
	 */
	public function lt(a:Dynamic, b:Dynamic):Bool {
		if (LNum.isNumber(a) && LNum.isNumber(b)) return LNum.numCompare(a, b) == -1;
		if (Std.isOfType(a, String) && Std.isOfType(b, String)) {
			var x:String = a;
			var y:String = b;
			return x < y;
		}
		var h = getMM(a, "__lt");
		if (h == null) h = getMM(b, "__lt");
		if (h == null) compareError(a, b);
		return !isFalse(first(call(h, [a, b])));
	}

	/**
	 * Less-or-equal (`<=`) honoring `__le`.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 * @returns Whether `a <= b`.
	 */
	public function le(a:Dynamic, b:Dynamic):Bool {
		if (LNum.isNumber(a) && LNum.isNumber(b)) {
			var c = LNum.numCompare(a, b);
			return c == -1 || c == 0;
		}
		if (Std.isOfType(a, String) && Std.isOfType(b, String)) {
			var x:String = a;
			var y:String = b;
			return x <= y;
		}
		var h = getMM(a, "__le");
		if (h == null) h = getMM(b, "__le");
		if (h == null) compareError(a, b);
		return !isFalse(first(call(h, [a, b])));
	}

	/**
	 * Length (`#`) honoring `__len`.
	 *
	 * @param v Value to measure.
	 * @param desc Optional descriptor for error messages.
	 * @returns The length.
	 */
	public function len(v:Dynamic, desc:String = null):Dynamic {
		if (Std.isOfType(v, String)) return (cast v : String).length;
		var h = getMM(v, "__len");
		if (h != null) return first(call(h, [v]));
		if (Std.isOfType(v, LTable)) return (cast v : LTable).length();
		return typeError(v, "get length of", desc);
	}

	inline function strOrNum(v:Dynamic):Bool
		return Std.isOfType(v, String) || LNum.isNumber(v);

	inline function asStr(v:Dynamic):String
		return Std.isOfType(v, String) ? v : LNum.numToString(v);

	/**
	 * Concatenates two values (`..`) honoring `__concat`.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 * @returns The concatenated value.
	 */
	function concat2(a:Dynamic, b:Dynamic):Dynamic {
		if (strOrNum(a) && strOrNum(b)) return asStr(a) + asStr(b);
		var h = getMM(a, "__concat");
		if (h == null) h = getMM(b, "__concat");
		if (h != null) return first(call(h, [a, b]));
		return typeError(strOrNum(a) ? b : a, "concatenate", null);
	}

	/**
	 * Concatenates the top `n` values of the coroutine stack in place,
	 * collapsing them into a single result.
	 *
	 * @param co Target coroutine.
	 * @param n Number of values to concatenate.
	 */
	public function concatN(co:Coroutine, n:Int):Void {
		var stack = co.stack;
		var sp = co.sp;
		var start = sp - n;
		var all = true;
		for (i in start...sp)
			if (!strOrNum(stack[i])) {
				all = false;
				break;
			}
		var res:Dynamic;
		if (all) {
			var sb = new StringBuf();
			for (i in start...sp) sb.add(asStr(stack[i]));
			res = sb.toString();
		} else {
			var acc = stack[sp - 1];
			var i = sp - 2;
			while (i >= start) {
				acc = concat2(stack[i], acc);
				i--;
			}
			res = acc;
		}
		stack[start] = res;
		co.sp = start + 1;
	}

	/**
	 * Writes `res` onto the coroutine stack starting at `pos`, either
	 * forwarding all results (`nres < 0`, multret) or padding/truncating
	 * to exactly `nres` values.
	 *
	 * @param co Target coroutine.
	 * @param pos Stack position of the first result slot.
	 * @param res Results to write (may be `null` for "no values").
	 * @param nres Number of expected results, or a negative value for multret.
	 */
	public function placeResults(co:Coroutine, pos:Int, res:Array<Dynamic>, nres:Int):Void {
		var stack = co.stack;
		var n = res == null ? 0 : res.length;
		if (nres < 0) {
			for (i in 0...n) stack[pos + i] = res[i];
			co.sp = pos + n;
			co.nmulti = n;
		} else {
			for (i in 0...nres) stack[pos + i] = i < n ? res[i] : null;
			co.sp = pos + nres;
		}
	}

	/**
	 * Pushes a Lua call frame for `cl`, handling parameter padding and
	 * varargs, and enforcing the maximum call depth.
	 *
	 * @param co Target coroutine.
	 * @param cl Lua closure to call.
	 * @param funcIdx Stack index of the function value.
	 * @param nargs Number of arguments already on the stack.
	 * @param retPos Stack index where results should be placed.
	 * @param nres Number of expected results, or a negative value for multret.
	 * @returns The new call frame.
	 */
	public function pushLua(co:Coroutine, cl:LuaClosure, funcIdx:Int, nargs:Int, retPos:Int, nres:Int):CallInfo {
		var p = cl.p;
		var stack = co.stack;
		var base = funcIdx + 1;
		var np = p.nparams;
		var va:Array<Dynamic> = null;
		if (nargs > np) {
			if (p.isVararg) va = stack.slice(base + np, base + nargs);
		} else for (i in nargs...np) stack[base + i] = null;
		if (p.isVararg && va == null) va = EMPTY;
		var depth = co.ci == null ? 1 : co.ci.depth + 1;
		if (depth > MAXDEPTH) throw new LuaError("stack overflow", true);
		var ci = new CallInfo();
		ci.cl = cl;
		ci.base = base;
		ci.retPos = retPos;
		ci.nres = nres;
		ci.varargs = va;
		ci.prev = co.ci;
		ci.depth = depth;
		co.ci = ci;
		co.sp = base + np;
		return ci;
	}

	/**
	 * Dispatches a call whose function value is at `stack[funcIdx]`.
	 *
	 * Handles Lua closures, native functions (including pcall/xpcall/yield
	 * specials) and `__call` chains.
	 *
	 * @param co Target coroutine.
	 * @param funcIdx Stack index of the function value.
	 * @param nargs Number of arguments on the stack.
	 * @param nres Number of expected results, or a negative value for multret.
	 * @param desc Optional descriptor for error messages.
	 * @returns `0` if a native call finished, `1` if a Lua frame was pushed, `2` if the coroutine yielded.
	 */
	public function precall(co:Coroutine, funcIdx:Int, nargs:Int, nres:Int, desc:String):Int {
		var stack = co.stack;
		while (true) {
			var f = stack[funcIdx];
			if (Std.isOfType(f, LuaClosure)) {
				pushLua(co, cast f, funcIdx, nargs, funcIdx, nres);
				return 1;
			}
			if (Std.isOfType(f, NativeFunction)) {
				var nf:NativeFunction = cast f;
				switch (nf.special) {
					case 1, 2:
						return pcallVM(co, funcIdx, nargs, nres, nf.special);
					case 3:
						if (co.isMain) error("attempt to yield from outside a coroutine");
						if (co.nny > 0) error("attempt to yield across a C-call boundary");
						co.transfer = stack.slice(funcIdx + 1, funcIdx + 1 + nargs);
						co.yRet = funcIdx;
						co.yNres = nres;
						co.status = Coroutine.SUSPENDED;
						return 2;
				}
				var args = stack.slice(funcIdx + 1, funcIdx + 1 + nargs);
				co.sp = funcIdx + 1 + nargs;
				var res = nf.fn(args);
				placeResults(co, funcIdx, res, nres);
				return 0;
			}
			var mm = getMM(f, "__call");
			if (mm == null) typeError(f, "call", desc);
			// Shift function + args one slot to the right so we can prepend the __call handler.
			var i = funcIdx + nargs;
			while (i >= funcIdx) {
				stack[i + 1] = stack[i];
				i--;
			}
			stack[funcIdx] = mm;
			nargs++;
			co.sp = funcIdx + 1 + nargs;
			desc = null;
		}
	}

	/**
	 * Implements the `pcall`/`xpcall` specials, catching errors and rewriting
	 * the result slots to `[ok, value...]`.
	 *
	 * @param co Target coroutine.
	 * @param funcIdx Stack index of the `pcall`/`xpcall` native function.
	 * @param nargs Number of arguments on the stack (including the callee).
	 * @param nres Number of expected results.
	 * @param kind `1` for `pcall`, `2` for `xpcall`.
	 * @returns `0` if handled synchronously, `1` if a Lua frame was pushed.
	 */
	function pcallVM(co:Coroutine, funcIdx:Int, nargs:Int, nres:Int, kind:Int):Int {
		var stack = co.stack;
		var handler:Dynamic = null;
		var calleeIdx = funcIdx + 1;
		var nargsC = nargs - 1;
		if (kind == 1) {
			if (nargs < 1) error("bad argument #1 to 'pcall' (value expected)");
		} else {
			if (nargs < 2) error("bad argument #2 to 'xpcall' (value expected)");
			handler = stack[funcIdx + 2];
			stack[funcIdx + 2] = stack[funcIdx + 1];
			calleeIdx = funcIdx + 2;
			nargsC = nargs - 2;
		}
		var f = stack[calleeIdx];
		if (Std.isOfType(f, LuaClosure)) {
			var ci = pushLua(co, cast f, calleeIdx, nargsC, funcIdx, nres);
			ci.isPcall = true;
			ci.handler = handler;
			return 1;
		}
		var args = stack.slice(calleeIdx + 1, calleeIdx + 1 + nargsC);
		co.sp = calleeIdx + 1 + nargsC;
		var saved = co.ci;
		var res:Array<Dynamic>;
		var svNoPos = noPos;
		noPos = Std.isOfType(f, NativeFunction);
		try {
			res = okRes(call(f, args));
			noPos = svNoPos;
		} catch (e:LuaError) {
			co.ci = saved;
			if (e.pending) {
				e.pending = false;
				if (Std.isOfType(e.value, String)) e.value = where(1) + e.value;
			}
			noPos = svNoPos;
			var ev = e.value;
			if (handler != null) {
				try {
					ev = first(call(handler, [ev]));
				} catch (e2:LuaError) {
					ev = e2.value;
				}
			}
			res = [false, ev];
		}
		placeResults(co, funcIdx, res, nres);
		return 0;
	}

	/**
	 * Calls a Lua value from Haxe code (natives, metamethods, host code).
	 *
	 * @param f Callable value.
	 * @param args Arguments (already converted to Lua values).
	 * @returns The returned values.
	 */
	public function call(f:Dynamic, args:Array<Dynamic>):Array<Dynamic> {
		if (Std.isOfType(f, NativeFunction)) {
			var r = (cast f : NativeFunction).fn(args);
			return r == null ? EMPTY : r;
		}
		if (!Std.isOfType(f, LuaClosure)) {
			var mm = getMM(f, "__call");
			if (mm == null) typeError(f, "call", null);
			return call(mm, [f].concat(args));
		}
		var co = cur;
		var stack = co.stack;
		var funcIdx = co.sp;
		stack[funcIdx] = f;
		for (i in 0...args.length) stack[funcIdx + 1 + i] = args[i];
		co.sp = funcIdx + 1 + args.length;
		if (nCcalls >= MAXCCALLS) throw new LuaError("C stack overflow", true);
		nCcalls++;
		co.nny++;
		var saved = co.ci;
		var svNoPos = noPos;
		noPos = false;
		try {
			var ni = pushLua(co, cast f, funcIdx, args.length, funcIdx, -1);
			ni.isBoundary = true;
			LVM.execute(this, co);
		} catch (e:LuaError) {
			noPos = svNoPos;
			co.nny--;
			nCcalls--;
			co.sp = funcIdx;
			co.ci = saved;
			throw e;
		}
		noPos = svNoPos;
		co.nny--;
		nCcalls--;
		var res = stack.slice(funcIdx, co.sp);
		co.sp = funcIdx;
		return res;
	}

	/**
	 * Closes to-be-closed variables with stack index `>= level`, calling
	 * their `__close` metamethods in reverse order.
	 *
	 * @param co Target coroutine.
	 * @param level Stack level (closed variables with index `>= level`).
	 * @param err Pending error (may be `null`).
	 * @returns The resulting error (either the original or one raised by `__close`).
	 */
	public function closeTbc(co:Coroutine, level:Int, err:LuaError):LuaError {
		while (co.tbc.length > 0 && co.tbc[co.tbc.length - 1] >= level) {
			var idx = co.tbc.pop();
			var v = co.stack[idx];
			if (Std.isOfType(v, Cell)) v = (cast v : Cell).v;
			var h = getMM(v, "__close");
			if (h == null) continue;
			try {
				call(h, [v, err == null ? null : err.value]);
			} catch (e:LuaError) {
				if (e.pending) {
					e.pending = false;
					if (Std.isOfType(e.value, String)) e.value = where(1) + e.value;
				}
				err = e;
			}
		}
		return err;
	}

	/**
	 * Parses and compiles a Lua chunk, returning the resulting closure bound
	 * to the given environment.
	 *
	 * @param src Source code.
	 * @param chunkname Chunk name (`=`-prefixed, `@`-prefixed, or raw source).
	 * @param env Environment value (usually the globals table).
	 * @returns The compiled Lua closure.
	 */
	public function load(src:String, chunkname:String, env:Dynamic):LuaClosure {
		var name = chunkId(chunkname);
		var fi = LParser.parse(src, name);
		var proto = LCode.compile(fi, name);
		return new LuaClosure(proto, [new Cell(env)]);
	}

	/**
	 * Creates a new (suspended) coroutine from a Lua function.
	 *
	 * @param fn Lua function to run inside the coroutine.
	 * @returns The new coroutine.
	 */
	public function newThread(fn:Dynamic):Coroutine {
		var co = new Coroutine();
		co.fn = fn;
		return co;
	}

	/**
	 * Resumes a coroutine.
	 *
	 * @param co Coroutine to resume.
	 * @param args Values passed to the coroutine (initial args or yielded-in values).
	 * @returns `[true, values...]` on success, or `[false, error]` on failure.
	 */
	public function resume(co:Coroutine, args:Array<Dynamic>):Array<Dynamic> {
		if (co.status == Coroutine.DEAD) return [false, "cannot resume dead coroutine"];
		if (co.status != Coroutine.SUSPENDED) return [false, "cannot resume non-suspended coroutine"];
		if (nCcalls >= MAXCCALLS) return [false, "C stack overflow"];
		var prev = cur;
		prev.status = Coroutine.NORMAL;
		co.status = Coroutine.RUNNING;
		cur = co;
		nCcalls++;
		var svNoPos = noPos;
		noPos = false;
		try {
			if (!co.started) {
				co.started = true;
				var stack = co.stack;
				stack[0] = co.fn;
				for (i in 0...args.length) stack[1 + i] = args[i];
				co.sp = 1 + args.length;
				var r = precall(co, 0, args.length, -1, null);
				if (r == 1) {
					co.ci.isBoundary = true;
					LVM.execute(this, co);
				}
			} else {
				placeResults(co, co.yRet, args, co.yNres);
				LVM.execute(this, co);
			}
		} catch (e:LuaError) {
			noPos = svNoPos;
			cur = prev;
			prev.status = Coroutine.RUNNING;
			nCcalls--;
			co.status = Coroutine.DEAD;
			if (e.pending) {
				e.pending = false;
				if (Std.isOfType(e.value, String) && co.ci != null) e.value = where(1) + e.value;
			}
			co.errorValue = e.value;
			return [false, e.value];
		}
		noPos = svNoPos;
		cur = prev;
		prev.status = Coroutine.RUNNING;
		nCcalls--;
		if (co.status == Coroutine.SUSPENDED) return okRes(co.transfer);
		co.status = Coroutine.DEAD;
		return okRes(co.stack.slice(0, co.sp));
	}

	/**
	 * Implements `coroutine.close`: marks the coroutine as dead, closes any
	 * pending to-be-closed variables, and clears the frame stack.
	 *
	 * @param co Coroutine to close.
	 * @returns `[true]` on success, or `[false, error]` if a `__close` raised.
	 */
	public function closeThread(co:Coroutine):Array<Dynamic> {
		if (co.status == Coroutine.SUSPENDED || co.status == Coroutine.DEAD) {
			var wasDead = co.status == Coroutine.DEAD;
			co.status = Coroutine.DEAD;
			var err:LuaError = (wasDead && co.errorValue != null) ? new LuaError(co.errorValue) : null;
			err = closeTbc(co, 0, err);
			co.ci = null;
			co.errorValue = null;
			if (err != null) return [false, err.value];
			return [true];
		}
		return error("cannot close a " + (co.status == Coroutine.RUNNING ? "running" : "normal") + " coroutine");
	}
}