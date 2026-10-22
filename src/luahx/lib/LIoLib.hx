package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LStr;
import luahx.vm.LTable;

/**
 * A Lua file handle. Files are emulated on top of an in-memory buffer that
 * gets synced to disk on {@link flush} / {@link close} (only on `sys`
 * targets).
 *
 * The `kind` field distinguishes the standard streams from on-disk files so
 * that writes to `io.stdout`/`io.stderr` are forwarded to the host and reads
 * from `io.stdin` pull from {@link LState.stdin}.
 */
private class IoFile {
	/** `0` stdout, `1` stderr, `2` stdin, `3` on-disk file. */
	public var kind:Int;

	public var buf:String = "";
	public var pos:Int = 0;
	public var path:String = null;
	public var readable:Bool = true;
	public var writable:Bool = false;
	public var append:Bool = false;
	public var closed:Bool = false;

	/** Whether `buf` has unsaved changes that must be flushed to disk. */
	public var dirty:Bool = false;

	var L:LuaState;

	public function new(L:LuaState, kind:Int) {
		this.L = L;
		this.kind = kind;
	}

	/**
	 * Pulls one more line from the host's stdin into `buf`.
	 *
	 * @returns `true` if new data was appended, `false` at EOF.
	 */
	function fill():Bool {
		if (kind != 2)
			return false;
		var l = L.stdin();
		if (l == null)
			return false;
		buf += l + "\n";
		return true;
	}

	/**
	 * Reads until the next newline.
	 *
	 * @param keep If `true`, the newline is included in the returned string
	 *             (Lua's `"*L"` format); otherwise it is dropped (`"*l"`).
	 * @returns The line, or `null` at EOF.
	 */
	public function readLine(keep:Bool):String {
		while (true) {
			var i = buf.indexOf("\n", pos);
			if (i >= 0) {
				var r = buf.substring(pos, keep ? i + 1 : i);
				pos = i + 1;
				return r;
			}
			if (!fill())
				break;
		}
		if (pos >= buf.length)
			return null;
		var r = buf.substr(pos);
		pos = buf.length;
		return r;
	}

	/**
	 * Reads the remainder of the file.
	 *
	 * @returns Everything from the current position onward (empty string at EOF).
	 */
	public function readAll():String {
		while (fill()) {}
		var r = buf.substr(pos);
		pos = buf.length;
		return r;
	}

	/**
	 * Reads up to `n` characters.
	 *
	 * @param n Number of characters to read.
	 * @returns The characters, or `null` if not enough data is available.
	 */
	public function readChars(n:Int):String {
		while (buf.length - pos < n && fill()) {}
		if (pos >= buf.length && n > 0)
			return null;
		var r = buf.substr(pos, n);
		pos += r.length;
		return r;
	}

	/**
	 * Skips whitespace and parses a Lua numeric literal from the stream.
	 *
	 * The character set `"0123456789abcdefABCDEFxX.+-pP"` covers every
	 * character allowed in decimal and hexadecimal numerals, including the
	 * `0x`/`0X` prefix and `p`/`P` exponent markers.
	 *
	 * @returns The parsed number, or `null` if no numeral was found.
	 */
	public function readNumber():Dynamic {
		while (true) {
			while (pos < buf.length && (buf.charCodeAt(pos) == 32 || (buf.charCodeAt(pos) >= 9 && buf.charCodeAt(pos) <= 13)))
				pos++;
			if (pos < buf.length || !fill())
				break;
		}
		var s = pos;
		while (pos < buf.length && "0123456789abcdefABCDEFxX.+-pP".indexOf(buf.charAt(pos)) >= 0)
			pos++;
		return LNum.str2number(buf.substring(s, pos));
	}

	/**
	 * Writes `s` to the file. Standard streams forward directly to the
	 * host; on-disk files update the in-memory buffer and mark it dirty.
	 *
	 * In append mode the write always goes to the end of the buffer and the
	 * cursor moves with it; otherwise the write overwrites the bytes at the
	 * current position.
	 *
	 * @param s String to write.
	 */
	public function write(s:String):Void {
		if (kind == 0)
			L.stdout(s);
		else if (kind == 1)
			L.stderr(s);
		else {
			if (append) {
				buf += s;
				pos = buf.length;
			} else {
				buf = buf.substr(0, pos) + s + buf.substr(pos + s.length);
				pos += s.length;
			}
			dirty = true;
		}
	}

