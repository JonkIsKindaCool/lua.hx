package luahx.vm;

import haxe.io.Bytes;

/**
 * lstring.c — Lua strings are byte strings.
 *
 * In this implementation they are represented as Haxe `String`s where each
 * character holds a single byte (`0..255`). This lets the VM use plain Haxe
 * strings while preserving Lua's byte-oriented semantics.
 */
class LStr {
	/**
	 * Converts a Haxe Unicode `String` into a byte-per-char Lua string (UTF-8 encoded).
	 *
	 * @param s Haxe Unicode string.
	 * @returns The UTF-8 bytes packed as a Haxe string (each char in `0..255`).
	 */
	public static function fromHaxe(s:String):String {
		var ascii = true;
		for (i in 0...s.length)
			if (s.charCodeAt(i) > 127) {
				ascii = false;
				break;
			}
		if (ascii)
			return s;
		var b = Bytes.ofString(s);
		var sb = new StringBuf();
		for (i in 0...b.length)
			sb.addChar(b.get(i));
		return sb.toString();
	}

	/**
	 * Decodes a byte-per-char Lua string as UTF-8 into a Haxe Unicode `String`.
	 *
	 * @param s Lua string (each char in `0..255`).
	 * @returns The decoded Unicode string.
	 */
	public static function toHaxe(s:String):String {
		var ascii = true;
		for (i in 0...s.length)
			if (s.charCodeAt(i) > 127) {
				ascii = false;
				break;
			}
		if (ascii)
			return s;
		var b = Bytes.alloc(s.length);
		for (i in 0...s.length)
			b.set(i, s.charCodeAt(i) & 0xFF);
		return b.toString();
	}

	/**
	 * Encodes a Unicode code point as a byte-per-char UTF-8 Lua string,
	 * matching Lua's `utf8.char` behavior (supports code points up to 2^31).
	 *
	 * @param x Unicode code point.
	 * @returns Byte-per-char string containing the UTF-8 encoding of `x`.
	 */
	public static function utf8Encode(x:Int):String {
		if (x < 0x80)
			return String.fromCharCode(x);
		var buf:Array<Int> = [];
		var mfb = 0x3f;
		do {
			buf.unshift(0x80 | (x & 0x3f));
			x = x >> 6;
			mfb >>= 1;
		} while (x > mfb);
		buf.unshift(((~mfb << 1) & 0xFF) | x);
		var sb = new StringBuf();
		for (c in buf)
			sb.addChar(c);
		return sb.toString();
	}

	/**
	 * Packs a byte-per-char Lua string into a `Bytes` buffer.
	 *
	 * @param s Lua string (each char in `0..255`).
	 * @returns The bytes.
	 */
	public static function toBytes(s:String):Bytes {
		var b = Bytes.alloc(s.length);
		for (i in 0...s.length)
			b.set(i, s.charCodeAt(i) & 0xFF);
		return b;
	}

	/**
	 * Unpacks a `Bytes` buffer into a byte-per-char Lua string.
	 *
	 * @param b Source bytes.
	 * @returns The Lua string.
	 */
	public static function ofBytes(b:Bytes):String {
		var sb = new StringBuf();
		for (i in 0...b.length)
			sb.addChar(b.get(i));
		return sb.toString();
	}
}
