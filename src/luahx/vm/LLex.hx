package luahx.vm;

import luahx.vm.LObject;

/**
 * llex.c — Lexical analyzer for Lua 5.5.
 *
 * Converts a source string into a stream of tokens: keywords, names,
 * numeral and string literals, and single-character or multi-character
 * operators. Numeral literals are already parsed into their Lua
 * representation (via {@link LNum.str2number}) and strings are decoded
 * into byte-per-char form (via {@link LStr.utf8Encode} for `\u{...}`).
 */
class LLex {
	public static inline var TK_AND = 257;
	public static inline var TK_BREAK = 258;
	public static inline var TK_DO = 259;
	public static inline var TK_ELSE = 260;
	public static inline var TK_ELSEIF = 261;
	public static inline var TK_END = 262;
	public static inline var TK_FALSE = 263;
	public static inline var TK_FOR = 264;
	public static inline var TK_FUNCTION = 265;
	public static inline var TK_GLOBAL = 266;
	public static inline var TK_GOTO = 267;
	public static inline var TK_IF = 268;
	public static inline var TK_IN = 269;
	public static inline var TK_LOCAL = 270;
	public static inline var TK_NIL = 271;
	public static inline var TK_NOT = 272;
	public static inline var TK_OR = 273;
	public static inline var TK_REPEAT = 274;
	public static inline var TK_RETURN = 275;
	public static inline var TK_THEN = 276;
	public static inline var TK_TRUE = 277;
	public static inline var TK_UNTIL = 278;
	public static inline var TK_WHILE = 279;
	public static inline var TK_IDIV = 280;
	public static inline var TK_CONCAT = 281;
	public static inline var TK_DOTS = 282;
	public static inline var TK_EQ = 283;
	public static inline var TK_GE = 284;
	public static inline var TK_LE = 285;
	public static inline var TK_NE = 286;
	public static inline var TK_SHL = 287;
	public static inline var TK_SHR = 288;
	public static inline var TK_DBCOLON = 289;
	public static inline var TK_EOS = 290;
	public static inline var TK_FLT = 291;
	public static inline var TK_INT = 292;
	public static inline var TK_NAME = 293;
	public static inline var TK_STRING = 294;
	static inline var TK_NONE = -1;

	/**
	 * Token names, indexed by `token - 257`. The first 23 entries are the
	 * keywords (in `TK_*` order) so the reserved-word table can be built
	 * from this array without duplication.
	 */
	static var tokenNames:Array<String> = [
		"and",
		"break",
		"do",
		"else",
		"elseif",
		"end",
		"false",
		"for",
		"function",
		"global",
		"goto",
		"if",
		"in",
		"local",
		"nil",
		"not",
		"or",
		"repeat",
		"return",
		"then",
		"true",
		"until",
		"while",
		"//",
		"..",
		"...",
		"==",
		">=",
		"<=",
		"~=",
		"<<",
		">>",
		"::",
		"<eof>",
		"<number>",
		"<integer>",
		"<name>",
		"<string>"
	];

	/** Keyword -> token code map, built lazily on first lexer construction. */
	static var reserved:Map<String, Int> = null;

	public var src:String;
	public var chunk:String;
	public var line:Int = 1;
	public var lastLine:Int = 1;
	public var tk:Int = TK_NONE;
	public var sv:String = null;
	public var nv:Dynamic = null;

	var ltk:Int = TK_NONE;
	var lsv:String = null;
	var lnv:Dynamic = null;
	var pos:Int = 0;
	var tokStart:Int = 0;

	/**
	 * Creates a lexer over `src`.
	 *
	 * A leading `#` is treated as a shebang line and skipped up to (but not
	 * including) the first newline.
	 *
	 * @param src Source code (byte-per-char string).
	 * @param chunk Chunk name used in error messages.
	 */
	public function new(src:String, chunk:String) {
		if (reserved == null) {
			reserved = new Map();
			for (i in 0...23)
				reserved.set(tokenNames[i], 257 + i);
		}
		this.src = src;
		this.chunk = chunk;
		if (src.charCodeAt(0) == 35) { // `#`: skip a shebang line.
			while (pos < src.length && src.charCodeAt(pos) != 10)
				pos++;
		}
	}

