package luahx.lib;

import luahx.lib.LAux;
import luahx.vm.LNum;
import luahx.vm.LObject;
import luahx.vm.LState;
import luahx.vm.LTable;

/**
 * ltablib.c — Implementation of the `table` library.
 */
class LTabLib {
	/**
	 * Returns the length of `t` as an `Int`, honoring `__len` when present
	 * and rejecting non-integer lengths.
	 *
	 * @param L Lua state (for metamethod dispatch and error reporting).
	 * @param t Table whose length is requested.
	 * @returns The length as a plain `Int`.
	 */
	static function lenOf(L:LuaState, t:LTable):Int {
		if (t.meta == null) return t.length();
		var n = L.len(t, null);
		var i = LNum.toInteger(n);
		if (i == null) L.error("object length is not an integer");
		return LAux.clamp(LNum.toI64(i));
	}

	/**
	 * Reads `t[i]` at integer index `i`, bypassing metamethods when the
	 * table has no metatable.
	 *
	 * @param L Lua state.
	 * @param t Target table.
	 * @param i Integer key.
	 * @returns The indexed value.
	 */
	static inline function geti(L:LuaState, t:LTable, i:Int):Dynamic
		return t.meta == null ? t.getInt(i) : L.index(t, i, null);

	/**
	 * Writes `t[i] = v` at integer index `i`, bypassing metamethods when the
	 * table has no metatable.
	 *
	 * @param L Lua state.
	 * @param t Target table.
	 * @param i Integer key.
	 * @param v Value to store.
	 */
	static inline function seti(L:LuaState, t:LTable, i:Int, v:Dynamic):Void {
		if (t.meta == null) t.setInt(i, v);
		else L.setIndex(t, i, v, null);
	}

	/**
	 * Ensures `a[i]` is a table (or a value with a `__index`/`__newindex`/
	 * `__len` metamethod, so it behaves like one).
	 *
	 * @param L Lua state (for error reporting).
	 * @param a Argument array.
	 * @param i Argument index.
	 * @param fname Function name (for error messages).
	 * @returns The coerced table-like value.
	 */
	static function checkTab(L:LuaState, a:Array<Dynamic>, i:Int, fname:String):LTable {
		if (i < a.length && Std.isOfType(a[i], LTable)) return cast a[i];
		var v = i < a.length ? a[i] : null;
		var mt = L.getMetatable(v);
		if (mt != null && (mt.getStr("__index") != null || mt.getStr("__newindex") != null || mt.getStr("__len") != null)) return cast v;
		return LAux.typeError(L, a, i, fname, "table");
	}

