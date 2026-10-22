package luahx.lib;

import haxe.Int64;
import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * Mutable state threaded through the pattern matcher.
 *
 * `capStart`/`capLen` hold the start offset and length of each active
 * capture; `capLen` uses the sentinel `CAP_UNFINISHED` for captures still
 * being matched and `CAP_POSITION` for position captures (`()`).
 *
 * The same instance can be reused across matches via {@link reprep}, which
 * resets the capture stack and the recursion depth budget.
 */
private class MatchState {
	public var src:String;
	public var pat:String;
	public var level:Int = 0;
	public var capStart:Array<Int> = [];
	public var capLen:Array<Int> = [];
	public var depth:Int = 200;
	public var L:LuaState;

	public function new(L:LuaState, src:String, pat:String) {
		this.L = L;
		this.src = src;
		this.pat = pat;
	}

	/**
	 * Resets per-match state so the same `MatchState` can be reused across
	 * iterations of `gmatch` / `gsub`.
	 */
	public function reprep():Void {
		level = 0;
		depth = 200;
	}
}

/**
 * lstrlib.c — Implementation of the `string` library: Lua patterns, `format`,
 * and pack/unpack (delegated to {@link LStrPack}).
 */
class LStrLib {
	static inline var CAP_UNFINISHED = -1;
	static inline var CAP_POSITION = -2;
	static inline var L_ESC = 37;
	static inline var SPECIALS = "^$*+?.([%-";

	/**
	 * Character class tests, matching the C locale used by Lua:
	 * `isalpha`, `isdigit`, `islower`, `isupper`, `isspace`, `iscntrl`,
	 * `isgraph`, `ispunct`, `isxdigit`.
	 */
	static inline function isAlpha(c:Int):Bool
		return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

	static inline function isDigit(c:Int):Bool
		return c >= 48 && c <= 57;

	static inline function isLower(c:Int):Bool
		return c >= 97 && c <= 122;

	static inline function isUpper(c:Int):Bool
		return c >= 65 && c <= 90;

	static inline function isSpace(c:Int):Bool
		return c == 32 || (c >= 9 && c <= 13);

	static inline function isCntrl(c:Int):Bool
		return c < 32 || c == 127;

	static inline function isGraph(c:Int):Bool
		return c >= 33 && c <= 126;

	static inline function isPunct(c:Int):Bool
		return isGraph(c) && !isAlpha(c) && !isDigit(c);