	/**
	 * Flushes any pending changes to disk (only meaningful for on-disk files
	 * on `sys` targets; other kinds are no-ops).
	 */
	public function flush():Void {
		#if sys
		if (kind == 3 && dirty && path != null) {
			sys.io.File.saveBytes(path, LStr.toBytes(buf));
			dirty = false;
		}
		#end
	}

	/**
	 * Flushes and marks the file as closed.
	 */
	public function close():Void {
		flush();
		closed = true;
	}
}

/**
 * liolib.c — Implementation of the `io` library.
 *
 * On-disk files are only available on `sys` targets; on other targets,
 * `io.open` returns a `(nil, message, errno)` tuple.
 */
class LIoLib {
	/**
	 * Registers the `io` module and its `FILE*` metatable.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var IO = new LTable();
		L.globals.setStr("io", IO);
		var meta = new LTable();
		var methods = new LTable();
		meta.setStr("__index", methods);
		meta.setStr("__name", "FILE*");
		var wrap = function(f:IoFile):LuaUserdata return new LuaUserdata(f, meta);
		var stdout = wrap(new IoFile(L, 0));
		var stderr = wrap(new IoFile(L, 1));
		var stdin = wrap(new IoFile(L, 2));
		// Output-only standard streams are not readable, and vice versa.
		(cast stdout.data : IoFile).readable = false;
		(cast stdout.data : IoFile).writable = true;
		(cast stderr.data : IoFile).writable = true;
		(cast stderr.data : IoFile).readable = false;
		IO.setStr("stdout", stdout);
		IO.setStr("stderr", stderr);
		IO.setStr("stdin", stdin);
		var defOut = stdout;
		var defIn = stdin;

		/**
		 * Validates that `a[i]` is a `FILE*` userdata and returns its backing
		 * `IoFile`.
		 *
		 * @param a Argument array.
		 * @param i Argument index.
		 * @param fname Function name (for error messages).
		 * @param allowClosed When `true`, closed files are accepted (used by
		 *                    `__tostring`).
		 * @returns The backing `IoFile`.
		 */
		function toFile(a:Array<Dynamic>, i:Int, fname:String, allowClosed:Bool = false):IoFile {
			if (i < a.length && Std.isOfType(a[i], LuaUserdata) && Std.isOfType((cast a[i] : LuaUserdata).data, IoFile)) {
				var f:IoFile = (cast a[i] : LuaUserdata).data;
				if (f.closed && !allowClosed)
					L.error("attempt to use a closed file");
				return f;
			}
			return LAux.typeError(L, a, i, fname, "FILE*");
		}
		meta.setStr("__tostring", new NativeFunction("tostring", function(a) {
			var f = toFile(a, 0, "tostring", true);
			return [f.closed ? "file (closed)" : "file (" + L.addrOf(a[0]) + ")"];
		}));

		/**
		 * Implements `file:read` / `io.read`. Defaults to `"*l"` when no
		 * formats are supplied.
		 *
		 * Each format may be an integer (read N bytes) or a string starting
		 * with `*l`, `*L`, `*a` or `*n`. Reading stops early on the first
		 * `nil` result.
		 *
		 * @param f Target file.
		 * @param a Argument array.
		 * @param from First format argument index.
		 * @returns The values read, or a `(nil, message, errno)` tuple.
		 */
		function doRead(f:IoFile, a:Array<Dynamic>, from:Int):Array<Dynamic> {
			if (!f.readable)
				return [null, "Bad file descriptor", 9];
			if (a.length <= from)
				return [f.readLine(false)];
			var r:Array<Dynamic> = [];
			for (i in from...a.length) {
				var fmt = a[i];
				var v:Dynamic;
				if (LNum.isNumber(fmt)) {
					var n = LAux.checkInt(L, a, i, "read");
					v = f.readChars(n);
					// `read(0)` returns "" unless at EOF, in which case it returns nil.
					if (n == 0)
						v = f.pos < f.buf.length || f.readChars(1) != null ? "" : null;
				} else {
					var s = LAux.checkStr(L, a, i, "read");
					if (s.charAt(0) == "*")
						s = s.substr(1);
					switch (s.charAt(0)) {
						case "l":
							v = f.readLine(false);
						case "L":
							v = f.readLine(true);
						case "a":
							v = f.readAll();
						case "n":
							v = f.readNumber();
						default:
							return LAux.argError(L, i, "read", "invalid format");
					}
				}
				r.push(v);
				if (v == null)
					break;
			}
			return r;
		}

