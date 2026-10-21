package luahx.vm;

import haxe.Int64;
import luahx.vm.LObject;

/**
 * lobject.c (luaO_arith, luaO_str2num, luaO_tostring) + lvm.c (low-level
 * arithmetic and comparisons).
 *
 * Integers are real 64-bit values (`Int` when they fit in 32 bits, `LInt64`
 * otherwise); floats are always boxed (`LFloat`) so `1` and `1.0` stay
 * distinguishable on every target.
 */
class LNum {
	public static inline var OP_ADD = 0;
	public static inline var OP_SUB = 1;
	public static inline var OP_MUL = 2;
	public static inline var OP_MOD = 3;
	public static inline var OP_POW = 4;
	public static inline var OP_DIV = 5;
	public static inline var OP_IDIV = 6;
	public static inline var OP_BAND = 7;
	public static inline var OP_BOR = 8;
	public static inline var OP_BXOR = 9;
	public static inline var OP_SHL = 10;
	public static inline var OP_SHR = 11;
	public static inline var OP_UNM = 12;
	public static inline var OP_BNOT = 13;

	/** Sentinel returned by {@link arith} when the operands are not numeric. */
	public static final FAIL:Dynamic = new Cell(null);

	public static final MAXINT:Int64 = Int64.make(0x7FFFFFFF, 0xFFFFFFFF);
	public static final MININT:Int64 = Int64.make(0x80000000, 0);
	static final I0:Int64 = Int64.ofInt(0);
	static final I1:Int64 = Int64.ofInt(1);

	static inline var LN10 = 2.302585092994046;

