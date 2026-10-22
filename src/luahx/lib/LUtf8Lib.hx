package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LStr;
import luahx.vm.LTable;

/**
 * lutf8lib.c — Implementation of the `utf8` library for Lua 5.5.
 *
 * Notable difference from Lua 5.3/5.4: `utf8.offset` returns both the start
 * and end index of the character, matching 5.5's revised contract.
 */
class LUtf8Lib {
	static inline var MAXUNICODE = 0x10FFFF;
	static inline var MAXUTF = 0x7FFFFFFF;

	/** Minimum encoded value per length (`limits[n]` is the smallest value needing `n` bytes). */
	static final limits:Array<Int> = [-1, 0x80, 0x800, 0x10000, 0x200000, 0x4000000];

	static inline function at(s:String, i:Int):Int
		return i < s.length ? s.charCodeAt(i) : 0;

	static inline function iscont(s:String, i:Int):Bool
		return (at(s, i) & 0xC0) == 0x80;

	/**
	 * Decodes a single UTF-8 sequence starting at `s[i]`.
	 *
	 * @param s Byte-per-char source string.
	 * @param i Index of the leading byte.
	 * @param strict When `true`, rejects code points above `MAXUNICODE` and
	 *               surrogate halves (as `utf8.len`/`utf8.codepoint` do when
	 *               called without `lax`).
	 * @returns `[codepoint, nextIndex]`, or `null` on invalid encoding.
	 */
	static function decode(s:String, i:Int, strict:Bool):Array<Int> {
		var c = at(s, i);
		var res = 0;
		var j = i;
		if (c < 0x80)
			res = c;
		else {
			var count = 0;
			while ((c & 0x40) != 0) {
				var cc = i + (++count) < s.length ? s.charCodeAt(i + count) : 0;
				if ((cc & 0xC0) != 0x80)
					return null;
				res = (res << 6) | (cc & 0x3F);
				c <<= 1;
			}
			res |= ((c & 0x7F) << (count * 5));
			// Reject overlong encodings and sequences longer than 6 bytes.
			if (count > 5 || res > MAXUTF || res < limits[count])
				return null;
			j = i + count;
		}
		if (strict && (res > MAXUNICODE || (res >= 0xD800 && res <= 0xDFFF)))
			return null;
		return [res, j + 1];
	}

	/**
	 * Converts a possibly-negative (end-relative) position into an absolute
	 * 1-based index, clamped to `0` when it falls before the start.
	 *
	 * @param pos Position (negative values count from the end of the string).
	 * @param len String length.
	 * @returns The absolute 1-based position (or `0` if out of range).
	 */
	static function uPosRelat(pos:Int, len:Int):Int {
		if (pos >= 0)
			return pos;
		if (-pos > len)
			return 0;
		return len + pos + 1;
	}

