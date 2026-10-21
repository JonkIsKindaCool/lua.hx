package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * loslib.c — Implementation of the `os` library.
 *
 * Some functions (`os.getenv`, `os.exit`, `os.remove`, `os.rename`) are
 * available only on `sys` targets; on other targets they either return
 * `nil`/error tuples or raise a runtime error.
 */
class LOsLib {
	/** Reference timestamp used by `os.clock` to report elapsed CPU/wall time since load. */
	static var startTime:Float = haxe.Timer.stamp();
	static final DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
	static final MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

	/**
	 * Zero-pads `n` to two digits.
	 *
	 * @param n Value in the range `0..99` (used for `%d`-like conversions).
	 * @returns The padded string.
	 */
	static function two(n:Int):String
		return n < 10 ? "0" + n : Std.string(n);

	/**
	 * Computes the 1-based day-of-year for the given date.
	 *
	 * @param y Full year.
	 * @param m Zero-based month (`0..11`).
	 * @param d Day of month (`1..31`).
	 * @returns Day of year in `1..366`.
	 */
	static function yday(y:Int, m:Int, d:Int):Int {
		var cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
		var leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
		return cum[m] + d + (leap && m > 1 ? 1 : 0);
	}

	/**
	 * Implements `os.date`'s strftime subset.
	 *
	 * Supports: `a A b B c d D e F h H I j m M n p S t T X x y Y z Z %`.
	 * Conversion `Z` yields `"UTC"` when `utc` is `true` and `""` otherwise
	 * (the host time zone name is not modeled).
	 *
	 * @param L Lua state (for error reporting).
	 * @param f Format string (without the leading `!`).
	 * @param d Date to format.
	 * @param utc Whether to use UTC fields instead of local time.
	 * @returns The formatted string.
	 */
	static function strftime(L:LuaState, f:String, d:Date, utc:Bool):String {
		var Y = utc ? d.getUTCFullYear() : d.getFullYear();
		var M = utc ? d.getUTCMonth() : d.getMonth();
		var D = utc ? d.getUTCDate() : d.getDate();
		var h = utc ? d.getUTCHours() : d.getHours();
		var mi = utc ? d.getUTCMinutes() : d.getMinutes();
		var s = utc ? d.getUTCSeconds() : d.getSeconds();
		var w = utc ? d.getUTCDay() : d.getDay();
		var b = new StringBuf();
		var i = 0;
		while (i < f.length) {
			var c = f.charAt(i++);
			if (c != "%") {
				b.add(c);
				continue;
			}
			if (i >= f.length) L.error("bad argument #1 to 'date' (invalid conversion specifier '%')");
			var k = f.charAt(i++);
			switch (k) {
				case "a": b.add(DAYS[w].substr(0, 3));
				case "A": b.add(DAYS[w]);
				case "b", "h": b.add(MONTHS[M].substr(0, 3));
				case "B": b.add(MONTHS[M]);
				case "c": b.add(DAYS[w].substr(0, 3) + " " + MONTHS[M].substr(0, 3) + " " + StringTools.lpad(Std.string(D), " ", 2) + " " + two(h) + ":" + two(mi) + ":" + two(s) + " " + Y);
				case "d": b.add(two(D));
				case "e": b.add(StringTools.lpad(Std.string(D), " ", 2));
				case "D": b.add(two(M + 1) + "/" + two(D) + "/" + two(Y % 100));
				case "F": b.add(Y + "-" + two(M + 1) + "-" + two(D));
				case "H": b.add(two(h));
				case "I": b.add(two(h % 12 == 0 ? 12 : h % 12));
				case "j": b.add(StringTools.lpad(Std.string(yday(Y, M, D)), "0", 3));
				case "m": b.add(two(M + 1));
				case "M": b.add(two(mi));
				case "n": b.add("\n");
				case "p": b.add(h < 12 ? "AM" : "PM");
				case "S": b.add(two(s));
				case "t": b.add("\t");
				case "T", "X": b.add(two(h) + ":" + two(mi) + ":" + two(s));
				case "x": b.add(two(M + 1) + "/" + two(D) + "/" + two(Y % 100));
				case "w": b.add(Std.string(w));
				case "y": b.add(two(Y % 100));
				case "Y": b.add(Std.string(Y));
				case "Z": b.add(utc ? "UTC" : "");
				case "z": b.add("+0000");
				case "%": b.add("%");
				default: L.error("bad argument #1 to 'date' (invalid conversion specifier '%" + k + "')");
			}
		}
		return b.toString();
	}