	/**
	 * `Math.floor` equivalent that returns a `Float`. The standard `Math.floor`
	 * returns `Int`, which overflows on static targets for out-of-range values.
	 *
	 * @param x Input value.
	 * @returns `floor(x)` as a float, preserving `NaN` / infinities.
	 */
	public static function ffloor(x:Float):Float {
		if (x != x || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var t = x - (x % 1.0);
		return t > x ? t - 1 : t;
	}

	/**
	 * `Math.ceil` equivalent that returns a `Float`, for the same reason as
	 * {@link ffloor}.
	 *
	 * @param x Input value.
	 * @returns `ceil(x)` as a float, preserving `NaN` / infinities.
	 */
	public static function fceil(x:Float):Float {
		if (x != x || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var t = x - (x % 1.0);
		return t < x ? t + 1 : t;
	}

	/**
	 * Rounds `x` to the nearest integer (half away from zero), returning a
	 * `Float`.
	 *
	 * @param x Input value.
	 * @returns The rounded value.
	 */
	static function rndF(x:Float):Float {
		var t = x - (x % 1.0);
		return (x - t) >= 0.5 ? t + 1 : t;
	}

	/**
	 * Returns whether `x` is negative zero, i.e. `x == 0` with the sign bit set.
	 *
	 * @param x Input value.
	 * @returns `true` for `-0.0`.
	 */
	public static function isNegZero(x:Float):Bool
		return x == 0 && Math.atan2(0.0, x) > 0;

	/**
	 * IEEE 754-compliant division. Returns `NaN` for `0/0`, signed infinity
	 * when dividing a nonzero value by zero, and the regular quotient
	 * otherwise.
	 *
	 * @param x Numerator.
	 * @param y Denominator.
	 * @returns `x / y` following IEEE 754 semantics.
	 */
	public static function fdiv(x:Float, y:Float):Float {
		if (y == 0) {
			if (x == 0 || x != x) return Math.NaN;
			var neg = (x < 0) != isNegZero(y);
			return neg ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
		}
		return x / y;
	}

	/**
	 * IEEE 754-compliant `x^y`, reproducing C's `pow` corner cases:
	 * any base raised to zero is one, `1^y` is one, and zero raised to a
	 * negative exponent yields signed infinity.
	 *
	 * @param x Base.
	 * @param y Exponent.
	 * @returns `x^y` following IEEE 754 semantics.
	 */
	public static function fpow(x:Float, y:Float):Float {
		if (y == 0) return 1.0;
		if (x == 1) return 1.0;
		if (x != x || y != y) return Math.NaN;
		if (x == 0) {
			if (y < 0) {
				var odd = y == ffloor(y) && Math.abs(y) < 9007199254740992.0 && (ffloor(y) % 2 != 0);
				return (odd && isNegZero(x)) ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
			}
			return 0.0;
		}
		try {
			return Math.pow(x, y);
		} catch (e:Dynamic) {
			if (x < 0 && y != ffloor(y)) return Math.NaN;
			var odd = y == ffloor(y) && Math.abs(y) < 9007199254740992.0 && (ffloor(y) % 2 != 0);
			var big = (Math.abs(x) > 1) == (y > 0);
			if (!big) return (x < 0 && odd) ? -0.0 : 0.0;
			return (x < 0 && odd) ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
		}
	}

	/**
	 * IEEE 754 square root: `sqrt` of a negative number is `NaN`.
	 *
	 * @param x Input value.
	 * @returns `sqrt(x)`.
	 */
	public static function fsqrt(x:Float):Float
		return x < 0 ? Math.NaN : Math.sqrt(x);

	/**
	 * IEEE 754 natural logarithm: negative values yield `NaN`, zero yields
	 * negative infinity.
	 *
	 * @param x Input value.
	 * @returns `ln(x)`.
	 */
	public static function flog(x:Float):Float {
		if (x != x || x < 0) return Math.NaN;
		if (x == 0) return Math.NEGATIVE_INFINITY;
		if (x == Math.POSITIVE_INFINITY) return x;
		return Math.log(x);
	}

	/**
	 * IEEE 754 exponential, clamped to avoid overflowing intermediate values
	 * (returns positive infinity above ~709.78, zero below ~-745.2).
	 *
	 * @param x Input value.
	 * @returns `e^x`.
	 */
	public static function fexp(x:Float):Float {
		if (x != x) return x;
		if (x > 709.782712893384) return Math.POSITIVE_INFINITY;
		if (x < -745.2) return 0.0;
		return Math.exp(x);
	}

	/**
	 * Calls a trigonometric function, mapping `NaN` / infinity arguments to
	 * `NaN` (as IEEE 754 requires).
	 *
	 * @param f Underlying math function.
	 * @param x Input value.
	 * @returns `f(x)`.
	 */
	public static function ftrig(f:Float->Float, x:Float):Float {
		if (x != x || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return Math.NaN;
		return f(x);
	}

	/**
	 * Calls an inverse trigonometric function, mapping out-of-domain arguments
	 * to `NaN`.
	 *
	 * @param f Underlying math function.
	 * @param x Input value.
	 * @returns `f(x)`.
	 */
	public static function farc(f:Float->Float, x:Float):Float {
		if (x != x || x > 1 || x < -1) return Math.NaN;
		return f(x);
	}

	/**
	 * IEEE 754 `fmod`: returns `NaN` for a zero divisor or a `NaN`/infinite
	 * dividend, and passes the dividend through unchanged when the divisor is
	 * infinite.
	 *
	 * @param x Dividend.
	 * @param y Divisor.
	 * @returns `x mod y` (C `fmod` semantics).
	 */
	public static function ffmod(x:Float, y:Float):Float {
		if (y == 0 || x != x || y != y || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return Math.NaN;
		if (y == Math.POSITIVE_INFINITY || y == Math.NEGATIVE_INFINITY) return x;
		return x % y;
	}

	/**
	 * `2^n` with overflow/underflow clamped to the IEEE double range.
	 * Used instead of `haxe.io.FPHelper`, which produces wrong results on
	 * some targets (e.g. Python).
	 *
	 * @param n Exponent.
	 * @returns `2^n` as a double.
	 */
	static function pow2(n:Int):Float {
		if (n > 1023) return Math.POSITIVE_INFINITY;
		if (n < -1074) return 0.0;
		return Math.pow(2, n);
	}

	/**
	 * Decomposes a positive finite `x` into `m * 2^e2`, where `m` is an exact
	 * integer (`m < 2^53`).
	 *
	 * @param x Positive finite value.
	 * @returns `{m, e2}` such that `x == m * 2^e2`.
	 */
	public static function decompose(x:Float):{m:Float, e2:Int} {
		var e = Std.int(ffloor(Math.log(x) / 0.6931471805599453));
		while (e > -1074 && pow2(e) > x) e--;
		while (pow2(e + 1) <= x) e++;
		if (e < -1022) e = -1022;
		return {m: x / pow2(e - 52), e2: e - 52};
	}

	/**
	 * Round-to-nearest-even of a float to an integer-valued float.
	 *
	 * @param f Input value.
	 * @returns The rounded value as a float.
	 */
	static function rne(f:Float):Float {
		var fl = ffloor(f);
		var d = f - fl;
		return d > 0.5 ? fl + 1 : (d < 0.5 ? fl : (fl % 2 == 0 ? fl : fl + 1));
	}

	/**
	 * Encodes `x` in IEEE 754 binary format.
	 *
	 * @param x Value to encode.
	 * @param ebits Number of exponent bits (11 for double, 8 for single).
	 * @param mbits Number of mantissa bits (52 for double, 23 for single).
	 * @returns The raw bit pattern as a 64-bit integer.
	 */
	public static function encodeIEEE(x:Float, ebits:Int, mbits:Int):Int64 {
		var bias = (1 << (ebits - 1)) - 1;
		var maxE = (1 << ebits) - 1;
		var sign = x < 0 || (x == 0 && isNegZero(x));
		if (sign) x = -x;
		var biased:Int;
		var frac = I0;
		if (x != x) {
			biased = maxE;
			frac = I1 << (mbits - 1);
		} else if (x == Math.POSITIVE_INFINITY) biased = maxE;
		else if (x == 0) biased = 0;
		else {
			var e = Std.int(ffloor(Math.log(x) / 0.6931471805599453));
			while (e > -1100 && pow2(e) > x) e--;
			while (pow2(e + 1) <= x) e++;
			var emin = 1 - bias;
			if (e < emin) {
				var fr = rne(x / pow2(emin - mbits));
				if (fr >= pow2(mbits)) { biased = 1; frac = I0; }
				else { biased = 0; frac = f2i(fr); }
			} else {
				var r = rne(x / pow2(e - mbits));
				if (r >= pow2(mbits + 1)) {
					r = r / 2;
					e++;
				}
				if (e > bias) { biased = maxE; frac = I0; }
				else {
					biased = e + bias;
					frac = f2i(r - pow2(mbits));
				}
			}
		}
		var bits = (Int64.ofInt(biased) << mbits) | frac;
		if (sign) bits = bits | (I1 << (ebits + mbits));
		return bits;
	}

	/**
	 * Decodes an IEEE 754 binary bit pattern into a Haxe `Float`.
	 *
	 * @param bits Raw bit pattern.
	 * @param ebits Number of exponent bits (11 for double, 8 for single).
	 * @param mbits Number of mantissa bits (52 for double, 23 for single).
	 * @returns The decoded value.
	 */
	public static function decodeIEEE(bits:Int64, ebits:Int, mbits:Int):Float {
		var bias = (1 << (ebits - 1)) - 1;
		var maxE = (1 << ebits) - 1;
		var sign = ((bits >>> (ebits + mbits)) & I1) == I1;
		var biased = ((bits >>> mbits) & Int64.ofInt(maxE)).low;
		var frac = i64ToFloat(bits & ((I1 << mbits) - I1));
		var r:Float;
		if (biased == maxE) r = frac == 0 ? Math.POSITIVE_INFINITY : Math.NaN;
		else if (biased == 0) r = frac * pow2(1 - bias - mbits);
		else r = (pow2(mbits) + frac) * pow2(biased - bias - mbits);
		return sign ? -r : r;
	}

	/**
	 * Returns the Lua type name of a value (without consulting metatables).
	 *
	 * @param v Value to inspect.
	 * @returns One of `"nil"`, `"boolean"`, `"string"`, `"number"`, `"table"`,
	 *          `"function"`, `"thread"` or `"userdata"`.
	 */
	public static function typeName(v:Dynamic):String {
		if (v == null) return "nil";
		if (Std.isOfType(v, Bool)) return "boolean";
		if (Std.isOfType(v, String)) return "string";
		if (Std.isOfType(v, Int) || Std.isOfType(v, LFloat) || Std.isOfType(v, LInt64)) return "number";
		if (Std.isOfType(v, LTable)) return "table";
		if (Std.isOfType(v, LuaFunction)) return "function";
		if (Std.isOfType(v, Coroutine)) return "thread";
		return "userdata";
	}

	/**
	 * Classifies the numeric representation of a value.
	 *
	 * @param v Value to inspect.
	 * @returns `0` if not a number, `1` for `Int`, `2` for `LInt64`, `3` for `LFloat`.
	 */
	public static inline function numKind(v:Dynamic):Int {
		if (Std.isOfType(v, Int)) return 1;
		if (Std.isOfType(v, LFloat)) return 3;
		if (Std.isOfType(v, LInt64)) return 2;
		return 0;
	}

	/**
	 * Checks whether `v` holds a Lua number (integer or float).
	 *
	 * @param v Value to test.
	 * @returns `true` if `v` is a number.
	 */
	public static inline function isNumber(v:Dynamic):Bool
		return numKind(v) != 0;

	/**
	 * Checks whether `v` is a Lua integer (`Int` or `LInt64`).
	 *
	 * @param v Value to test.
	 * @returns `true` if `v` is an integer.
	 */
	public static inline function isInteger(v:Dynamic):Bool {
		var k = numKind(v);
		return k == 1 || k == 2;
	}

	/**
	 * Boxes an `Int64` as an `Int` when it fits, or as an `LInt64` otherwise.
	 *
	 * @param i Value to box.
	 * @returns The Lua integer representation.
	 */
	public static inline function mkInt(i:Int64):Dynamic {
		if (i.high == (i.low >> 31)) {
			var r:Int = i.low;
			return r;
		}
		return new LInt64(i);
	}

	/**
	 * Boxes an integer-valued `Float` (`|f| < 2^53`) as a Lua integer.
	 *
	 * @param f Integer-valued float.
	 * @returns The Lua integer representation.
	 */
	public static inline function mkIntF(f:Float):Dynamic {
		if (f >= -2147483648.0 && f <= 2147483647.0) {
			var r:Int = Std.int(f);
			return r;
		}
		return new LInt64(f2i(f));
	}

	/**
	 * Boxes a `Float` as a Lua float.
	 *
	 * @param f Value to box.
	 * @returns The `LFloat` wrapper.
	 */
	public static inline function mkFloat(f:Float):Dynamic
		return new LFloat(f);

	/**
	 * Converts an integer-valued `Float` in the 64-bit range to an exact
	 * `Int64`. `Int64.fromFloat` loses precision beyond 2^53, so we split the
	 * value into high and low 32-bit halves manually.
	 *
	 * @param f Integer-valued float (`|f| < 2^63`).
	 * @returns The exact `Int64` value.
	 */
	public static function f2i(f:Float):Int64 {
		var hi = ffloor(f / 4294967296.0);
		var lo = f - hi * 4294967296.0;
		var loI:Int = lo >= 2147483648.0 ? Std.int(lo - 4294967296.0) : Std.int(lo);
		return Int64.make(Std.int(hi), loI);
	}

	/**
	 * Converts an `Int` or `LInt64` to `Int64`.
	 *
	 * @param v Integer value.
	 * @returns The `Int64` representation.
	 */
	public static function toI64(v:Dynamic):Int64 {
		if (Std.isOfType(v, Int)) {
			var i:Int = v;
			return Int64.ofInt(i);
		}
		return (cast v : LInt64).v;
	}

	/**
	 * Converts an `Int64` to `Float`, going through 32-bit halves to avoid
	 * `Int64` precision issues.
	 *
	 * @param i Value to convert.
	 * @returns The equivalent float (may lose precision beyond 2^53).
	 */
	public static function i64ToFloat(i:Int64):Float {
		var hi:Float = i.high;
		var lo:Float = i.low;
		if (lo < 0) lo += 4294967296.0;
		return hi * 4294967296.0 + lo;
	}

	/**
	 * Converts any Lua number to a Haxe `Float`.
	 *
	 * @param v Numeric value.
	 * @returns The equivalent float.
	 */
	public static function toFloat(v:Dynamic):Float {
		if (Std.isOfType(v, Int)) {
			var i:Int = v;
			return i * 1.0;
		}
		if (Std.isOfType(v, LFloat)) return (cast v : LFloat).v;
		return i64ToFloat((cast v : LInt64).v);
	}

	/**
	 * Converts a `Float` to a Lua integer if it is integral and within the
	 * 64-bit range.
	 *
	 * @param f Value to convert.
	 * @returns The Lua integer, or `null` if not representable.
	 */
	public static function floatToInt(f:Float):Dynamic {
		if (f != ffloor(f)) return null;
		if (f >= -9223372036854775808.0 && f < 9223372036854775808.0) {
			if (f >= -2147483648.0 && f <= 2147483647.0) {
				var r:Int = Std.int(f);
				return r;
			}
			return new LInt64(f2i(f));
		}
		return null;
	}

	/**
	 * Coerces a value to a Lua number, converting numeric strings if needed.
	 *
	 * @param v Value to coerce.
	 * @returns The Lua number, or `null` if the value is not convertible.
	 */
	public static function toNumber(v:Dynamic):Dynamic {
		if (isNumber(v)) return v;
		if (Std.isOfType(v, String)) return str2number(v);
		return null;
	}

	/**
	 * Coerces a value to a Lua integer, converting integral floats and
	 * numeric strings.
	 *
	 * @param v Value to coerce.
	 * @returns The Lua integer, or `null` if the value has no integer form.
	 */
	public static function toInteger(v:Dynamic):Dynamic {
		var n = toNumber(v);
		if (n == null) return null;
		if (Std.isOfType(n, LFloat)) return floatToInt((cast n : LFloat).v);
		return n;
	}

	/**
	 * Returns the 64-bit integer representation of `v` for bitwise ops,
	 * accepting integral floats. Throws if the value has no integer form.
	 *
	 * @param v Value to convert.
	 * @returns The `Int64` bits of `v`.
	 */
	static inline function bitsOf(v:Dynamic):Int64 {
		var n = toNumber(v);
		if (n == null) return null;
		if (Std.isOfType(n, LFloat)) {
			var r = floatToInt((cast n : LFloat).v);
			if (r == null) throw new LuaError("number has no integer representation", true);
			return toI64(r);
		}
		return toI64(n);
	}

	/**
	 * Shift-left with Lua semantics: shifts by `>= 64` or `<= -64` return
	 * zero, negative shifts become logical right shifts.
	 *
	 * @param a Value to shift.
	 * @param n Shift amount (negative for right shifts).
	 * @returns The shifted value.
	 */
	public static function shiftLeft(a:Int64, n:Int64):Int64 {
		if (Int64.compare(n, Int64.ofInt(-64)) <= 0 || Int64.compare(n, Int64.ofInt(64)) >= 0) return I0;
		var s = n.low;
		if (s >= 0) return a << s;
		return a >>> (-s);
	}

	/**
	 * Unsigned integer division, matching Lua's `//` for unsigned operands.
	 *
	 * @param a Dividend.
	 * @param b Divisor.
	 * @returns `a / b` (unsigned).
	 */
	public static function udiv(a:Int64, b:Int64):Int64 {
		if (b < I0) return Int64.ucompare(a, b) >= 0 ? I1 : I0;
		if (a >= I0) return a / b;
		var q = ((a >>> 1) / b) << 1;
		var r = a - q * b;
		if (Int64.ucompare(r, b) >= 0) q = q + I1;
		return q;
	}

	/**
	 * Floor division of `Int64` values, matching Lua's integer `//`.
	 *
	 * @param a Dividend.
	 * @param b Divisor.
	 * @returns `floor(a / b)`.
	 */
	public static function floorDiv64(a:Int64, b:Int64):Int64 {
		var q = a / b;
		if ((a % b) != I0 && ((a ^ b) < I0)) q = q - I1;
		return q;
	}

	/**
	 * Lua's `%` for floats: the result has the sign of the divisor, and
	 * zero divisors return `NaN`.
	 *
	 * @param a Dividend.
	 * @param b Divisor.
	 * @returns `a mod b` with Lua semantics.
	 */
	public static function fmod(a:Float, b:Float):Float {
		var m = ffmod(a, b);
		if ((m > 0) ? b < 0 : (m < 0 && b != m)) m += b;
		return m;
	}

	/**
	 * Performs a Lua arithmetic or bitwise operation on two values, coercing
	 * numeric strings. Returns {@link FAIL} if either operand is not numeric
	 * (the caller is then expected to try metamethods).
	 *
	 * @param op Opcode (`OP_ADD`, `OP_SUB`, ..., `OP_BNOT`).
	 * @param a Left operand.
	 * @param b Right operand (ignored for `OP_UNM` / `OP_BNOT`).
	 * @returns The result, or `FAIL`.
	 */
	public static function arith(op:Int, a:Dynamic, b:Dynamic):Dynamic {
		var ka = numKind(a);
		var kb = numKind(b);
		if (op >= OP_BAND && op != OP_UNM) { // bitwise operations
			var x = bitsOf(a);
			var y = op == OP_BNOT ? x : bitsOf(b);
			if (x == null || y == null) return FAIL;
			switch (op) {
				case OP_BAND: return mkInt(x & y);
				case OP_BOR: return mkInt(x | y);
				case OP_BXOR: return mkInt(x ^ y);
				case OP_SHL: return mkInt(shiftLeft(x, y));
				case OP_SHR: return mkInt(shiftLeft(x, -y));
				default: return mkInt(~x);
			}
		}
		if (ka == 0) {
			a = toNumber(a);
			if (a == null) return FAIL;
			ka = numKind(a);
		}
		if (kb == 0) {
			b = toNumber(b);
			if (b == null) return FAIL;
			kb = numKind(b);
		}
		if (op == OP_UNM) {
			if (ka == 1) {
				var i:Int = a;
				if (i == -2147483648) return mkInt(-Int64.ofInt(i));
				return -i;
			}
			if (ka == 2) return mkInt(-(cast a : LInt64).v);
			return new LFloat((cast a : LFloat).v * -1.0);
		}
		if (ka <= 2 && kb <= 2 && op != OP_DIV && op != OP_POW) { // both integers
			if (ka == 1 && kb == 1) {
				var x:Int = a;
				var y:Int = b;
				switch (op) {
					case OP_ADD:
						var r:Float = x * 1.0 + y;
						return mkIntF(r);
					case OP_SUB:
						var r:Float = x * 1.0 - y;
						return mkIntF(r);
					case OP_MUL:
						var r:Float = x * 1.0 * y;
						if (r > -9007199254740992.0 && r < 9007199254740992.0) return mkIntF(r);
						return mkInt(Int64.ofInt(x) * Int64.ofInt(y));
					case OP_IDIV:
						if (y == 0) throw new LuaError("attempt to divide by zero", true);
						var r:Float = x * 1.0;
						return mkIntF(ffloor(r / y));
					case OP_MOD:
						if (y == 0) throw new LuaError("attempt to perform 'n%0'", true);
						var m = x % y;
						if (m != 0 && (m ^ y) < 0) m += y;
						return m;
				}
			}
			var x = toI64(a);
			var y = toI64(b);
			switch (op) {
				case OP_ADD: return mkInt(x + y);
				case OP_SUB: return mkInt(x - y);
				case OP_MUL: return mkInt(x * y);
				case OP_IDIV:
					if (y == I0) throw new LuaError("attempt to divide by zero", true);
					if (y == Int64.ofInt(-1)) return mkInt(-x);
					return mkInt(floorDiv64(x, y));
				case OP_MOD:
					if (y == I0) throw new LuaError("attempt to perform 'n%0'", true);
					if (y == Int64.ofInt(-1)) return 0;
					var m = x % y;
					if (m != I0 && ((m ^ y) < I0)) m = m + y;
					return mkInt(m);
			}
		}
		var x = toFloat(a);
		var y = toFloat(b);
		switch (op) {
			case OP_ADD: return new LFloat(x + y);
			case OP_SUB: return new LFloat(x - y);
			case OP_MUL: return new LFloat(x * y);
			case OP_DIV: return new LFloat(fdiv(x, y));
			case OP_POW: return new LFloat(y == 2 ? x * x : fpow(x, y));
			case OP_IDIV: return new LFloat(ffloor(fdiv(x, y)));
			case OP_MOD:
				if (y == Math.POSITIVE_INFINITY && x == x && x != Math.POSITIVE_INFINITY && x != Math.NEGATIVE_INFINITY)
					return new LFloat(x >= 0 ? x : (x == 0 ? x : y));
				if (y == Math.NEGATIVE_INFINITY && x == x && x != Math.POSITIVE_INFINITY && x != Math.NEGATIVE_INFINITY)
					return new LFloat(x <= 0 ? x : y);
				return new LFloat(fmod(x, y));
		}
		return FAIL;
	}

	/**
	 * Compares an integer and a float without losing precision by comparing
	 * against the integer part of the float first, then the fractional part.
	 *
	 * @param i Integer operand.
	 * @param f Float operand.
	 * @returns `-1`, `0`, `1` for ordering, or `2` if the float is `NaN`.
	 */
	static function cmpIntFloat(i:Int64, f:Float):Int {
		if (f != f) return 2;
		if (f >= 9223372036854775808.0) return -1;
		if (f < -9223372036854775808.0) return 1;
		var fl = ffloor(f);
		var c = Int64.compare(i, f2i(fl));
		if (c < 0) return -1;
		if (c > 0) return 1;
		return f > fl ? -1 : 0;
	}

	/**
	 * Compares two Lua numbers (integers or floats) with full precision.
	 *
	 * @param a Left operand (must be a number).
	 * @param b Right operand (must be a number).
	 * @returns `-1`, `0`, `1` for ordering, or `2` when unordered (`NaN`).
	 */
	public static function numCompare(a:Dynamic, b:Dynamic):Int {
		var ka = numKind(a);
		var kb = numKind(b);
		if (ka == 1 && kb == 1) {
			var x:Int = a;
			var y:Int = b;
			return x < y ? -1 : (x > y ? 1 : 0);
		}
		if (ka == 3 && kb == 3) {
			var x = (cast a : LFloat).v;
			var y = (cast b : LFloat).v;
			return x < y ? -1 : (x > y ? 1 : (x == y ? 0 : 2));
		}
		if (ka != 3 && kb != 3) {
			var c = Int64.compare(toI64(a), toI64(b));
			return c < 0 ? -1 : (c > 0 ? 1 : 0);
		}
		if (ka == 3) {
			var c = cmpIntFloat(toI64(b), (cast a : LFloat).v);
			return c == 2 ? 2 : -c;
		}
		return cmpIntFloat(toI64(a), (cast b : LFloat).v);
	}

	/**
	 * Raw Lua equality (no metamethods). Numbers compare across integer and
	 * float representations.
	 *
	 * @param a Left operand.
	 * @param b Right operand.
	 * @returns Whether the two values are equal.
	 */
	public static function rawEquals(a:Dynamic, b:Dynamic):Bool {
		if (a == null) return b == null;
		if (b == null) return false;
		if (Std.isOfType(a, String)) {
			if (!Std.isOfType(b, String)) return false;
			var x:String = a;
			var y:String = b;
			return x == y;
		}
		if (Std.isOfType(a, Bool)) {
			if (!Std.isOfType(b, Bool)) return false;
			var x:Bool = a;
			var y:Bool = b;
			return x == y;
		}
		var ka = numKind(a);
		if (ka != 0) {
			var kb = numKind(b);
			if (kb == 0) return false;
			return numCompare(a, b) == 0;
		}
		return a == b;
	}

	inline static function isSpace(c:Int):Bool
		return c == 32 || (c >= 9 && c <= 13);

	inline static function hexVal(c:Int):Int {
		if (c >= 48 && c <= 57) return c - 48;
		if (c >= 97 && c <= 102) return c - 87;
		if (c >= 65 && c <= 70) return c - 55;
		return -1;
	}

	/**
	 * Lua's `luaO_str2num`: parses a full numeric literal (decimal or
	 * `0x`-prefixed hexadecimal, optional sign, fraction and exponent).
	 *
	 * @param s Source string.
	 * @returns The parsed number (integer or `LFloat`), or `null` on failure.
	 */
	public static function str2number(s:String):Dynamic {
		var n = s.length;
		var i = 0;
		while (i < n && isSpace(s.charCodeAt(i))) i++;
		while (n > i && isSpace(s.charCodeAt(n - 1))) n--;
		if (i >= n) return null;
		var neg = false;
		var c = s.charCodeAt(i);
		if (c == 45) { neg = true; i++; }
		else if (c == 43) i++;
		if (i >= n) return null;
		if (i + 1 < n && s.charCodeAt(i) == 48 && (s.charCodeAt(i + 1) | 32) == 120) { // `0x` prefix
			i += 2;
			var mant = I0;
			var fm:Float = 0.0;
			var any = false;
			var isFloat = false;
			var exp = 0;
			while (i < n && hexVal(s.charCodeAt(i)) >= 0) {
				var h = hexVal(s.charCodeAt(i));
				mant = (mant << 4) + Int64.ofInt(h);
				fm = fm * 16 + h;
				any = true;
				i++;
			}
			if (i < n && s.charCodeAt(i) == 46) {
				isFloat = true;
				i++;
				while (i < n && hexVal(s.charCodeAt(i)) >= 0) {
					fm = fm * 16 + hexVal(s.charCodeAt(i));
					exp -= 4;
					any = true;
					i++;
				}
			}
			if (!any) return null;
			if (i < n && (s.charCodeAt(i) | 32) == 112) { // `p` exponent
				isFloat = true;
				i++;
				var eneg = false;
				if (i < n && (s.charCodeAt(i) == 43 || s.charCodeAt(i) == 45)) {
					eneg = s.charCodeAt(i) == 45;
					i++;
				}
				if (i >= n) return null;
				var e = 0;
				var anyE = false;
				while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
					e = e * 10 + (s.charCodeAt(i) - 48);
					anyE = true;
					i++;
				}
				if (!anyE) return null;
				exp += eneg ? -e : e;
			}
			if (i != n) return null;
			if (!isFloat) return mkInt(neg ? -mant : mant);
			var r = fm * Math.pow(2, exp);
			return new LFloat(neg ? -r : r);
		}
		// decimal path
		var start = i;
		var digits = 0;
		var isFloat = false;
		var acc = I0;
		var overflow = false;
		var maxBy10 = Int64.make(0x0CCCCCCC, 0xCCCCCCCC); // 922337203685477580
		while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
			var d = s.charCodeAt(i) - 48;
			if (!overflow) {
				var cmp = Int64.compare(acc, maxBy10);
				if (cmp > 0 || (cmp == 0 && d > 7 + (neg ? 1 : 0))) overflow = true;
				else acc = acc * Int64.ofInt(10) + Int64.ofInt(d);
			}
			digits++;
			i++;
		}
		if (i < n && s.charCodeAt(i) == 46) {
			isFloat = true;
			i++;
			while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
				digits++;
				i++;
			}
		}
		if (digits == 0) return null;
		if (i < n && (s.charCodeAt(i) | 32) == 101) { // `e` exponent
			isFloat = true;
			i++;
			if (i < n && (s.charCodeAt(i) == 43 || s.charCodeAt(i) == 45)) i++;
			var ed = 0;
			while (i < n && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
				ed++;
				i++;
			}
			if (ed == 0) return null;
		}
		if (i != n) return null;
		if (!isFloat && !overflow) return mkInt(neg ? -acc : acc);
		var f = Std.parseFloat(s.substring(start, n));
		return new LFloat(neg ? -f : f);
	}

	/**
	 * Formats a Lua number as a string (`tostring` semantics).
	 *
	 * @param v Numeric value.
	 * @returns The textual form.
	 */
	public static function numToString(v:Dynamic):String {
		var k = numKind(v);
		if (k == 1) return Std.string(v);
		if (k == 2) return Int64.toStr((cast v : LInt64).v);
		return floatToString((cast v : LFloat).v);
	}

	/**
	 * Formats a float using Lua's `%.14g` rule, appending `.0` when the
	 * output looks like an integer (so `1` and `1.0` print differently).
	 *
	 * @param f Float value.
	 * @returns The textual form.
	 */
	public static function floatToString(f:Float):String {
		if (f != f) return "nan";
		if (f == Math.POSITIVE_INFINITY) return "inf";
		if (f == Math.NEGATIVE_INFINITY) return "-inf";
		var s = fmtG(f, 14, false, false);
		var looksInt = true;
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (!(c == 45 || (c >= 48 && c <= 57))) {
				looksInt = false;
				break;
			}
		}
		return looksInt ? s + ".0" : s;
	}

