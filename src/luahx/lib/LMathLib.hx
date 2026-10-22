package luahx.lib;

import haxe.Int64;
import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * lmathlib.c — Implementation of the `math` library.
 *
 * Uses the xoshiro256** PRNG from Lua 5.4/5.5, so `math.random` produces
 * the same sequence as reference Lua for a given seed.
 */
class LMathLib {
	static var s0:Int64;
	static var s1:Int64;
	static var s2:Int64;
	static var s3:Int64;

	/**
	 * 64-bit left rotation.
	 *
	 * @param x Value to rotate.
	 * @param n Rotation amount in bits (`1..63`).
	 * @returns The rotated value.
	 */
	static inline function rotl(x:Int64, n:Int):Int64
		return (x << n) | (x >>> (64 - n));

	/**
	 * Produces the next 64-bit xoshiro256** output and advances the state.
	 *
	 * @returns A pseudorandom 64-bit integer.
	 */
	static function nextRand():Int64 {
		var r = rotl(s1 * Int64.ofInt(5), 7) * Int64.ofInt(9);
		var t = s1 << 17;
		s2 = s2 ^ s0;
		s3 = s3 ^ s1;
		s1 = s1 ^ s2;
		s0 = s0 ^ s3;
		s2 = s2 ^ t;
		s3 = rotl(s3, 45);
		return r;
	}

	/**
	 * Seeds the xoshiro256** state and warms it up with 16 draws so
	 * similar seeds diverge immediately.
	 *
	 * @param n1 First seed word.
	 * @param n2 Second seed word.
	 */
	static function setSeed(n1:Int64, n2:Int64):Void {
		s0 = n1;
		s1 = Int64.ofInt(0xff);
		s2 = n2;
		s3 = Int64.ofInt(0);
		for (i in 0...16)
			nextRand();
	}

	/**
	 * Reduces a raw 64-bit draw into the range `[0, n]`.
	 *
	 * When `n + 1` is a power of two, the mask path is exact and cheap.
	 * Otherwise a rejection loop is used to keep the distribution uniform.
	 *
	 * @param ran Raw 64-bit random value.
	 * @param n Inclusive upper bound.
	 * @returns A uniform value in `[0, n]`.
	 */
	static function project(ran:Int64, n:Int64):Int64 {
		var zero = Int64.ofInt(0);
		if ((n & (n + Int64.ofInt(1))) == zero)
			return ran & n;
		// Fill in the low bits of `n` to build the rejection mask.
		var lim = n;
		lim = lim | (lim >>> 1);
		lim = lim | (lim >>> 2);
		lim = lim | (lim >>> 4);
		lim = lim | (lim >>> 8);
		lim = lim | (lim >>> 16);
		lim = lim | (lim >>> 32);
		ran = ran & lim;
		while (Int64.ucompare(ran, n) > 0)
			ran = nextRand() & lim;
		return ran;
	}

	/**
	 * Returns a Lua number representing the integer value of `f`, or the
	 * original float if `f` has no integer form.
	 *
	 * @param f Float value.
	 * @returns Integer representation or `LFloat(f)`.
	 */
	static function numInt(f:Float):Dynamic {
		var r = LNum.floatToInt(f);
		return r != null ? r : new LFloat(f);
	}