	static inline function isXDigit(c:Int):Bool
		return isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);

	/**
	 * Tests `c` against a `%x` character class.
	 *
	 * `cl` is the character following `%` (lowercase; uppercase letters
	 * invert the result, e.g. `%A` matches non-alpha). Any other character
	 * `x` matches only the literal `x`, mirroring Lua's `%x` escapes.
	 *
	 * @param c Candidate character.
	 * @param cl Character class specifier (e.g. `'a'`, `'D'`).
	 * @returns Whether `c` belongs to the class.
	 */
	static function matchClass(c:Int, cl:Int):Bool {
		var res:Bool;
		switch (cl | 32) {
			case 97:
				res = isAlpha(c);
			case 99:
				res = isCntrl(c);
			case 100:
				res = isDigit(c);
			case 103:
				res = isGraph(c);
			case 108:
				res = isLower(c);
			case 112:
				res = isPunct(c);
			case 115:
				res = isSpace(c);
			case 117:
				res = isUpper(c);
			case 119:
				res = isAlpha(c) || isDigit(c);
			case 120:
				res = isXDigit(c);
			default:
				return cl == c;
		}
		return isUpper(cl) ? !res : res;
	}

	static inline function pc(ms:MatchState, i:Int):Int
		return i < ms.pat.length ? ms.pat.charCodeAt(i) : 0;

	/**
	 * Returns the index just past the character class starting at `p`.
	 *
	 * Handles `%x` (2 chars), `[...]` sets (with optional `^` and escaped
	 * `]`) and single characters.
	 *
	 * @param ms Match state (for pattern access and errors).
	 * @param p Index of the class start.
	 * @returns Index just past the class.
	 */
	static function classEnd(ms:MatchState, p:Int):Int {
		var plen = ms.pat.length;
		var c = ms.pat.charCodeAt(p++);
		if (c == L_ESC) {
			if (p >= plen)
				ms.L.error("malformed pattern (ends with '%')");
			return p + 1;
		}
		if (c == 91) { // `[`
			if (pc(ms, p) == 94)
				p++; // optional `^`
			do {
				if (p >= plen)
					ms.L.error("malformed pattern (missing ']')");
				var cc = ms.pat.charCodeAt(p++);
				if (cc == L_ESC && p < plen)
					p++;
			} while (p >= plen || ms.pat.charCodeAt(p) != 93); // until `]`
			return p + 1;
		}
		return p;
	}

	/**
	 * Tests `c` against the character set `pattern[p..ec]`.
	 *
	 * @param ms Match state.
	 * @param c Character to test.
	 * @param p Index of `[`.
	 * @param ec Index of the closing `]`.
	 * @returns Whether `c` belongs to the set (respecting a leading `^`).
	 */
	static function matchBracketClass(ms:MatchState, c:Int, p:Int, ec:Int):Bool {
		var sig = true;
		if (pc(ms, p + 1) == 94) {
			sig = false;
			p++;
		}
		while (++p < ec) {
			var pp = ms.pat.charCodeAt(p);
			if (pp == L_ESC) {
				p++;
				if (matchClass(c, ms.pat.charCodeAt(p)))
					return sig;
			} else if (pc(ms, p + 1) == 45 && p + 2 < ec) { // range `a-b`
				p += 2;
				if (ms.pat.charCodeAt(p - 2) <= c && c <= ms.pat.charCodeAt(p))
					return sig;
			} else if (pp == c)
				return sig;
		}
		return !sig;
	}

	/**
	 * Tests whether `src[s]` matches the single-character pattern starting
	 * at `pattern[p]` (whose class ends at `ep`).
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param p Pattern index of the class start.
	 * @param ep Pattern index just past the class.
	 * @returns Whether the character matches.
	 */
	static function singleMatch(ms:MatchState, s:Int, p:Int, ep:Int):Bool {
		if (s >= ms.src.length)
			return false;
		var c = ms.src.charCodeAt(s);
		var pp = ms.pat.charCodeAt(p);
		switch (pp) {
			case 46:
				return true; // `.`
			case L_ESC:
				return matchClass(c, ms.pat.charCodeAt(p + 1));
			case 91:
				return matchBracketClass(ms, c, p, ep - 1);
			default:
				return pp == c;
		}
	}

	/**
	 * Implements `%bxy`: matches a balanced substring delimited by `x` and `y`.
	 *
	 * @param ms Match state.
	 * @param s Source index where the opening `x` must appear.
	 * @param p Pattern index of `x` (the `y` is at `p + 1`).
	 * @returns Index just past the closing `y`, or `-1` if unmatched.
	 */
	static function matchBalance(ms:MatchState, s:Int, p:Int):Int {
		if (p + 1 >= ms.pat.length)
			ms.L.error("malformed pattern (missing arguments to '%b')");
		if (s >= ms.src.length || ms.src.charCodeAt(s) != ms.pat.charCodeAt(p))
			return -1;
		var b = ms.pat.charCodeAt(p);
		var e = ms.pat.charCodeAt(p + 1);
		var cont = 1;
		var i = s + 1;
		while (i < ms.src.length) {
			var c = ms.src.charCodeAt(i);
			if (c == e) {
				if (--cont == 0)
					return i + 1;
			} else if (c == b)
				cont++;
			i++;
		}
		return -1;
	}

	/**
	 * Greedy quantifiers (`*` and `+`): consume as much as possible, then
	 * backtrack one character at a time until the rest of the pattern
	 * matches.
	 *
	 * @param ms Match state.
	 * @param s Source index to start from.
	 * @param p Pattern index of the class start.
	 * @param ep Pattern index just past the class (quantifier position).
	 * @returns End index of the overall match, or `-1` on failure.
	 */
	static function maxExpand(ms:MatchState, s:Int, p:Int, ep:Int):Int {
		var i = 0;
		while (singleMatch(ms, s + i, p, ep))
			i++;
		while (i >= 0) {
			var res = doMatch(ms, s + i, ep + 1);
			if (res != -1)
				return res;
			i--;
		}
		return -1;
	}

	/**
	 * Lazy quantifier (`-`): try the shortest match first, then consume one
	 * more character at a time.
	 *
	 * @param ms Match state.
	 * @param s Source index to start from.
	 * @param p Pattern index of the class start.
	 * @param ep Pattern index just past the class (quantifier position).
	 * @returns End index of the overall match, or `-1` on failure.
	 */
	static function minExpand(ms:MatchState, s:Int, p:Int, ep:Int):Int {
		while (true) {
			var res = doMatch(ms, s, ep + 1);
			if (res != -1)
				return res;
			if (singleMatch(ms, s, p, ep))
				s++;
			else
				return -1;
		}
	}

	/**
	 * Begins a capture at `s` and continues matching at `p`.
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param p Pattern index after `(`.
	 * @param what `CAP_UNFINISHED` for `(...)`, `CAP_POSITION` for `()`.
	 * @returns End index of the overall match, or `-1` on failure.
	 */
	static function startCapture(ms:MatchState, s:Int, p:Int, what:Int):Int {
		if (ms.level >= 32)
			ms.L.error("too many captures");
		ms.capStart[ms.level] = s;
		ms.capLen[ms.level] = what;
		ms.level++;
		var res = doMatch(ms, s, p);
		if (res == -1)
			ms.level--;
		return res;
	}

	/**
	 * Closes the innermost unfinished capture at `s` and continues at `p`.
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param p Pattern index after `)`.
	 * @returns End index of the overall match, or `-1` on failure.
	 */
	static function endCapture(ms:MatchState, s:Int, p:Int):Int {
		var l = -1;
		var i = ms.level - 1;
		while (i >= 0) {
			if (ms.capLen[i] == CAP_UNFINISHED) {
				l = i;
				break;
			}
			i--;
		}
		if (l < 0)
			ms.L.error("invalid pattern capture");
		ms.capLen[l] = s - ms.capStart[l];
		var res = doMatch(ms, s, p);
		if (res == -1)
			ms.capLen[l] = CAP_UNFINISHED;
		return res;
	}

	/**
	 * Validates a back-reference digit (`%1`..`%9`) and returns the capture
	 * index it refers to.
	 *
	 * @param ms Match state.
	 * @param l Character code of the digit (`'1'`..`'9'`).
	 * @returns The capture index `0..8`.
	 */
	static function checkCapture(ms:MatchState, l:Int):Int {
		l -= 49;
		if (l < 0 || l >= ms.level || ms.capLen[l] == CAP_UNFINISHED)
			ms.L.error("invalid capture index %" + (l + 1));
		return l;
	}

	/**
	 * Matches a back-reference (`%1`..`%9`) at `s` against the captured text.
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param l Character code of the digit.
	 * @returns Index just past the back-reference match, or `-1`.
	 */
	static function matchCapture(ms:MatchState, s:Int, l:Int):Int {
		l = checkCapture(ms, l);
		var len = ms.capLen[l];
		if (ms.src.length - s >= len && ms.src.substr(ms.capStart[l], len) == ms.src.substr(s, len))
			return s + len;
		return -1;
	}

	/**
	 * Wrapper around {@link doMatchInner} that enforces a recursion budget
	 * (`ms.depth`) to reject pathological patterns.
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param p Pattern index.
	 * @returns End index of the match, or `-1`.
	 */
	static function doMatch(ms:MatchState, s:Int, p:Int):Int {
		if (ms.depth-- == 0)
			ms.L.error("pattern too complex");
		var r = doMatchInner(ms, s, p);
		ms.depth++;
		return r;
	}

	/**
	 * Core recursive pattern matcher. The main loop handles one pattern item
	 * at a time: it interprets captures, anchors, escapes (`%b`, `%f`,
	 * back-references) and single-character classes with optional `?`, `+`,
	 * `*` or `-` quantifiers.
	 *
	 * @param ms Match state.
	 * @param s Source index.
	 * @param p Pattern index.
	 * @returns End index of the match, or `-1`.
	 */
	static function doMatchInner(ms:MatchState, s:Int, p:Int):Int {
		var plen = ms.pat.length;
		while (true) {
			if (p == plen)
				return s;
			var c = ms.pat.charCodeAt(p);
			var dflt = false;
			switch (c) {
				case 40: // `(`
					if (pc(ms, p + 1) == 41)
						return startCapture(ms, s, p + 2, CAP_POSITION);
					return startCapture(ms, s, p + 1, CAP_UNFINISHED);
				case 41: // `)`
					return endCapture(ms, s, p + 1);
				case 36: // `$`
					if (p + 1 == plen)
						return s == ms.src.length ? s : -1;
					dflt = true;
				case L_ESC: // `%`
					var n = pc(ms, p + 1);
					if (n == 98) { // `%b` balanced match
						s = matchBalance(ms, s, p + 2);
						if (s != -1) {
							p += 4;
							continue;
						}
						return -1;
					} else if (n == 102) { // `%f` frontier pattern
						p += 2;
						if (pc(ms, p) != 91)
							ms.L.error("missing '[' after '%f' in pattern");
						var ep = classEnd(ms, p);
						var prev = s == 0 ? 0 : ms.src.charCodeAt(s - 1);
						var curc = s < ms.src.length ? ms.src.charCodeAt(s) : 0;
						if (!matchBracketClass(ms, prev, p, ep - 1) && matchBracketClass(ms, curc, p, ep - 1)) {
							p = ep;
							continue;
						}
						return -1;
					} else if (isDigit(n)) { // back-reference
						s = matchCapture(ms, s, n);
						if (s != -1) {
							p += 2;
							continue;
						}
						return -1;
					}
					dflt = true;
				default:
					dflt = true;
			}
			// Default case: a single-character class with an optional quantifier.
			var ep = classEnd(ms, p);
			var epc = pc(ms, ep);
			if (!singleMatch(ms, s, p, ep)) {
				if (epc == 42 || epc == 63 || epc == 45) { // `*`, `?`, `-` allow zero matches
					p = ep + 1;
					continue;
				}
				return -1;
			}
			switch (epc) {
				case 63: // `?`
					var res = doMatch(ms, s + 1, ep + 1);
					if (res != -1)
						return res;
					p = ep + 1;
				case 43: // `+`
					return maxExpand(ms, s + 1, p, ep);
				case 42: // `*`
					return maxExpand(ms, s, p, ep);
				case 45: // `-`
					return minExpand(ms, s, p, ep);
				default:
					s++;
					p = ep;
			}
		}
	}

	/**
	 * Returns one capture as a Haxe value.
	 *
	 * Captures 1..n return the captured string (or the start position for a
	 * position capture). When `i == 0` and the caller did not open any
	 * captures, the whole match `src[s..e]` is returned.
	 *
	 * @param ms Match state.
	 * @param i Capture index (0-based; 0 = whole match fallback).
	 * @param s Match start in `src`.
	 * @param e Match end in `src`.
	 * @returns The captured value.
	 */
	static function getOneCapture(ms:MatchState, i:Int, s:Int, e:Int):Dynamic {
		if (i >= ms.level) {
			if (i != 0)
				ms.L.error("invalid capture index %" + (i + 1));
			return ms.src.substring(s, e);
		}
		var l = ms.capLen[i];
		if (l == CAP_UNFINISHED)
			ms.L.error("unfinished capture");
		if (l == CAP_POSITION)
			return ms.capStart[i] + 1;
		return ms.src.substr(ms.capStart[i], l);
	}

	/**
	 * Collects the captures produced by a successful match.
	 *
	 * @param ms Match state.
	 * @param s Match start in `src`.
	 * @param e Match end in `src`.
	 * @param wholeIfNone When `true`, returns the whole match if no captures were opened.
	 * @returns The list of captured values.
	 */
	static function pushCaptures(ms:MatchState, s:Int, e:Int, wholeIfNone:Bool):Array<Dynamic> {
		var n = (ms.level == 0 && wholeIfNone) ? 1 : ms.level;
		var r:Array<Dynamic> = [];
		for (i in 0...n)
			r.push(getOneCapture(ms, i, s, e));
		return r;
	}

	/**
	 * Returns `true` if the pattern contains no magic characters, so a plain
	 * `indexOf` can be used as an optimization.
	 *
	 * @param p Pattern string.
	 * @returns Whether the pattern is a plain literal.
	 */
	static function noSpecials(p:String):Bool {
		for (i in 0...p.length)
			if (SPECIALS.indexOf(p.charAt(i)) >= 0)
				return false;
		return true;
	}

	/**
	 * Converts a possibly-negative (end-relative) position into an absolute
	 * 1-based index, clamped to `1` for positions before the start.
	 *
	 * @param pos Relative position.
	 * @param len String length.
	 * @returns Absolute 1-based position.
	 */
	static function posrelatI(pos:Int, len:Int):Int {
		if (pos > 0)
			return pos;
		if (pos == 0)
			return 1;
		if (pos < -len)
			return 1;
		return len + pos + 1;
	}

	/**
	 * Converts a possibly-negative position into an absolute 1-based end
	 * index, clamped to `0`/`len` when out of range.
	 *
	 * @param pos Relative position.
	 * @param len String length.
	 * @returns Absolute 1-based end index.
	 */
	static function getEndPos(pos:Int, len:Int):Int {
		if (pos > len)
			return len;
		if (pos >= 0)
			return pos;
		if (pos < -len)
			return 0;
		return len + pos + 1;
	}

	/**
	 * Backend shared by `string.find` and `string.match`.
	 *
	 * When `find` is `true`, returns `[start, end, captures...]`; the plain
	 * substring path is used unless the pattern contains magic characters or
	 * the caller passed `plain = true`. When `find` is `false`, returns only
	 * the captures (or the whole match when the pattern has none).
	 *
	 * @param L Lua state.
	 * @param a Argument array.
	 * @param find Whether this call is for `find` (`true`) or `match` (`false`).
	 * @returns The result array.
	 */
	static function strFindAux(L:LuaState, a:Array<Dynamic>, find:Bool):Array<Dynamic> {
		var fname = find ? "find" : "match";
		var s = LAux.checkStr(L, a, 0, fname);
		var p = LAux.checkStr(L, a, 1, fname);
		var ls = s.length;
		var init = posrelatI(LAux.optInt(L, a, 2, fname, 1), ls) - 1;
		if (init > ls)
			return [null];
		if (find && (!LuaState.isFalse(a.length > 3 ? a[3] : null) || noSpecials(p))) {
			// Fast path: plain literal search.
			var idx = s.indexOf(p, init);
			if (idx < 0)
				return [null];
			return [idx + 1, idx + p.length];
		}
		var ms = new MatchState(L, s, p);
		var anchor = p.charCodeAt(0) == 94;
		var pi = anchor ? 1 : 0;
		var s1 = init;
		while (true) {
			ms.reprep();
			var e = doMatch(ms, s1, pi);
			if (e != -1) {
				if (find) {
					var r:Array<Dynamic> = [s1 + 1, e];
					return r.concat(pushCaptures(ms, -1, 0, false));
				}
				return pushCaptures(ms, s1, e, true);
			}
			s1++;
			if (s1 > ls || anchor)
				break;
		}
		return [null];
	}

	/**
	 * Appends the `gsub` replacement string `news` to `b`, expanding `%0`
	 * (whole match) and `%1`..`%9` (captures) and honoring `%%` for a
	 * literal `%`.
	 *
	 * @param ms Match state.
	 * @param b Output buffer.
	 * @param s Match start in `src`.
	 * @param e Match end in `src`.
	 * @param news Replacement template.
	 */
	static function addS(ms:MatchState, b:StringBuf, s:Int, e:Int, news:String):Void {
		var l = news.length;
		var i = 0;
		while (i < l) {
			var c = news.charCodeAt(i);
			if (c != L_ESC)
				b.addChar(c);
			else {
				i++;
				var d = i < l ? news.charCodeAt(i) : 0;
				if (d == L_ESC)
					b.addChar(L_ESC);
				else if (isDigit(d)) {
					if (d == 48)
						b.add(ms.src.substring(s, e)); // `%0`
					else {
						var cap = getOneCapture(ms, d - 49, s, e);
						b.add(Std.isOfType(cap, String) ? cap : LNum.numToString(cap));
					}
				} else
					ms.L.error("invalid use of '%' in replacement string");
			}
			i++;
		}
	}

	/**
	 * Appends one `gsub` replacement value to `b`. The replacement may be:
	 * - a template string (`kind == 0`),
	 * - a table indexed by the first capture (`kind == 1`), or
	 * - a function called with the captures (`kind == 2`).
	 *
	 * False/nil means "keep the original match".
	 *
	 * @param ms Match state.
	 * @param b Output buffer.
	 * @param s Match start in `src`.
	 * @param e Match end in `src`.
	 * @param repl The replacement (string/table/function).
	 * @param kind One of the three replacement modes above.
	 */
	static function addValue(ms:MatchState, b:StringBuf, s:Int, e:Int, repl:Dynamic, kind:Int):Void {
		var L = ms.L;
		var v:Dynamic;
		if (kind == 0) {
			addS(ms, b, s, e, repl);
			return;
		} else if (kind == 1) {
			v = L.index(repl, getOneCapture(ms, 0, s, e), null);
		} else {
			v = LuaState.first(L.call(repl, pushCaptures(ms, s, e, true)));
		}
		if (LuaState.isFalse(v))
			b.add(ms.src.substring(s, e));
		else if (Std.isOfType(v, String))
			b.add(v);
		else if (LNum.isNumber(v))
			b.add(LNum.numToString(v));
		else
			L.error("invalid replacement value (a " + LNum.typeName(v) + ")");
	}

	/**
	 * Pads `s` to `width` characters.
	 *
	 * @param s Input string.
	 * @param width Minimum width.
	 * @param left Left-justify (`-` flag) instead of right-justify.
	 * @param zero Pad with zeros (`0` flag) instead of spaces; the padding is
	 *             inserted after any sign / `0x` prefix.
	 * @returns The padded string.
	 */
	static function pad(s:String, width:Int, left:Bool, zero:Bool):String {
		if (s.length >= width)
			return s;
		var n = width - s.length;
		var sp = StringTools.rpad("", zero ? "0" : " ", n);
		if (left)
			return s + StringTools.rpad("", " ", n);
		if (zero) {
			// Keep the sign / `0x` prefix before the zero padding.
			var i = 0;
			if (s.length > 0 && (s.charAt(0) == "-" || s.charAt(0) == "+" || s.charAt(0) == " "))
				i = 1;
			if (s.length > i + 1 && s.charAt(i) == "0" && (s.charAt(i + 1) == "x" || s.charAt(i + 1) == "X"))
				i += 2;
			return s.substr(0, i) + sp + s.substr(i);
		}
		return sp + s;
	}

	/**
	 * Converts an integer to a string in the given base, treating the value
	 * as unsigned (as `%u`/`%x`/`%o` do).
	 *
	 * @param v Value to format.
	 * @param base `8`, `10` or `16`.
	 * @param upper Whether to emit uppercase hex digits.
	 * @returns The digit string.
	 */
	static function unsignedStr(v:Int64, base:Int, upper:Bool):String {
		if (v == Int64.ofInt(0))
			return "0";
		var digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
		var b = Int64.ofInt(base);
		var out = "";
		while (v != Int64.ofInt(0)) {
			var q = LNum.udiv(v, b);
			var r = v - q * b;
			out = digits.charAt(r.low) + out;
			v = q;
		}
		return out;
	}

	/**
	 * Emits `s` in a form `load` can read back (used by `%q`). Quotes are
	 * added, control characters are escaped, and strings ending in a digit
	 * are escaped as `\ddd` to avoid ambiguity.
	 *
	 * @param s String to quote.
	 * @returns The quoted/escaped string.
	 */
	static function quoteStr(s:String):String {
		var b = new StringBuf();
		b.addChar(34);
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (c == 34 || c == 92) {
				b.addChar(92);
				b.addChar(c);
			} else if (c == 10)
				b.add("\\\n");
			else if (c == 13)
				b.add("\\r");
			else if (c == 0) {
				var nx = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
				b.add(isDigit(nx) ? "\\000" : "\\0");
			} else if (isCntrl(c)) {
				var nx = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
				b.add("\\" + (isDigit(nx) ? StringTools.lpad(Std.string(c), "0", 3) : Std.string(c)));
			} else
				b.addChar(c);
		}
		b.addChar(34);
		return b.toString();
	}

	/**
	 * Implements `string.format`.
	 *
	 * Supports the standard `printf` flags (`-`, `+`, ` `, `#`, `0`), widths,
	 * precisions and the conversion specifiers `d i u o x X c f F e E g G a A s q`.
	 *
	 * @param L Lua state.
	 * @param a Argument array.
	 * @returns `[resultString]`.
	 */
	static function format(L:LuaState, a:Array<Dynamic>):Array<Dynamic> {
		var fmt = LAux.checkStr(L, a, 0, "format");
		var b = new StringBuf();
		var arg = 0;
		var i = 0;
		var n = fmt.length;
		while (i < n) {
			var c = fmt.charCodeAt(i++);
			if (c != L_ESC) {
				b.addChar(c);
				continue;
			}
			if (i >= n)
				L.error("invalid conversion '%' to 'format'");
			if (fmt.charCodeAt(i) == L_ESC) {
				b.addChar(L_ESC);
				i++;
				continue;
			}
			var start = i - 1;
			var left = false, plus = false, space = false, alt = false, zero = false;
			while (i < n) {
				var f = fmt.charAt(i);
				if (f == "-")
					left = true;
				else if (f == "+")
					plus = true;
				else if (f == " ")
					space = true;
				else if (f == "#")
					alt = true;
				else if (f == "0")
					zero = true;
				else
					break;
				i++;
			}
			var width = 0;
			var wd = 0;
			while (i < n && isDigit(fmt.charCodeAt(i))) {
				width = width * 10 + fmt.charCodeAt(i) - 48;
				i++;
				if (++wd > 2)
					L.error("invalid conversion '" + fmt.substring(start, i) + "' to 'format'");
			}
			var prec = -1;
			if (i < n && fmt.charCodeAt(i) == 46) { // `.`
				i++;
				prec = 0;
				var pd = 0;
				while (i < n && isDigit(fmt.charCodeAt(i))) {
					prec = prec * 10 + fmt.charCodeAt(i) - 48;
					i++;
					if (++pd > 2)
						L.error("invalid conversion '" + fmt.substring(start, i) + "' to 'format'");
				}
			}
			if (i >= n)
				L.error("invalid conversion '" + fmt.substring(start, i) + "' to 'format'");
			var conv = fmt.charAt(i++);
			arg++;
			var out:String;
			switch (conv) {
				case "d", "i":
					var v = LAux.checkInteger(L, a, arg, "format");
					var neg = v < Int64.ofInt(0);
					var ds = Int64.toStr(v);
					if (neg)
						ds = ds.substr(1);
					if (prec >= 0) {
						if (prec == 0 && v == Int64.ofInt(0))
							ds = "";
						ds = StringTools.lpad(ds, "0", prec);
					}
					var sign = neg ? "-" : (plus ? "+" : (space ? " " : ""));
					out = pad(sign + ds, width, left, zero && prec < 0);
				case "u":
					var v = LAux.checkInteger(L, a, arg, "format");
					out = pad(unsignedStr(v, 10, false), width, left, zero);
				case "c":
					out = pad(String.fromCharCode(LAux.checkInt(L, a, arg, "format") & 0xFF), width, left, false);
				case "x", "X", "o":
					var v = LAux.checkInteger(L, a, arg, "format");
					var ds = unsignedStr(v, conv == "o" ? 8 : 16, conv == "X");
					if (prec >= 0)
						ds = StringTools.lpad(ds, "0", prec);
					if (alt && v != Int64.ofInt(0))
						ds = (conv == "o" ? "0" : (conv == "x" ? "0x" : "0X")) + ds;
					out = pad(ds, width, left, zero && prec < 0);
				case "e", "E", "f", "F", "g", "G", "a", "A":
					var x = LAux.checkNum(L, a, arg, "format");
					var upper = conv == "E" || conv == "G" || conv == "F" || conv == "A";
					var body:String;
					var finite = true;
					if (x != x) {
						body = upper ? "NAN" : "nan";
						finite = false;
					} else if (x == Math.POSITIVE_INFINITY) {
						body = upper ? "INF" : "inf";
						finite = false;
					} else if (x == Math.NEGATIVE_INFINITY) {
						body = upper ? "-INF" : "-inf";
						finite = false;
					} else
						switch (conv) {
							case "e", "E": body = LNum.fmtE(x, prec < 0 ? 6 : prec, alt, upper);
							case "f", "F": body = LNum.fmtF(x, prec < 0 ? 6 : prec, alt);
							case "g", "G": body = LNum.fmtG(x, prec < 0 ? 6 : prec, alt, upper);
							default: body = LNum.fmtA(x, prec, upper);
						}
					// `+`/` ` only prefix finite bodies; NaN/inf already carry their sign.
					if (body.charAt(0) != "-")
						body = (plus ? "+" : (space ? " " : "")) + body;
					out = pad(body, width, left, zero && finite);
				case "s":
					var s = L.tostring(LAux.checkAny(L, a, arg, "format"));
					if (prec >= 0 && s.length > prec)
						s = s.substr(0, prec);
					out = pad(s, width, left, false);
				case "q":
					var v = LAux.checkAny(L, a, arg, "format");
					if (Std.isOfType(v, String))
						out = quoteStr(v);
					else if (LNum.isInteger(v)) {
						var iv = LNum.toI64(v);
						out = iv == LNum.MININT ? "0x8000000000000000" : Int64.toStr(iv);
					} else if (Std.isOfType(v, LFloat)) {
						var x = (cast v : LFloat).v;
						if (x == Math.POSITIVE_INFINITY)
							out = "1e9999";
						else if (x == Math.NEGATIVE_INFINITY)
							out = "-1e9999";
						else if (x != x)
							out = "(0/0)";
						else
							out = LNum.fmtA(x, -1, false);
					} else if (v == null || Std.isOfType(v, Bool))
						out = L.tostring(v);
					else {
						LAux.argError(L, arg, "format", "value has no literal form");
						out = "";
					}
				default:
					L.error("invalid conversion '" + fmt.substring(start, i) + "' to 'format'");
					out = "";
			}
			b.add(out);
		}
		return [b.toString()];
	}

	/**
	 * Registers the `string` module and installs its metatable so that
	 * `("x"):upper()` and similar method syntax works.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var S = new LTable();
		L.globals.setStr("string", S);
		var meta = new LTable();
		meta.setStr("__index", S);
		L.stringMeta = meta;

		LAux.reg(S, "len", function(a) return [LAux.checkStr(L, a, 0, "len").length]);
		LAux.reg(S, "sub", function(a) {
			var s = LAux.checkStr(L, a, 0, "sub");
			var l = s.length;
			var i = posrelatI(LAux.checkInt(L, a, 1, "sub"), l);
			var j = getEndPos(LAux.optInt(L, a, 2, "sub", -1), l);
			if (i > j)
				return [""];
			return [s.substring(i - 1, j)];
		});
		LAux.reg(S, "upper", function(a) {
			var s = LAux.checkStr(L, a, 0, "upper");
			var b = new StringBuf();
			for (i in 0...s.length) {
				var c = s.charCodeAt(i);
				b.addChar(isLower(c) ? c - 32 : c);
			}
			return [b.toString()];
		});
		LAux.reg(S, "lower", function(a) {
			var s = LAux.checkStr(L, a, 0, "lower");
			var b = new StringBuf();
			for (i in 0...s.length) {
				var c = s.charCodeAt(i);
				b.addChar(isUpper(c) ? c + 32 : c);
			}
			return [b.toString()];
		});
		LAux.reg(S, "reverse", function(a) {
			var s = LAux.checkStr(L, a, 0, "reverse");
			var b = new StringBuf();
			var i = s.length - 1;
			while (i >= 0)
				b.addChar(s.charCodeAt(i--));
			return [b.toString()];
		});
		LAux.reg(S, "rep", function(a) {
			var s = LAux.checkStr(L, a, 0, "rep");
			var n = LAux.checkInt(L, a, 1, "rep");
			var sep = LAux.optStr(L, a, 2, "rep", "");
			if (n <= 0)
				return [""];
			// Guard against overflow before the concatenation.
			if ((s.length + sep.length) * n > 0x7FFFFFFF / 4)
				L.error("resulting string too large");
			var b = new StringBuf();
			for (i in 0...n) {
				b.add(s);
				if (i < n - 1)
					b.add(sep);
			}
			return [b.toString()];
		});
		LAux.reg(S, "byte", function(a) {
			var s = LAux.checkStr(L, a, 0, "byte");
			var l = s.length;
			var pi = posrelatI(LAux.optInt(L, a, 1, "byte", 1), l);
			var pe = getEndPos(LAux.optInt(L, a, 2, "byte", pi), l);
			var r:Array<Dynamic> = [];
			for (i in pi...pe + 1)
				r.push(s.charCodeAt(i - 1));
			return r;
		});
		LAux.reg(S, "char", function(a) {
			var b = new StringBuf();
			for (i in 0...a.length) {
				var c = LAux.checkInt(L, a, i, "char");
				if (c < 0 || c > 255)
					LAux.argError(L, i, "char", "value out of range");
				b.addChar(c);
			}
			return [b.toString()];
		});
		LAux.reg(S, "format", function(a) return format(L, a));
		LAux.reg(S, "find", function(a) return strFindAux(L, a, true));
		LAux.reg(S, "match", function(a) return strFindAux(L, a, false));
		LAux.reg(S, "gmatch", function(a) {
			var s = LAux.checkStr(L, a, 0, "gmatch");
			var p = LAux.checkStr(L, a, 1, "gmatch");
			var init = posrelatI(LAux.optInt(L, a, 2, "gmatch", 1), s.length) - 1;
			var pos = init > s.length ? s.length + 1 : init;
			var last = -1;
			var ms = new MatchState(L, s, p);
			return [
				new NativeFunction("gmatch_iter", function(_) {
					while (pos <= s.length) {
						ms.reprep();
						var e = doMatch(ms, pos, 0);
						// Skip empty matches at the same position to guarantee progress.
						if (e != -1 && e != last) {
							var st = pos;
							pos = last = e;
							return pushCaptures(ms, st, e, true);
						}
						pos++;
					}
					return [null];
				})
			];
		});
		LAux.reg(S, "gsub", function(a) {
			var s = LAux.checkStr(L, a, 0, "gsub");
			var p = LAux.checkStr(L, a, 1, "gsub");
			var repl:Dynamic = a.length > 2 ? a[2] : null;
			var kind:Int;
			if (Std.isOfType(repl, String))
				kind = 0;
			else if (LNum.isNumber(repl)) {
				repl = LNum.numToString(repl);
				kind = 0;
			} else if (Std.isOfType(repl, LTable))
				kind = 1;
			else if (Std.isOfType(repl, LuaFunction))
				kind = 2;
			else
				return LAux.typeError(L, a, 2, "gsub", "string/function/table");
			var maxS = LAux.optInt(L, a, 3, "gsub", s.length + 1);
			var anchor = p.charCodeAt(0) == 94;
			var pi = anchor ? 1 : 0;
			var ms = new MatchState(L, s, p);
			var b = new StringBuf();
			var src = 0;
			var last = -1;
			var n = 0;
			while (n < maxS) {
				ms.reprep();
				var e = doMatch(ms, src, pi);
				if (e != -1 && e != last) {
					n++;
					addValue(ms, b, src, e, repl, kind);
					src = last = e;
				} else if (src < s.length)
					b.addChar(s.charCodeAt(src++));
				else
					break;
				if (anchor)
					break;
			}
			if (src < s.length)
				b.add(s.substr(src));
			return [b.toString(), n];
		});
		LStrPack.open(L, S);
	}
}