	/**
	 * Produces the exact decimal expansion of `x` (`x > 0`, finite) as
	 * `d[0].d[1..] * 10^e`, using bignum arithmetic in base 1e7.
	 *
	 * @param x Positive finite value.
	 * @returns `{d, e}` where `d` has no leading zeros and `d.length >= 1`.
	 */
	static function exactDecimal(x:Float):{d:String, e:Int} {
		var dc = decompose(x);
		var m = dc.m;
		var e2 = dc.e2;
		var limbs:Array<Float> = [];
		var f = m;
		while (f > 0) {
			var l = f % 1e7;
			limbs.push(l);
			f = (f - l) / 1e7;
		}
		if (limbs.length == 0) limbs.push(0);
		if (e2 >= 0) mulPow(limbs, 2, e2);
		else mulPow(limbs, 5, -e2);
		var sb = new StringBuf();
		var i = limbs.length - 1;
		sb.add(Std.string(Std.int(limbs[i])));
		while (--i >= 0) sb.add(StringTools.lpad(Std.string(Std.int(limbs[i])), "0", 7));
		var str = sb.toString();
		return {d: str, e: str.length - 1 + (e2 >= 0 ? 0 : e2)};
	}

	/**
	 * Multiplies a base-1e7 limb array by `base^n`, using repeated small
	 * multiplications to stay within exact float precision.
	 *
	 * @param limbs Limb array (modified in place).
	 * @param base Base to exponentiate (2 or 5).
	 * @param n Exponent.
	 */
	static function mulPow(limbs:Array<Float>, base:Int, n:Int):Void {
		var chunk = base == 2 ? 22 : 9;
		while (n > 0) {
			var k = n >= chunk ? chunk : n;
			mulSmall(limbs, Math.pow(base, k));
			n -= k;
		}
	}

