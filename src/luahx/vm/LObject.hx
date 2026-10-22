package luahx.vm;

import haxe.Int64;

/*
 * lobject.h / lfunc.h — Haxe representation of Lua values.
 *
 * ```
 * nil      -> null
 * boolean  -> Bool
 * integer  -> Int     (when it fits in 32 bits)  |  LInt64 (rest of the 64-bit range)
 * float    -> LFloat  (always boxed, so 1 and 1.0 stay distinct on every target, JS included)
 * string   -> String  (each char holds one byte, 0..255)
 * table    -> LTable
 * function -> LuaClosure | NativeFunction
 * thread   -> Coroutine
 * userdata -> any other Haxe object
 * ```
 */

/**
 * Boxed 32-bit floating point.
 */
final class LFloat {
	public final v:Float;

	public inline function new(v:Float)
		this.v = v;
}

/** Boxed 64-bit integer, used for values outside the 32-bit `Int` range. */
final class LInt64 {
	public final v:Int64;

	public inline function new(v:Int64)
		this.v = v;
}

/** Upvalue cell / captured variable slot. */
final class Cell {
	public var v:Dynamic;

	public inline function new(v:Dynamic)
		this.v = v;
}

/**
 * Lua error thrown via `throw`.
 *
 * When `pending` is `true`, the VM has not yet prefixed the value with
 * `chunk:line:` — this is deferred so the location reflects where the error
 * actually propagates.
 */
final class LuaError {
	public var value:Dynamic;
	public var pending:Bool;
	public var traceback:String = null;

	public function new(value:Dynamic, pending:Bool = false) {
		this.value = value;
		this.pending = pending;
	}

	public function toString():String
		return Std.isOfType(value, String) ? value : (value == null ? "nil" : "(error object is a " + LNum.typeName(value) + " value)");
}

/**
 * Description of a single upvalue of a prototype.
 *
 * When `inStack` is `true`, `idx` refers to a local slot in the parent
 * function (the value gets captured when the closure is created); otherwise
 * it refers to an upvalue of the parent.
 */
final class UpvalDesc {
	public var name:String;
	public var inStack:Bool;
	public var idx:Int;

	public function new(name:String, inStack:Bool, idx:Int) {
		this.name = name;
		this.inStack = inStack;
		this.idx = idx;
	}
}

/**
 * Function prototype (bytecode).
 *
 * Instruction `i` is encoded as the tuple `(ops[i], a[i], b[i], c[i])`.
 * `d1[i]`/`d2[i]` carry the textual description of the operands at that
 * instruction, only used to build error messages.
 */
final class Proto {
	public var ops:Array<Int> = [];
	public var a:Array<Int> = [];
	public var b:Array<Int> = [];
	public var c:Array<Int> = [];
	public var lines:Array<Int> = [];
	public var d1:Array<String> = [];
	public var d2:Array<String> = [];
	public var consts:Array<Dynamic> = [];
	public var protos:Array<Proto> = [];
	public var upvals:Array<UpvalDesc> = [];
	public var nparams:Int = 0;
	public var isVararg:Bool = false;
	public var source:String = "?";
	public var lineDefined:Int = 0;
	public var lastLine:Int = 0;

	public function new() {}
}

/** Userdata with an optional metatable (used by `io`: files, etc.). */
final class LuaUserdata {
	public var meta:LTable;
	public var data:Dynamic;

	public function new(data:Dynamic, meta:LTable) {
		this.data = data;
		this.meta = meta;
	}
}

/** Base class for callable values (Lua closures and native functions). */
class LuaFunction {
	public function new() {}
}

/** Lua closure: a prototype plus its captured upvalue cells. */
final class LuaClosure extends LuaFunction {
	public final p:Proto;
	public final upvals:Array<Cell>;

	public function new(p:Proto, upvals:Array<Cell>) {
		super();
		this.p = p;
		this.upvals = upvals;
	}
}

/**
 * Native function implemented in Haxe.
 *
 * `special` is interpreted by the VM's call dispatcher:
 * `1` = `pcall`, `2` = `xpcall`, `3` = `yield`.
 */
final class NativeFunction extends LuaFunction {
	public var name:String;
	public var fn:Array<Dynamic>->Array<Dynamic>;
	public var special:Int = 0;

	public function new(name:String, fn:Array<Dynamic>->Array<Dynamic>, special:Int = 0) {
		super();
		this.name = name;
		this.fn = fn;
		this.special = special;
	}
}

/**
 * Activation record (`lstate.h`'s `CallInfo`).
 *
 * Call frames are stored on the heap and linked via `prev`, so Lua->Lua
 * recursion does not grow the Haxe call stack.
 */
final class CallInfo {
	public var cl:LuaClosure;
	public var base:Int;
	public var pc:Int = 0;
	public var retPos:Int;
	public var nres:Int;
	public var varargs:Array<Dynamic>;
	public var depth:Int = 1;
	public var isBoundary:Bool = false;
	public var isPcall:Bool = false;
	public var handler:Dynamic = null;
	public var prev:CallInfo;

	public function new() {}
}

/** Thread / coroutine (`lua_State`). */
final class Coroutine {
	public static inline var SUSPENDED = 0;
	public static inline var RUNNING = 1;
	public static inline var NORMAL = 2;
	public static inline var DEAD = 3;

	public var stack:Array<Dynamic> = [];
	public var sp:Int = 0;
	public var ci:CallInfo = null;
	public var status:Int = SUSPENDED;
	public var fn:Dynamic = null;
	public var started:Bool = false;

	/** > 0 while a yield is forbidden (inside a native call that cannot yield across). */
	public var nny:Int = 0;

	public var nmulti:Int = 0;
	public var transfer:Array<Dynamic> = null;
	public var yRet:Int = 0;
	public var yNres:Int = 0;
	public var tbc:Array<Int> = [];
	public var depth:Int = 0;
	public var isMain:Bool = false;
	public var errorValue:Dynamic = null;

	public function new() {}
}

/**
 * Internal state of a numeric `for` loop.
 *
 * Loops start in the float fast path (`idx`, `step`, `count` in doubles) and
 * fall back to the 64-bit path (`i64`, `s64`, `c64`) only when the values
 * cannot be represented exactly as doubles.
 */
final class ForState {
	public var isFloat:Bool = false;
	public var big:Bool = false;
	public var idx:Float = 0;
	public var step:Float = 0;

	/** Iteration count in the fast path (|values| < 2^53), or the limit in float loops. */
	public var count:Float = 0;

	public var i64:Int64;
	public var s64:Int64;

	/** Unsigned 64-bit counter (used in the `big` path). */
	public var c64:Int64;

	public function new() {}
}