	/**
	 * Registers the `table` module and its functions (`insert`, `remove`,
	 * `concat`, `unpack`, `pack`, `create`, `move`, `sort`) into the given
	 * state's globals.
	 *
	 * @param L Target Lua state.
	 */
	public static function open(L:LuaState):Void {
		var T = new LTable();
		L.globals.setStr("table", T);
		var E = LuaState.EMPTY;

		LAux.reg(T, "insert", function(a) {
			var t = checkTab(L, a, 0, "insert");
			var e = lenOf(L, t) + 1;
			switch (a.length) {
				case 2:
					seti(L, t, e, a[1]);
				case 3:
					var pos = LAux.checkInt(L, a, 1, "insert");
					if (pos < 1 || pos > e) LAux.argError(L, 1, "insert", "position out of bounds");
					// Fast path: the table has no metatable and its array part is
					// exactly the sequence, so we can splice directly.
					if (t.meta == null && a[2] != null && t.arr.length == e - 1) {
						t.arr.insert(pos - 1, a[2]);
						t.migrate();
					} else {
						var i = e;
						while (i > pos) {
							seti(L, t, i, geti(L, t, i - 1));
							i--;
						}
						seti(L, t, pos, a[2]);
					}
				default:
					L.error("wrong number of arguments to 'insert'");
			}
			return E;
		});
		LAux.reg(T, "remove", function(a) {
			var t = checkTab(L, a, 0, "remove");
			var size = lenOf(L, t);
			var pos = LAux.optInt(L, a, 1, "remove", size);
			if (a.length > 1 && pos != size && (pos < 1 || pos > size + 1)) LAux.argError(L, 1, "remove", "position out of bounds");
			// Fast path: no metatable and the array part is a plain sequence.
			if (t.meta == null && pos >= 1 && pos <= size && t.arr.length == size) {
				var v = t.arr.splice(pos - 1, 1)[0];
				while (t.arr.length > 0 && t.arr[t.arr.length - 1] == null) t.arr.pop();
				return [v];
			}
			var v = geti(L, t, pos);
			while (pos < size) {
				seti(L, t, pos, geti(L, t, pos + 1));
				pos++;
			}
			if (pos <= size || a.length > 1) seti(L, t, pos, null);
			return [v];
		});
		LAux.reg(T, "concat", function(a) {
			var t = checkTab(L, a, 0, "concat");
			var sep = LAux.optStr(L, a, 1, "concat", "");
			var i = LAux.optInt(L, a, 2, "concat", 1);
			var j = a.length > 3 && a[3] != null ? LAux.checkInt(L, a, 3, "concat") : lenOf(L, t);
			var b = new StringBuf();
			var k = i;
			while (k <= j) {
				var v = geti(L, t, k);
				if (Std.isOfType(v, String)) b.add(v);
				else if (LNum.isNumber(v)) b.add(LNum.numToString(v));
				else L.error("invalid value (at index " + k + ") in table for 'concat'");
				if (k < j) b.add(sep);
				k++;
			}
			return [b.toString()];
		});
		var unpack = function(a:Array<Dynamic>):Array<Dynamic> {
			var t = a.length > 0 ? a[0] : null;
			var i = LAux.optInt(L, a, 1, "unpack", 1);
			var e = a.length > 2 && a[2] != null ? LAux.checkInt(L, a, 2, "unpack") : (Std.isOfType(t, LTable) ? lenOf(L, cast t) : cast L.len(t, null));
			if (i > e) return E;
			if (e - i >= 1000000) L.error("too many results to unpack");
			var r:Array<Dynamic> = [];
			var tt:Dynamic = t;
			for (k in i...e + 1) r.push(Std.isOfType(tt, LTable) && (cast tt : LTable).meta == null ? (cast tt : LTable).getInt(k) : L.index(tt, k, null));
			return r;
		};
		LAux.reg(T, "unpack", unpack);
		// No global `unpack` alias: Lua 5.5 dropped it.
		L.globals.getStr("table");
		LAux.reg(T, "pack", function(a) {
			var t = new LTable();
			t.setList(1, a, 0, a.length);
			t.setStr("n", a.length);
			return [t];
		});
		LAux.reg(T, "create", function(a) {
			// `narr`/`nhash` hints are accepted but ignored.
			LAux.optInt(L, a, 0, "create", 0);
			return [new LTable()];
		});
		LAux.reg(T, "move", function(a) {
			var a1 = checkTab(L, a, 0, "move");
			var f = LAux.checkInt(L, a, 1, "move");
			var e = LAux.checkInt(L, a, 2, "move");
			var t = LAux.checkInt(L, a, 3, "move");
			var a2 = a.length > 4 && a[4] != null ? checkTab(L, a, 4, "move") : a1;
			if (e >= f) {
				if (!(f > 0 || e < 0x7FFFFFFF + f)) LAux.argError(L, 2, "move", "too many elements to move");
				// Copy forward unless the ranges overlap in the "backward" direction.
				if (t > e || t <= f || a1 != a2) {
					for (i in 0...e - f + 1) seti(L, a2, t + i, geti(L, a1, f + i));
				} else {
					var i = e - f;
					while (i >= 0) {
						seti(L, a2, t + i, geti(L, a1, f + i));
						i--;
					}
				}
			}
			return [a2];
		});
		LAux.reg(T, "sort", function(a) {
			var t = checkTab(L, a, 0, "sort");
			var n = lenOf(L, t);
			if (n > 1) {
				var comp:Dynamic = a.length > 1 ? a[1] : null;
				if (comp != null && !Std.isOfType(comp, LuaFunction)) LAux.typeError(L, a, 1, "sort", "function");
				// Copy to a 1-based array so indices match Lua's.
				var arr:Array<Dynamic> = [null];
				for (i in 1...n + 1) arr.push(geti(L, t, i));
				var lt:Dynamic->Dynamic->Bool = comp == null ? function(x, y) return L.lt(x, y) : function(x, y) return !LuaState.isFalse(LuaState.first(L.call(comp, [x, y])));
				auxsort(L, arr, 1, n, lt);
				for (i in 1...n + 1) seti(L, t, i, arr[i]);
			}
			return E;
		});
	}

	/**
	 * Quicksort helper used by `table.sort` (mirrors `auxsort` from
	 * `ltablib.c`). Uses median-of-three pivoting and recurses into the
	 * smaller partition to bound stack depth.
	 *
	 * @param L Lua state (for raising comparator errors).
	 * @param a 1-based array being sorted.
	 * @param lo First index of the current partition.
	 * @param up Last index of the current partition.
	 * @param lt Comparator returning whether the first argument is less than the second.
	 */
	static function auxsort(L:LuaState, a:Array<Dynamic>, lo:Int, up:Int, lt:Dynamic->Dynamic->Bool):Void {
		while (lo < up) {
			if (lt(a[up], a[lo])) swap(a, lo, up);
			if (up - lo == 1) break;
			var p = (lo + up) >> 1;
			if (lt(a[p], a[lo])) swap(a, p, lo);
			else if (lt(a[up], a[p])) swap(a, p, up);
			if (up - lo == 2) break;
			var pivot = a[p];
			swap(a, p, up - 1);
			var i = lo;
			var j = up - 1;
			while (true) {
				while (lt(a[++i], pivot)) {
					if (i == up - 1) L.error("invalid order function for sorting");
				}
				while (lt(pivot, a[--j])) {
					if (j < i) L.error("invalid order function for sorting");
				}
				if (j < i) break;
				swap(a, i, j);
			}
			swap(a, up - 1, i);
			p = i;
			// Recurse into the smaller side to bound the stack depth.
			if (p - lo < up - p) {
				auxsort(L, a, lo, p - 1, lt);
				lo = p + 1;
			} else {
				auxsort(L, a, p + 1, up, lt);
				up = p - 1;
			}
		}
	}

	/**
	 * Swaps two elements of `a`.
	 *
	 * @param a Array to mutate.
	 * @param i First index.
	 * @param j Second index.
	 */
	static inline function swap(a:Array<Dynamic>, i:Int, j:Int):Void {
		var t = a[i];
		a[i] = a[j];
		a[j] = t;
	}
}