	/**
	 * Multiplies a base-1e7 limb array by a single scalar.
	 *
	 * @param limbs Limb array (modified in place).
	 * @param f Scalar factor.
	 */
	static function mulSmall(limbs:Array<Float>, f:Float):Void {
		var carry = 0.0;
		for (i in 0...limbs.length) {
			var v = limbs[i] * f + carry;
			var l = v % 1e7;
			limbs[i] = l;
			carry = (v - l) / 1e7;
		}
		while (carry > 0) {
			var l = carry % 1e7;
			limbs.push(l);
			carry = (carry - l) / 1e7;
		}
	}

	/**
	 * Rounds a decimal string to `nd` significant digits using
	 * round-half-to-even on the exact value.
	 *
	 * @param d Decimal digits (no decimal point).
	 * @param e Decimal exponent of `d[0]`.
	 * @param nd Target number of significant digits.
	 * @returns The rounded digits and exponent.
	 */
	static function roundSig(d:String, e:Int, nd:Int):{d:String, e:Int} {
		if (nd < 0) return {d: "", e: e};
		if (d.length <= nd) return {d: d + zeros(nd - d.length), e: e};
		var next = d.charCodeAt(nd) - 48;
		var up:Bool;
		if (next > 5) up = true;
		else if (next < 5) up = false;
		else {
			var tail = false;
			for (i in nd + 1...d.length)
				if (d.charCodeAt(i) != 48) {
					tail = true;
					break;
				}
			up = tail || (nd > 0 && (d.charCodeAt(nd - 1) - 48) % 2 == 1);
		}
		var r = d.substr(0, nd);
		if (!up) return {d: r, e: e};
		var arr = [for (i in 0...r.length) r.charCodeAt(i) - 48];
		var i = arr.length - 1;
		while (i >= 0) {
			if (arr[i] == 9) {
				arr[i] = 0;
				i--;
			} else {
				arr[i]++;
				break;
			}
		}
		if (i < 0) { // 99.. -> 100..
			if (nd == 0) return {d: "1", e: e + 1};
			return {d: "1" + zeros(nd - 1), e: e + 1};
		}
		return {d: arr.join(""), e: e};
	}