		/**
		 * Implements `file:write` / `io.write`, returning the file handle for
		 * chaining.
		 *
		 * Floats are formatted with `%.14g` (no trailing `.0`), matching
		 * `io.write`'s contract rather than `tostring`.
		 *
		 * @param f Target file.
		 * @param fv File userdata to return as the result.
		 * @param a Argument array.
		 * @param from First value argument index.
		 * @returns The result array (`[fv]`).
		 */
		function doWrite(f:IoFile, fv:Dynamic, a:Array<Dynamic>, from:Int):Array<Dynamic> {
			if (!f.writable)
				return [null, "Bad file descriptor", 9];
			for (i in from...a.length) {
				var v = a[i];
				if (Std.isOfType(v, LFloat)) {
					var x = (cast v : LFloat).v;
					f.write((x != x || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) ? LNum.numToString(v) : LNum.fmtG(x, 14, false, false));
				} else
					f.write(LAux.checkStr(L, a, i, "write"));
			}
			return [fv];
		}
		LAux.reg(IO, "write", function(a) return doWrite((cast defOut.data : IoFile), defOut, a, 0));
		LAux.reg(IO, "read", function(a) return doRead((cast defIn.data : IoFile), a, 0));
		LAux.reg(methods, "write", function(a) return doWrite(toFile(a, 0, "write"), a[0], a, 1));
		LAux.reg(methods, "read", function(a) return doRead(toFile(a, 0, "read"), a, 1));
		LAux.reg(methods, "flush", function(a) {
			toFile(a, 0, "flush").flush();
			return [a[0]];
		});
		LAux.reg(IO, "flush", function(a) return [defOut]);
		LAux.reg(methods, "setvbuf", function(a) return [true]);
		LAux.reg(methods, "seek", function(a) {
			var f = toFile(a, 0, "seek");
			var whence = LAux.optStr(L, a, 1, "seek", "cur");
			var off = LAux.optInt(L, a, 2, "seek", 0);
			// Convert the "whence" token into the base offset for `pos`.
			var base = switch (whence) {
				case "set": 0;
				case "cur": f.pos;
				case "end": f.buf.length;
				default: LAux.argError(L, 1, "seek", "invalid option '" + whence + "'");
			}
			if (base + off < 0)
				return [null, "Invalid argument", 22];
			f.pos = base + off;
			return [f.pos];
		});
		var closeFn = function(a:Array<Dynamic>):Array<Dynamic> {
			var f = a.length > 0 ? toFile(a, 0, "close") : (cast defOut.data : IoFile);
			// Standard streams are never closed (their `kind` is 0..2).
			if (f.kind != 3)
				return [null, "cannot close standard file"];
			f.close();
			return [true];
		};
		LAux.reg(methods, "close", closeFn);
		LAux.reg(IO, "close", closeFn);
		meta.setStr("__close", methods.getStr("close"));
		meta.setStr("__gc", methods.getStr("close"));
		LAux.reg(IO, "type", function(a) {
			LAux.checkAny(L, a, 0, "type");
			if (Std.isOfType(a[0], LuaUserdata) && Std.isOfType((cast a[0] : LuaUserdata).data, IoFile))
				return [((cast(cast a[0] : LuaUserdata).data : IoFile).closed) ? "closed file" : "file"];
			return [null];
		});