	/**
	 * Registers the `utf8` module and its functions (`char`, `len`,
	 * `codepoint`, `offset`, `codes`) into the given state's globals.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var U = new LTable();
		L.globals.setStr("utf8", U);
		var ch = String.fromCharCode;
		// `charpattern` matches one whole UTF-8-encoded character.
		U.setStr("charpattern", "[" + ch(0) + "-" + ch(0x7F) + ch(0xC2) + "-" + ch(0xFD) + "][" + ch(0x80) + "-" + ch(0xBF) + "]*");
		LAux.reg(U, "char", function(a) {
			var b = new StringBuf();
			for (i in 0...a.length) {
				var c = LAux.checkInteger(L, a, i, "char");
				if (c < haxe.Int64.ofInt(0) || c > haxe.Int64.ofInt(MAXUTF))
					LAux.argError(L, i, "char", "value out of range");
				b.add(LStr.utf8Encode(c.low));
			}
			return [b.toString()];
		});
		LAux.reg(U, "len", function(a) {
			var s = LAux.checkStr(L, a, 0, "len");
			var len = s.length;
			var posi = uPosRelat(LAux.optInt(L, a, 1, "len", 1), len);
			var posj = uPosRelat(LAux.optInt(L, a, 2, "len", -1), len);
			var lax = !LuaState.isFalse(a.length > 3 ? a[3] : null);
			if (!(1 <= posi && --posi <= len))
				LAux.argError(L, 1, "len", "initial position out of bounds");
			if (!(--posj < len))
				LAux.argError(L, 2, "len", "final position out of bounds");
			var n = 0;
			while (posi <= posj) {
				var r = decode(s, posi, !lax);
				// On the first invalid byte, return `(nil, indexOfBadByte)`.
				if (r == null)
					return [null, posi + 1];
				posi = r[1];
				n++;
			}
			return [n];
		});
		LAux.reg(U, "codepoint", function(a) {
			var s = LAux.checkStr(L, a, 0, "codepoint");
			var len = s.length;
			var posi = uPosRelat(LAux.optInt(L, a, 1, "codepoint", 1), len);
			var pose = uPosRelat(LAux.optInt(L, a, 2, "codepoint", posi), len);
			var lax = !LuaState.isFalse(a.length > 3 ? a[3] : null);
			if (posi < 1)
				LAux.argError(L, 1, "codepoint", "out of bounds");
			if (pose > len)
				LAux.argError(L, 2, "codepoint", "out of bounds");
			var r:Array<Dynamic> = [];
			var i = posi - 1;
			while (i < pose) {
				var d = decode(s, i, !lax);
				if (d == null)
					L.error("invalid UTF-8 code");
				r.push(d[0]);
				i = d[1];
			}
			return r;
		});
		LAux.reg(U, "offset", function(a) {
			var s = LAux.checkStr(L, a, 0, "offset");
			var len = s.length;
			var n = LAux.checkInt(L, a, 1, "offset");
			var posi = uPosRelat(LAux.optInt(L, a, 2, "offset", n > 0 ? 1 : len + 1), len);
			if (!(1 <= posi && --posi <= len))
				LAux.argError(L, 2, "offset", "position out of bounds");
			if (n == 0) {
				// `n == 0`: return the start of the character containing `posi`.
				while (posi > 0 && iscont(s, posi))
					posi--;
			} else {
				if (iscont(s, posi))
					L.error("initial position is a continuation byte");
				if (n < 0) {
					// Walk backwards `-n` characters, skipping continuation bytes.
					while (n < 0 && posi > 0) {
						do
							posi-- while (posi > 0 && iscont(s, posi));
						n++;
					}
				} else {
					// Walk forwards `n - 1` characters, skipping continuation bytes.
					n--;
					while (n > 0 && posi < len) {
						do
							posi++ while (iscont(s, posi));
						n--;
					}
				}
			}
			if (n != 0)
				return [null];
			// 5.5 addition: return the character's end index as well.
			var e = posi;
			if (e < len) {
				e++;
				while (iscont(s, e))
					e++;
			}
			return [posi + 1, e];
		});
		/**
		 * Builds one `codes` iterator. `lax` selects strict or permissive
		 * UTF-8 validation; each closure is created once and reused across
		 * `utf8.codes` calls so that repeated iteration doesn't allocate.
		 *
		 * @param lax Whether to accept code points above `MAXUNICODE` / surrogates.
		 * @returns The iterator function.
		 */
		var iter = function(lax:Bool) return new NativeFunction("codes_iter", function(a) {
			var s = LAux.checkStr(L, a, 0, "codes");
			var n = LAux.checkInt(L, a, 1, "codes");
			// Skip the tail of the previously yielded character.
			if (n < s.length)
				while (iscont(s, n))
					n++;
			if (n >= s.length)
				return [null];
			var d = decode(s, n, !lax);
			if (d == null || iscont(s, d[1]))
				L.error("invalid UTF-8 code");
			return [n + 1, d[0]];
		});
		var strictIter = iter(false);
		var laxIter = iter(true);
		LAux.reg(U, "codes", function(a) {
			var s = LAux.checkStr(L, a, 0, "codes");
			var lax = !LuaState.isFalse(a.length > 1 ? a[1] : null);
			if (iscont(s, 0))
				L.error("invalid UTF-8 code");
			return [lax ? laxIter : strictIter, s, 0];
		});
	}
}