	/**
	 * Returns the exact decimal digits of `x` rounded to `nd` significant
	 * digits.
	 *
	 * @param x Positive finite value.
	 * @param nd Target significant digits.
	 * @returns The rounded digits and exponent.
	 */
	static function digitsOf(x:Float, nd:Int):{d:String, e:Int} {
		var ex = exactDecimal(x);
		return roundSig(ex.d, ex.e, nd);
	}

	/**
	 * Returns `n` zero characters as a string.
	 *
	 * @param n Number of zeros.
	 * @returns The zero string.
	 */
	static function zeros(n:Int):String {
		var b = new StringBuf();
		for (i in 0...n) b.addChar(48);
		return b.toString();
	}

	/**
	 * Formats an exponent suffix (e.g. `e+02`), with optional uppercase `E`.
	 *
	 * @param e Exponent value.
	 * @param upper Whether to emit uppercase `E`.
	 * @returns The formatted suffix.
	 */
	static function expStr(e:Int, upper:Bool):String {
		var a = e < 0 ? -e : e;
		return (upper ? "E" : "e") + (e < 0 ? "-" : "+") + (a < 10 ? "0" : "") + a;
	}

	static function isNeg(x:Float):Bool
		return x < 0 || (x == 0 && isNegZero(x));

	/**
	 * Formats `x` like C's `%e`.
	 *
	 * @param x Value to format.
	 * @param prec Digits after the decimal point.
	 * @param alt Alternate form (always emit a decimal point).
	 * @param upper Uppercase `E`.
	 * @returns The formatted string.
	 */
	public static function fmtE(x:Float, prec:Int, alt:Bool, upper:Bool):String {
		var neg = isNeg(x);
		if (neg) x = -x;
		var d:String;
		var e:Int;
		if (x == 0) { d = zeros(prec + 1); e = 0; }
		else { var r = digitsOf(x, prec + 1); d = r.d; e = r.e; }
		var s = d.charAt(0) + (prec > 0 ? "." + d.substr(1) : (alt ? "." : "")) + expStr(e, upper);
		return neg ? "-" + s : s;
	}