	/**
	 * Registers the `math` module and its functions.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var M = new LTable();
		L.globals.setStr("math", M);
		M.setStr("pi", new LFloat(3.141592653589793));
		M.setStr("huge", new LFloat(Math.POSITIVE_INFINITY));
		M.setStr("maxinteger", LNum.mkInt(LNum.MAXINT));
		M.setStr("mininteger", LNum.mkInt(LNum.MININT));
		// Seed deterministically from the wall clock at module-open time.
		setSeed(LNum.f2i(Date.now().getTime()), Int64.ofInt(0));

		/**
		 * Registers a one-argument float function under `name`.
		 *
		 * @param name Lua function name.
		 * @param fn Underlying math implementation.
		 */
		function f1(name:String, fn:Float->Float)
			LAux.reg(M, name, function(a) return [new LFloat(fn(LAux.checkNum(L, a, 0, name)))]);
		f1("sqrt", LNum.fsqrt);
		f1("sin", function(x) return LNum.ftrig(Math.sin, x));
		f1("cos", function(x) return LNum.ftrig(Math.cos, x));
		f1("tan", function(x) return LNum.ftrig(Math.tan, x));
		f1("asin", function(x) return LNum.farc(Math.asin, x));
		f1("acos", function(x) return LNum.farc(Math.acos, x));
		f1("exp", LNum.fexp);
		LAux.reg(M, "atan", function(a) return [
			new LFloat(Math.atan2(LAux.checkNum(L, a, 0, "atan"), LAux.optNum(L, a, 1, "atan", 1.0)))
		]);
		LAux.reg(M, "log", function(a) {
			var x = LAux.checkNum(L, a, 0, "log");
			if (a.length < 2 || a[1] == null)
				return [new LFloat(LNum.flog(x))];
			var b = LAux.checkNum(L, a, 1, "log");
			return [new LFloat(LNum.fdiv(LNum.flog(x), LNum.flog(b)))];
		});
		LAux.reg(M, "floor", function(a) {
			var v = LAux.checkNumber(L, a, 0, "floor");
			if (LNum.isInteger(v))
				return [v];
			return [numInt(LNum.ffloor(LNum.toFloat(v)))];
		});
		LAux.reg(M, "ceil", function(a) {
			var v = LAux.checkNumber(L, a, 0, "ceil");
			if (LNum.isInteger(v))
				return [v];
			return [numInt(LNum.fceil(LNum.toFloat(v)))];
		});
		LAux.reg(M, "abs", function(a) {
			var v = LAux.checkNumber(L, a, 0, "abs");
			if (LNum.isInteger(v)) {
				var i = LNum.toI64(v);
				return [i < Int64.ofInt(0) ? LNum.mkInt(-i) : v];
			}
			return [new LFloat(Math.abs(LNum.toFloat(v)))];
		});
		LAux.reg(M, "fmod", function(a) {
			var x = LAux.checkNumber(L, a, 0, "fmod");
			var y = LAux.checkNumber(L, a, 1, "fmod");
			if (LNum.isInteger(x) && LNum.isInteger(y)) {
				var d = LNum.toI64(y);
				// `fmod(x, 0)` is an error; `fmod(x, -1)` is always 0.
				if (d == Int64.ofInt(0))
					LAux.argError(L, 1, "fmod", "zero");
				if (d == Int64.ofInt(-1))
					return [0];
				return [LNum.mkInt(LNum.toI64(x) % d)];
			}
			return [new LFloat(LNum.ffmod(LNum.toFloat(x), LNum.toFloat(y)))];
		});
		LAux.reg(M, "modf", function(a) {
			var x = LAux.checkNum(L, a, 0, "modf");
			// For infinities, Lua returns (inf, 0.0) with matching signs.
			if (x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY)
				return [new LFloat(x), new LFloat(0.0)];
			// Truncate toward zero for the integer part, then compute the fraction.
			var ip = x >= 0 ? LNum.ffloor(x) : LNum.fceil(x);
			return [new LFloat(ip), new LFloat(x != x ? x : x - ip)];
		});
		LAux.reg(M, "tointeger", function(a) {
			LAux.checkAny(L, a, 0, "tointeger");
			return [LNum.toInteger(a[0])];
		});
		LAux.reg(M, "type", function(a) {
			LAux.checkAny(L, a, 0, "type");
			var k = LNum.numKind(a[0]);
			// Returns `nil` for non-numbers, `"float"` or `"integer"` otherwise.
			return [k == 0 ? null : (k == 3 ? "float" : "integer")];
		});
		LAux.reg(M, "ult", function(a) {
			var x = LAux.checkInteger(L, a, 0, "ult");
			var y = LAux.checkInteger(L, a, 1, "ult");
			return [Int64.ucompare(x, y) < 0];
		});
		LAux.reg(M, "max", function(a) {
			var m = LAux.checkNumber(L, a, 0, "max");
			for (i in 1...a.length) {
				var v = LAux.checkNumber(L, a, i, "max");
				if (LNum.numCompare(m, v) == -1)
					m = v;
			}
			return [m];
		});
		LAux.reg(M, "min", function(a) {
			var m = LAux.checkNumber(L, a, 0, "min");
			for (i in 1...a.length) {
				var v = LAux.checkNumber(L, a, i, "min");
				if (LNum.numCompare(v, m) == -1)
					m = v;
			}
			return [m];
		});
		LAux.reg(M, "random", function(a) {
			var rv = nextRand();
			var low:Int64;
			var up:Int64;
			switch (a.length) {
				case 0:
					// 53 random bits -> uniform double in [0, 1).
					return [new LFloat(LNum.i64ToFloat(rv >>> 11) * (0.5 / 4503599627370496.0))];
				case 1:
					low = Int64.ofInt(1);
					up = LAux.checkInteger(L, a, 0, "random");
					// `math.random(0)` returns the raw integer draw (Lua 5.4 feature).
					if (up == Int64.ofInt(0))
						return [LNum.mkInt(rv)];
				case 2:
					low = LAux.checkInteger(L, a, 0, "random");
					up = LAux.checkInteger(L, a, 1, "random");
				default:
					return L.error("wrong number of arguments");
			}
			if (low > up)
				LAux.argError(L, a.length - 1, "random", "interval is empty");
			return [LNum.mkInt(project(rv, up - low) + low)];
		});
		LAux.reg(M, "randomseed", function(a) {
			if (a.length == 0) {
				// No explicit seed: derive two words from the clock and RNG and return them.
				var n1 = LNum.f2i(Date.now().getTime());
				var n2 = LNum.f2i(Math.random() * 4294967296.0);
				setSeed(n1, n2);
				return [LNum.mkInt(n1), LNum.mkInt(n2)];
			}
			var n1:Int64;
			var v = LAux.checkNumber(L, a, 0, "randomseed");
			if (LNum.isInteger(v))
				n1 = LNum.toI64(v);
			else {
				var f = LNum.toFloat(v);
				var iv = LNum.floatToInt(f);
				// Non-integral floats are hashed through their IEEE bits.
				n1 = iv != null ? LNum.toI64(iv) : LNum.encodeIEEE(f, 11, 52);
			}
			var n2 = a.length > 1 && a[1] != null ? LAux.checkInteger(L, a, 1, "randomseed") : Int64.ofInt(0);
			setSeed(n1, n2);
			return [LNum.mkInt(n1), LNum.mkInt(n2)];
		});
	}
}