	/**
	 * Returns a textual representation of a token code, without quotes for
	 * symbolic single-character tokens.
	 *
	 * @param t Token code.
	 * @returns The textual form.
	 */
	public static function tokenText(t:Int):String {
		if (t < 257)
			return t >= 32 && t < 127 ? String.fromCharCode(t) : "<\\" + t + ">";
		return tokenNames[t - 257];
	}

	/**
	 * Raises a lexical error at the current line, optionally pointing at
	 * `near`.
	 *
	 * @param msg Error message.
	 * @param near Optional token text to append after `" near "`.
	 */
	public function error(msg:String, ?near:String):Dynamic {
		var m = chunk + ":" + line + ": " + msg;
		if (near != null)
			m += " near " + near;
		throw new LuaError(m);
	}

	/**
	 * Raises a lexical error at the current line pointing at the current
	 * token.
	 *
	 * @param msg Error message.
	 */
	public function errorToken(msg:String):Dynamic {
		return error(msg, tokenToString(tk));
	}

	/**
	 * Equivalent to Lua's `luaX_token2str`: quotes single-character and
	 * operator tokens, but leaves `<eof>`, `<number>`, `<string>`, etc.
	 * unquoted.
	 *
	 * @param t Token code.
	 * @returns The textual form.
	 */
	public static function tok2str(t:Int):String {
		if (t >= TK_EOS)
			return tokenNames[t - 257];
		return "'" + tokenText(t) + "'";
	}

	/**
	 * Returns a representation of token `t` suitable for `" near ... "`
	 * messages. For names, strings and numerals it uses the original source
	 * text.
	 *
	 * @param t Token code.
	 * @returns The textual form.
	 */
	public function tokenToString(t:Int):String {
		switch (t) {
			case TK_NAME, TK_STRING, TK_FLT, TK_INT:
				return "'" + (t == TK_NAME || t == TK_STRING ? sv : src.substring(tokStart, pos)) + "'";
			default:
				return tok2str(t);
		}
	}

	/**
	 * Advances to the next token, either by consuming a previously scanned
	 * lookahead token or by scanning a fresh one.
	 */
	public function next():Void {
		lastLine = line;
		if (ltk != TK_NONE) {
			tk = ltk;
			sv = lsv;
			nv = lnv;
			ltk = TK_NONE;
		} else
			tk = scan();
	}

	/**
	 * Returns the token that would follow the current one without consuming
	 * the current token. The lookahead is buffered so a subsequent
	 * {@link next} advances by exactly one token.
	 *
	 * @returns The lookahead token code.
	 */
	public function lookahead():Int {
		var st = tk;
		var ss = sv;
		var sn = nv;
		ltk = scan();
		lsv = sv;
		lnv = nv;
		tk = st;
		sv = ss;
		nv = sn;
		return ltk;
	}

	inline function cur():Int
		return pos < src.length ? src.charCodeAt(pos) : -1;

	inline function at(i:Int):Int
		return pos + i < src.length ? src.charCodeAt(pos + i) : -1;

	static inline function isAlpha(c:Int):Bool
		return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95;

	static inline function isDigit(c:Int):Bool
		return c >= 48 && c <= 57;