	/**
	 * Formats `x` like C's `%f`.
	 *
	 * @param x Value to format.
	 * @param prec Digits after the decimal point.
	 * @param alt Alternate form (always emit a decimal point).
	 * @returns The formatted string.
	 */
	public static function fmtF(x:Float, prec:Int, alt:Bool):String {
		var neg = isNeg(x);
		if (neg) x = -x;
		var R = "";
		var e = 0;
		if (x != 0) {
			var ex = exactDecimal(x);
			var nd = ex.e + 1 + prec;
			if (nd >= 0) {
				var rr = roundSig(ex.d, ex.e, nd);
				R = rr.d;
				e = rr.e;
			} else e = ex.e;
		}
		var ip = new StringBuf();
		if (R.length == 0 || e < 0) ip.add("0");
		else for (i in 0...e + 1) ip.add(i < R.length ? R.charAt(i) : "0");
		var s = ip.toString();
		if (prec > 0 || alt) s += ".";
		for (j in 1...prec + 1) {
			var idx = e + j;
			s += (idx >= 0 && idx < R.length) ? R.charAt(idx) : "0";
		}
		return neg ? "-" + s : s;
	}

	/**
	 * Formats `x` like C's `%g`: uses `%e` when the exponent is `< -4` or
	 * `>= prec`, and `%f` otherwise, stripping trailing zeros unless `alt`.
	 *
	 * @param x Value to format.
	 * @param prec Significant digits.
	 * @param alt Alternate form (keep trailing zeros, always emit a decimal point).
	 * @param upper Uppercase `E`.
	 * @returns The formatted string.
	 */
	public static function fmtG(x:Float, prec:Int, alt:Bool, upper:Bool):String {
		if (prec == 0) prec = 1;
		var neg = isNeg(x);
		if (neg) x = -x;
		var d:String;
		var e:Int;
		if (x == 0) { d = zeros(prec); e = 0; }
		else { var r = digitsOf(x, prec); d = r.d; e = r.e; }
		var s:String;
		if (e < -4 || e >= prec) {
			var frac = d.substr(1);
			if (!alt) frac = stripZeros(frac);
			s = d.charAt(0) + (frac.length > 0 ? "." + frac : (alt ? "." : "")) + expStr(e, upper);
		} else {
			var ip:String;
			var fp:String;
			if (e >= 0) { ip = d.substr(0, e + 1); fp = d.substr(e + 1); }
			else { ip = "0"; fp = zeros(-e - 1) + d; }
			if (!alt) fp = stripZeros(fp);
			s = ip + (fp.length > 0 ? "." + fp : (alt ? "." : ""));
		}
		return neg ? "-" + s : s;
	}

