package luahx.lib;

import haxe.Int64;
import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * `string.pack` / `string.unpack` / `string.packsize` implementation.
 *
 * Supports the standard Lua 5.4/5.5 format options but not the alignment
 * (`!n`) or padding-inheritance (`X`) options.
 */
class LStrPack {
	static function isDigit(c:Int):Bool
		return c >= 48 && c <= 57;

	/**
	 * Parses a format string into a list of typed entries.
	 *
	 * Each entry has:
	 * - `k`: an abstract kind (`"<"`, `">"`, `"i"`, `"I"`, `"f"`, `"d"`, `"s"`, `"z"`, `"x"`, `"c"`).
	 *   The `<`/`>` entries only update the current endianness.
	 * - `size`: number of bytes the option consumes (0 for endianness markers).
	 *
	 * @param L Lua state (used to raise format errors).
	 * @param fmt Format string.
	 * @param fname Function name (`"pack"`, `"unpack"`, `"packsize"`) for error messages.
	 * @returns The parsed entries.
	 */
	static function parse(L:LuaState, fmt:String, fname:String):Array<{k:String, size:Int}> {
		var out = [];
		var i = 0;
		var little = true;
		function num(def:Int):Int {
			if (i < fmt.length && isDigit(fmt.charCodeAt(i))) {
				var v = 0;
				while (i < fmt.length && isDigit(fmt.charCodeAt(i)))
					v = v * 10 + fmt.charCodeAt(i++) - 48;
				return v;
			}
			return def;
		}
		while (i < fmt.length) {
			var c = fmt.charAt(i++);
			switch (c) {
				case "<":
					little = true;
					out.push({k: "<", size: 0});
				case ">":
					little = false;
					out.push({k: ">", size: 0});
				case "=":
					little = true;
					out.push({k: "<", size: 0});
				case " ":
				case "b":
					out.push({k: "i", size: 1});
				case "B":
					out.push({k: "I", size: 1});
				case "h":
					out.push({k: "i", size: 2});
				case "H":
					out.push({k: "I", size: 2});
				case "i", "I":
					var n = num(4);
					if (n < 1 || n > 16)
						L.error("integral size (" + n + ") out of limits [1,16]");
					out.push({k: c, size: n});
				case "l", "j":
					out.push({k: "i", size: 8});
				case "L", "J", "T":
					out.push({k: "I", size: 8});
				case "f":
					out.push({k: "f", size: 4});
				case "d", "n":
					out.push({k: "d", size: 8});
				case "s":
					out.push({k: "s", size: num(8)});
				case "z":
					out.push({k: "z", size: 0});
				case "x":
					out.push({k: "x", size: 1});
				case "c":
					var n = num(-1);
					if (n < 0)
						L.error("missing size for format option 'c'");
					out.push({k: "c", size: n});
				default:
					L.error("invalid format option '" + c + "'");
			}
		}
		return out;
	}

	/**
	 * Appends `v` to `b` as a little- or big-endian integer of `size` bytes.
	 *
	 * Sizes larger than 8 bytes are sign-extended with `0xFF` / `0x00` bytes
	 * so the value keeps its integer semantics when read back.
	 *
	 * @param b Output buffer.
	 * @param v Value to pack.
	 * @param size Number of bytes to write (`1..16`).
	 * @param little `true` for little-endian, `false` for big-endian.
	 */
	static function packInt(b:StringBuf, v:Int64, size:Int, little:Bool):Void {
		var bytes:Array<Int> = [];
		var neg = v < Int64.ofInt(0);
		for (i in 0...size) {
			if (i < 8)
				bytes.push(((i < 4 ? v.low >>> (i * 8) : v.high >>> ((i - 4) * 8)) & 0xFF));
			else
				bytes.push(neg ? 0xFF : 0);
		}
		if (!little)
			bytes.reverse();
		for (x in bytes)
			b.addChar(x);
	}

	/**
	 * Reads `size` bytes at `s[pos]` as an integer of the given endianness.
	 *
	 * @param s Source string.
	 * @param pos Start offset.
	 * @param size Number of bytes to read (`1..16`).
	 * @param little `true` for little-endian, `false` for big-endian.
	 * @param signed Whether the result should be sign-extended.
	 * @returns The decoded 64-bit integer.
	 */
	static function unpackInt(s:String, pos:Int, size:Int, little:Bool, signed:Bool):Int64 {
		var v = Int64.ofInt(0);
		var n = size > 8 ? 8 : size;
		for (i in 0...n) {
			var idx = little ? pos + n - 1 - i : pos + i;
			v = (v << 8) | Int64.ofInt(s.charCodeAt(idx));
		}
		if (signed && size < 8) {
			var shift = 64 - size * 8;
			v = (v << shift) >> shift;
		}
		return v;
	}