		/**
		 * Opens a file with the given mode.
		 *
		 * Only modes starting with `r`, `w` or `a`, optionally followed by
		 * `+`, `b` or `+b`, are accepted.
		 *
		 * @param name File path.
		 * @param mode Lua open mode.
		 * @returns `[file]` on success, or `(nil, message, errno)` on failure.
		 */
		var openFile = function(name:String, mode:String):Array<Dynamic> {
			var okMode = mode.length >= 1 && "rwa".indexOf(mode.charAt(0)) >= 0 && ["", "+", "b", "+b"].indexOf(mode.substr(1)) >= 0;
			if (!okMode)
				return LAux.argError(L, 1, "open", "invalid mode");
			#if sys
			var f = new IoFile(L, 3);
			f.path = name;
			var m = mode.charAt(0);
			var plus = mode.indexOf("+") >= 0;
			f.readable = m == "r" || plus;
			f.writable = m != "r" || plus;
			f.append = m == "a";
			try {
				if (m == "w") {
					// Truncate / create.
					sys.io.File.saveBytes(name, haxe.io.Bytes.alloc(0));
				} else if (sys.FileSystem.exists(name) && !sys.FileSystem.isDirectory(name)) {
					f.buf = LStr.ofBytes(sys.io.File.getBytes(name));
				} else if (m == "r")
					return [null, name + ": No such file or directory", 2];
				else
					sys.io.File.saveBytes(name, haxe.io.Bytes.alloc(0));
			} catch (e:Dynamic) {
				return [null, name + ": Permission denied", 13];
			}
			// In append mode, the cursor starts at the end of the file.
			if (f.append)
				f.pos = f.buf.length;
			return [wrap(f)];
			#else
			return [null, name + ": files are not supported on this target", 1];
			#end
		};
		LAux.reg(IO, "open", function(a) return openFile(LAux.checkStr(L, a, 0, "open"), LAux.optStr(L, a, 1, "open", "r")));

		/**
		 * Builds a `lines` iterator over `f`. When `closeAtEof` is `true`,
		 * the file is closed automatically at EOF (used by `io.lines(name)`).
		 *
		 * @param f File to iterate.
		 * @param fmts Read formats.
		 * @param closeAtEof Whether to close the file when the iterator ends.
		 * @param fv File userdata (for closure captures).
		 * @returns The iterator function.
		 */
		var linesIter = function(f:IoFile, fmts:Array<Dynamic>, closeAtEof:Bool, fv:Dynamic):NativeFunction {
			return new NativeFunction("lines_iter", function(_) {
				if (f.closed)
					L.error("file is already closed");
				var r = doRead(f, [null].concat(fmts), 1);
				if (r.length == 0 || r[0] == null) {
					if (closeAtEof)
						f.close();
					return [null];
				}
				return r;
			});
		};
		LAux.reg(methods, "lines", function(a) return [linesIter(toFile(a, 0, "lines"), a.slice(1), false, a[0])]);
		LAux.reg(IO, "lines", function(a) {
			if (a.length == 0 || a[0] == null)
				return [linesIter((cast defIn.data : IoFile), [], false, defIn)];
			var name = LAux.checkStr(L, a, 0, "lines");
			var r = openFile(name, "r");
			if (r[0] == null)
				return L.error(r[1]);
			// The 4-tuple form `[iter, state, ctrl, close]` lets a generic
			// `for` loop run the file's `__close` when iteration ends.
			return [linesIter((cast r[0].data : IoFile), a.slice(1), true, r[0]), null, null, r[0]];
		});
		LAux.reg(IO, "output", function(a) {
			if (a.length > 0 && a[0] != null) {
				if (Std.isOfType(a[0], String)) {
					var r = openFile(a[0], "w");
					if (r[0] == null)
						return L.error(r[1]);
					defOut = r[0];
				} else {
					toFile(a, 0, "output");
					defOut = a[0];
				}
			}
			return [defOut];
		});
		LAux.reg(IO, "input", function(a) {
			if (a.length > 0 && a[0] != null) {
				if (Std.isOfType(a[0], String)) {
					var r = openFile(a[0], "r");
					if (r[0] == null)
						return L.error(r[1]);
					defIn = r[0];
				} else {
					toFile(a, 0, "input");
					defIn = a[0];
				}
			}
			return [defIn];
		});
		LAux.reg(IO, "popen", function(a) return L.error("'popen' not supported"));
		LAux.reg(IO, "tmpfile", function(a) return L.error("'tmpfile' not supported"));
	}
}