	/**
	 * Removes trailing zeros from a decimal string.
	 *
	 * @param s Source string.
	 * @returns The stripped string.
	 */
	static function stripZeros(s:String):String {
		var n = s.length;
		while (n > 0 && s.charCodeAt(n - 1) == 48) n--;
		return s.substr(0, n);
	}

	/**
	 * Formats `x` like C's `%a` (hexadecimal floating point).
	 *
	 * @param x Value to format.
	 * @param prec Digits after the point (`-1` = minimal, no trailing zeros).
	 * @param upper Uppercase output.
	 * @returns The formatted string.
	 */
	public static function fmtA(x:Float, prec:Int, upper:Bool):String {
		var neg = isNeg(x);
		if (neg) x = -x;
		var s:String;
		if (x == 0) s = "0x0p+0";
		else {
			var dc = decompose(x);
			var normal = dc.m >= 4503599627370496.0;
			var lead = normal ? "1" : "0";
			var e = normal ? dc.e2 + 52 : -1022;
			var mant = f2i(normal ? dc.m - 4503599627370496.0 : dc.m);
			var hex = StringTools.hex(mant.high, 5) + StringTools.hex(mant.low, 8);
			hex = hex.substr(hex.length - 13).toLowerCase();
			hex = prec >= 0 ? (prec < 13 ? hex.substr(0, prec) : hex + zeros(prec - 13)) : stripZeros(hex);
			s = "0x" + lead + (hex.length > 0 ? "." + hex : "") + "p" + (e < 0 ? "-" : "+") + (e < 0 ? -e : e);
		}
		if (upper) s = s.toUpperCase();
		return neg ? "-" + s : s;
	}
}