	/**
	 * Registers the `os` module and its functions (`time`, `clock`, `difftime`,
	 * `date`, `getenv`, `exit`, `remove`, `rename`, `tmpname`, `setlocale`)
	 * into the given state's globals.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var O = new LTable();
		L.globals.setStr("os", O);
		LAux.reg(O, "time", function(a) {
			if (a.length == 0 || a[0] == null) return [LNum.mkIntF(LNum.ffloor(Date.now().getTime() / 1000))];
			var t = LAux.checkTable(L, a, 0, "time");
			function fld(n:String, def:Int):Int {
				var v = t.getStr(n);
				if (v == null) {
					if (def < 0) L.error("field '" + n + "' missing in date table");
					return def;
				}
				var i = LNum.toInteger(v);
				if (i == null) L.error("field '" + n + "' is not an integer");
				return LAux.clamp(LNum.toI64(i));
			}
			// `month` is 1-based in Lua; Haxe's Date constructor expects 0-based.
			var d = new Date(fld("year", -1), fld("month", -1) - 1, fld("day", -1), fld("hour", 12), fld("min", 0), fld("sec", 0));
			return [LNum.mkIntF(LNum.ffloor(d.getTime() / 1000))];
		});
		LAux.reg(O, "clock", function(a) return [new LFloat(haxe.Timer.stamp() - startTime)]);
		LAux.reg(O, "difftime", function(a) return [new LFloat(LAux.checkNum(L, a, 0, "difftime") - LAux.optNum(L, a, 1, "difftime", 0))]);
		LAux.reg(O, "date", function(a) {
			var f = LAux.optStr(L, a, 0, "date", "%c");
			var t = a.length > 1 && a[1] != null ? LAux.checkNum(L, a, 1, "date") : Date.now().getTime() / 1000;
			var utc = false;
			// A leading `!` requests UTC fields.
			if (f.charAt(0) == "!") {
				utc = true;
				f = f.substr(1);
			}
			var d = Date.fromTime(t * 1000);
			if (f.substr(0, 2) == "*t") {
				var r = new LTable();
				var Y = utc ? d.getUTCFullYear() : d.getFullYear();
				var M = utc ? d.getUTCMonth() : d.getMonth();
				var D = utc ? d.getUTCDate() : d.getDate();
				r.setStr("year", Y);
				r.setStr("month", M + 1);
				r.setStr("day", D);
				r.setStr("hour", utc ? d.getUTCHours() : d.getHours());
				r.setStr("min", utc ? d.getUTCMinutes() : d.getMinutes());
				r.setStr("sec", utc ? d.getUTCSeconds() : d.getSeconds());
				// `wday` is 1-based in Lua (Sunday = 1), while Haxe returns 0..6.
				r.setStr("wday", (utc ? d.getUTCDay() : d.getDay()) + 1);
				r.setStr("yday", yday(Y, M, D));
				r.setStr("isdst", false);
				return [r];
			}
			return [strftime(L, f, d, utc)];
		});
		LAux.reg(O, "getenv", function(a) {
			var n = LAux.checkStr(L, a, 0, "getenv");
			#if sys
			return [Sys.getEnv(n)];
			#else
			return [null];
			#end
		});
		LAux.reg(O, "exit", function(a) {
			var code = 0;
			// Lua also accepts a boolean: `true` -> 0, `false` -> 1.
			if (a.length > 0 && a[0] != null) code = Std.isOfType(a[0], Bool) ? ((cast a[0] : Bool) ? 0 : 1) : LAux.checkInt(L, a, 0, "exit");
			#if sys
			Sys.exit(code);
			#end
			return L.error("os.exit is not supported on this target");
		});
		LAux.reg(O, "remove", function(a) {
			var n = LAux.checkStr(L, a, 0, "remove");
			#if sys
			try {
				if (sys.FileSystem.isDirectory(n)) sys.FileSystem.deleteDirectory(n);
				else sys.FileSystem.deleteFile(n);
				return [true];
			} catch (e:Dynamic) {
				return [null, n + ": No such file or directory", 2];
			}
			#else
			return [null, "os.remove not supported on this target", 1];
			#end
		});
		LAux.reg(O, "rename", function(a) {
			var n = LAux.checkStr(L, a, 0, "rename");
			var m = LAux.checkStr(L, a, 1, "rename");
			#if sys
			try {
				sys.FileSystem.rename(n, m);
				return [true];
			} catch (e:Dynamic) {
				return [null, n + ": No such file or directory", 2];
			}
			#else
			return [null, "os.rename not supported on this target", 1];
			#end
		});
		LAux.reg(O, "tmpname", function(a) return ["/tmp/lua_" + StringTools.hex(Std.random(0x7FFFFFFF), 8)]);
		LAux.reg(O, "setlocale", function(a) {
			var l = a.length > 0 ? a[0] : null;
			// Only the `C`/`POSIX` locale is modeled; anything else returns nil.
			return [(l == null || l == "" || l == "C" || l == "POSIX") ? "C" : null];
		});
	}
}