	/**
	 * Registers `string.pack`, `string.unpack` and `string.packsize` on the
	 * given `string` module table.
	 *
	 * @param L Target Lua state.
	 * @param S The `string` module table to add the functions to.
	 */
	public static function open(L:LuaState, S:LTable):Void {
		LAux.reg(S, "pack", function(a) {
			var fmt = LAux.checkStr(L, a, 0, "pack");
			var b = new StringBuf();
			var little = true;
			var arg = 0;
			for (e in parse(L, fmt, "pack")) {
				switch (e.k) {
					case "<":
						little = true;
					case ">":
						little = false;
					case "i", "I":
						arg++;
						var v = LAux.checkInteger(L, a, arg, "pack");
						// Range-check only when the target width is smaller than 64 bits.
						if (e.size < 8) {
							var lim = Int64.ofInt(1) << (e.size * 8 - (e.k == "i" ? 1 : 0));
							if (e.k == "i" ? (v < -lim || v >= lim) : (Int64.ucompare(v, lim) >= 0))
								LAux.argError(L, arg, "pack", (e.k == "i" ? "integer" : "unsigned") + " overflow");
						}
						packInt(b, v, e.size, little);
					case "f":
						arg++;
						var x = LAux.checkNum(L, a, arg, "pack");
						packInt(b, LNum.encodeIEEE(x, 8, 23), 4, little);
					case "d":
						arg++;
						var x = LAux.checkNum(L, a, arg, "pack");
						packInt(b, LNum.encodeIEEE(x, 11, 52), 8, little);
					case "s":
						arg++;
						var s = LAux.checkStr(L, a, arg, "pack");
						packInt(b, Int64.ofInt(s.length), e.size, little);
						b.add(s);
					case "z":
						arg++;
						var s = LAux.checkStr(L, a, arg, "pack");
						if (s.indexOf(String.fromCharCode(0)) >= 0)
							LAux.argError(L, arg, "pack", "string contains zeros");
						b.add(s);
						b.addChar(0);
					case "x":
						b.addChar(0);
					case "c":
						arg++;
						var s = LAux.checkStr(L, a, arg, "pack");
						if (s.length > e.size)
							LAux.argError(L, arg, "pack", "string longer than given size");
						b.add(s);
						for (i in s.length...e.size)
							b.addChar(0);
				}
			}
			return [b.toString()];
		});
		LAux.reg(S, "packsize", function(a) {
			var total = 0;
			for (e in parse(L, LAux.checkStr(L, a, 0, "packsize"), "packsize")) {
				// `s` and `z` have data-dependent sizes, so the total is not constant.
				if (e.k == "s" || e.k == "z")
					LAux.argError(L, 0, "packsize", "variable-length format");
				if (e.k != "<" && e.k != ">")
					total += e.size;
			}
			return [total];
		});
		LAux.reg(S, "unpack", function(a) {
			var fmt = LAux.checkStr(L, a, 0, "unpack");
			var s = LAux.checkStr(L, a, 1, "unpack");
			var pos = LAux.optInt(L, a, 2, "unpack", 1);
			if (pos < 0)
				pos = s.length + pos + 1;
			pos--;
			if (pos < 0 || pos > s.length)
				LAux.argError(L, 2, "unpack", "initial position out of string");
			var little = true;
			var r:Array<Dynamic> = [];
			function need(n:Int)
				if (pos + n > s.length)
					LAux.argError(L, 1, "unpack", "data string too short");
			for (e in parse(L, fmt, "unpack")) {
				switch (e.k) {
					case "<":
						little = true;
					case ">":
						little = false;
					case "i", "I":
						need(e.size);
						r.push(LNum.mkInt(unpackInt(s, pos, e.size, little, e.k == "i")));
						pos += e.size;
					case "f":
						need(4);
						r.push(new LFloat(LNum.decodeIEEE(unpackInt(s, pos, 4, little, false), 8, 23)));
						pos += 4;
					case "d":
						need(8);
						r.push(new LFloat(LNum.decodeIEEE(unpackInt(s, pos, 8, little, false), 11, 52)));
						pos += 8;
					case "s":
						need(e.size);
						var len = LAux.clamp(unpackInt(s, pos, e.size, little, false));
						pos += e.size;
						need(len);
						r.push(s.substr(pos, len));
						pos += len;
					case "z":
						var z = s.indexOf(String.fromCharCode(0), pos);
						if (z < 0)
							LAux.argError(L, 1, "unpack", "unfinished string for format 'z'");
						r.push(s.substring(pos, z));
						pos = z + 1;
					case "x":
						need(1);
						pos++;
					case "c":
						need(e.size);
						r.push(s.substr(pos, e.size));
						pos += e.size;
				}
			}
			// Trailing value: the position after the last decoded byte (1-based).
			r.push(pos + 1);
			return r;
		});
	}
}