	static inline function isHex(c:Int):Bool
		return isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);

	/**
	 * Advances past a newline sequence (`\n`, `\r`, `\r\n` or `\n\r`) and
	 * increments the line counter.
	 */
	function incLine():Void {
		var old = cur();
		pos++;
		var c = cur();
		// Consume the second half of a CRLF / LFCR pair as part of the same newline.
		if ((c == 10 || c == 13) && c != old)
			pos++;
		line++;
	}

	/**
	 * Reads and returns the next token, skipping whitespace and comments.
	 * String/number literals set `sv`/`nv`; keyword/operator tokens are
	 * returned as their numeric codes.
	 *
	 * @returns The token code.
	 */
	function scan():Int {
		while (true) {
			tokStart = pos;
			var c = cur();
			switch (c) {
				case -1:
					return TK_EOS;
				case 10, 13:
					incLine();
				case 32, 12, 9, 11:
					pos++;
				case 45: // `-`
					if (at(1) != 45) {
						pos++;
						return 45;
					}
					pos += 2;
					// `--[==[ ... ]==]` long comment or a one-line `--` comment.
					if (cur() == 91) {
						var sep = skipSep();
						if (sep >= 2) {
							readLong(sep, true);
							continue;
						}
					}
					while (cur() != -1 && cur() != 10 && cur() != 13)
						pos++;
				case 91: // `[`
					var sep = skipSep();
					if (sep >= 2) {
						sv = readLong(sep, false);
						return TK_STRING;
					} else if (sep == 0)
						error("invalid long string delimiter", "'['");
					return 91;
				case 61: // `=`
					pos++;
					if (cur() == 61) {
						pos++;
						return TK_EQ;
					}
					return 61;
				case 60: // `<`
					pos++;
					if (cur() == 61) {
						pos++;
						return TK_LE;
					}
					if (cur() == 60) {
						pos++;
						return TK_SHL;
					}
					return 60;
				case 62: // `>`
					pos++;
					if (cur() == 61) {
						pos++;
						return TK_GE;
					}
					if (cur() == 62) {
						pos++;
						return TK_SHR;
					}
					return 62;
				case 47: // `/`
					pos++;
					if (cur() == 47) {
						pos++;
						return TK_IDIV;
					}
					return 47;
				case 126: // `~`
					pos++;
					if (cur() == 61) {
						pos++;
						return TK_NE;
					}
					return 126;
				case 58: // `:`
					pos++;
					if (cur() == 58) {
						pos++;
						return TK_DBCOLON;
					}
					return 58;
				case 34, 39:
					return readString(c);
				case 46: // `.`
					if (at(1) == 46) {
						if (at(2) == 46) {
							pos += 3;
							return TK_DOTS;
						}
						pos += 2;
						return TK_CONCAT;
					}
					if (!isDigit(at(1))) {
						pos++;
						return 46;
					}
					return readNumeral();
				default:
					if (isDigit(c))
						return readNumeral();
					if (isAlpha(c)) {
						var s = pos;
						while (isAlpha(cur()) || isDigit(cur()))
							pos++;
						var w = src.substring(s, pos);
						var r = reserved.get(w);
						if (r != null)
							return r;
						sv = w;
						return TK_NAME;
					}
					pos++;
					return c;
			}
		}
	}

	/**
	 * Inspects a `[` or `]` at the current position and counts the `=`
	 * signs between the brackets.
	 *
	 * @returns `N + 2` if the token is `[==...==]` (with `N` `=` signs and a
	 *          matching closing bracket); `1` if it is a bare `[` or `]`
	 *          (consumed); `0` if the opening delimiter is malformed.
	 */
	function skipSep():Int {
		var s = cur();
		var count = 0;
		var i = 1;
		while (at(i) == 61) {
			i++;
			count++;
		}
		if (at(i) == s) {
			pos += i + 1;
			return count + 2;
		}
		if (count == 0) {
			pos++;
			return 1;
		}
		pos += i;
		return 0;
	}

	/**
	 * Consumes a long bracket string (or comment) whose level has already
	 * been determined by {@link skipSep}.
	 *
	 * @param sep Separator level as returned by {@link skipSep} (>= 2).
	 * @param isComment Whether the caller is consuming a long comment
	 *                  (affects the error message only).
	 * @returns The decoded string body.
	 */
	function readLong(sep:Int, isComment:Bool):String {
		var startLine = line;
		if (cur() == 10 || cur() == 13)
			incLine();
		var sb = new StringBuf();
		while (true) {
			var c = cur();
			if (c == -1) {
				error("unfinished long " + (isComment ? "comment" : "string") + " (starting at line " + startLine + ")", "<eof>");
			} else if (c == 93) { // `]`
				var i = 1;
				var cnt = 0;
				while (at(i) == 61) {
					i++;
					cnt++;
				}
				if (at(i) == 93 && cnt + 2 == sep) {
					pos += i + 1;
					return sb.toString();
				}
				sb.addChar(93);
				pos++;
			} else if (c == 10 || c == 13) {
				// Normalize every newline form to `\n`, as Lua does.
				sb.addChar(10);
				incLine();
			} else {
				sb.addChar(c);
				pos++;
			}
		}
	}

	/**
	 * Reads a numeral literal (decimal or hexadecimal, optionally with a
	 * fraction and exponent) and stores the parsed value in `nv`.
	 *
	 * @returns `TK_FLT` for float literals and `TK_INT` for integer ones.
	 */
	function readNumeral():Int {
		var s = pos;
		var expo1 = 101; // `e`
		var expo2 = 69; // `E`
		var first = cur();
		pos++;
		if (first == 48 && (cur() == 120 || cur() == 88)) { // `0x` / `0X`
			expo1 = 112; // `p`
			expo2 = 80; // `P`
			pos++;
		}
		while (true) {
			var c = cur();
			if (c == expo1 || c == expo2) {
				pos++;
				if (cur() == 43 || cur() == 45)
					pos++;
			} else if (isHex(c) || c == 46)
				pos++;
			else
				break;
		}
		// Consume one trailing alphabetic character so the error message
		// shows the whole malformed numeral (matching Lua).
		if (isAlpha(cur()))
			pos++;
		var text = src.substring(s, pos);
		var v = LNum.str2number(text);
		if (v == null)
			error("malformed number", "'" + text + "'");
		nv = v;
		return Std.isOfType(v, LFloat) ? TK_FLT : TK_INT;
	}

	/**
	 * Raises an error from inside an escape sequence, pointing at the
	 * escape text starting at `from`.
	 *
	 * @param msg Error message.
	 * @param from Start index of the offending escape sequence.
	 */
	function escError(msg:String, from:Int):Dynamic {
		var e = pos < src.length ? pos + 1 : pos;
		return error(msg, "'" + src.substring(from, e > src.length ? src.length : e) + "'");
	}

	/**
	 * Reads a short quoted string (single or double quotes) handling every
	 * Lua escape sequence (`\a \b \f \n \r \t \v \\ \" \' \ddd \xXX \z
	 * \u{XXX}` and escaped newlines).
	 *
	 * @param del Closing delimiter (`'` or `"`).
	 * @returns `TK_STRING` with the decoded string stored in `sv`.
	 */
	function readString(del:Int):Int {
		var sb = new StringBuf();
		var s0 = pos;
		pos++;
		while (cur() != del) {
			var c = cur();
			switch (c) {
				case -1:
					error("unfinished string", "<eof>");
				case 10, 13:
					error("unfinished string", "'" + src.substring(s0, pos) + "'");
				case 92: // `\`
					var es = pos;
					pos++;
					var e = cur();
					switch (e) {
						case 97:
							sb.addChar(7);
							pos++; // \a
						case 98:
							sb.addChar(8);
							pos++; // \b
						case 102:
							sb.addChar(12);
							pos++; // \f
						case 110:
							sb.addChar(10);
							pos++; // \n
						case 114:
							sb.addChar(13);
							pos++; // \r
						case 116:
							sb.addChar(9);
							pos++; // \t
						case 118:
							sb.addChar(11);
							pos++; // \v
						case 92:
							sb.addChar(92);
							pos++; // \\
						case 34:
							sb.addChar(34);
							pos++; // \"
						case 39:
							sb.addChar(39);
							pos++; // \'
						case 10, 13: // escaped newline
							incLine();
							sb.addChar(10);
						case 120: // \xXX
							pos++;
							var v = 0;
							for (i in 0...2) {
								var h = cur();
								if (!isHex(h))
									escError("hexadecimal digit expected", es);
								v = v * 16 + (isDigit(h) ? h - 48 : (h | 32) - 87);
								pos++;
							}
							sb.addChar(v);
						case 122: // \z: skip following whitespace
							pos++;
							while (cur() != -1 && (cur() == 32 || (cur() >= 9 && cur() <= 13))) {
								if (cur() == 10 || cur() == 13)
									incLine();
								else
									pos++;
							}
						case 117: // \u{XXX}: UTF-8 code point
							pos++;
							if (cur() != 123)
								escError("missing '{' in \\u{xxxx}", es);
							pos++;
							var v = 0;
							if (!isHex(cur()))
								escError("hexadecimal digit expected", es);
							while (isHex(cur())) {
								var h = cur();
								v = v * 16 + (isDigit(h) ? h - 48 : (h | 32) - 87);
								if (v > 0x7FFFFFFF)
									escError("UTF-8 value too large", es);
								pos++;
							}
							if (cur() != 125)
								escError("missing '}' in \\u{xxxx}", es);
							pos++;
							sb.add(LStr.utf8Encode(v));
						default:
							if (isDigit(e)) { // \ddd: up to three decimal digits
								var v = 0;
								var i = 0;
								while (i < 3 && isDigit(cur())) {
									v = v * 10 + (cur() - 48);
									pos++;
									i++;
								}
								if (v > 255)
									escError("decimal escape too large", es);
								sb.addChar(v);
							} else escError("invalid escape sequence", es);
					}
				default:
					sb.addChar(c);
					pos++;
			}
		}
		pos++;
		sv = sb.toString();
		return TK_STRING;
	}
}
