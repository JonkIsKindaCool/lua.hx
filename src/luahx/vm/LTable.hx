package luahx.vm;

import haxe.Int64;
import haxe.ds.IntMap;
import haxe.ds.ObjectMap;
import haxe.ds.StringMap;
import luahx.vm.LObject;

/**
 * ltable.c — Lua table implementation.
 *
 * A table is composed of an array part (indices `1..n`) plus a hash part that
 * preserves insertion order. The ordered hash part makes `next` O(1) and allows
 * keys to be deleted safely during iteration.
 */
final class LTable {
	public var arr:Array<Dynamic>;
	public var meta:LTable = null;

	var hk:Array<Dynamic> = null;
	var hv:Array<Dynamic> = null;
	var smap:StringMap<Int> = null;
	var imap:IntMap<Int> = null;
	var omap:ObjectMap<Dynamic, Int> = null;
	var xmap:StringMap<Int> = null; // Floats, 64-bit integers and booleans.
	var dead:Int = 0;

	public function new() {
		arr = [];
	}

	/**
	 * Builds a canonical string key for a float value so that equal floats
	 * (including `-0`, `NaN` and infinities) map to the same hash slot.
	 *
	 * @param f Float value.
	 * @returns Canonical key string.
	 */
	static function floatKey(f:Float):String {
		if (f == 0)
			return 1 / f < 0 ? "f-0" : "f0";
		if (f != f)
			return "fnan";
		if (f == Math.POSITIVE_INFINITY)
			return "f+inf";
		if (f == Math.NEGATIVE_INFINITY)
			return "f-inf";
		var neg = f < 0;
		var d = LNum.decompose(neg ? -f : f);
		return "f" + (neg ? "-" : "") + Int64.toStr(LNum.f2i(d.m)) + "/" + d.e2;
	}

	/**
	 * Produces the string key used to store non-string, non-int keys
	 * (floats, 64-bit integers and booleans) inside the `xmap`.
	 *
	 * @param k Key value.
	 * @returns Canonical key string.
	 */
	static function xkey(k:Dynamic):String {
		if (Std.isOfType(k, LFloat))
			return floatKey((cast k : LFloat).v);
		if (Std.isOfType(k, LInt64))
			return "i" + Int64.toStr((cast k : LInt64).v);
		var b:Bool = k;
		return b ? "T" : "F";
	}

	/**
	 * Finds the position of `k` inside the hash arrays.
	 *
	 * @param k Key to look up.
	 * @returns Index into `hk`/`hv`, or `-1` if the key is absent.
	 */
	function hfind(k:Dynamic):Int {
		if (hk == null)
			return -1;
		var p:Null<Int>;
		if (Std.isOfType(k, String)) {
			if (smap == null)
				return -1;
			p = smap.get(k);
		} else if (Std.isOfType(k, Int)) {
			if (imap == null)
				return -1;
			var i:Int = k;
			p = imap.get(i);
		} else if (Std.isOfType(k, LFloat) || Std.isOfType(k, LInt64) || Std.isOfType(k, Bool)) {
			if (xmap == null)
				return -1;
			p = xmap.get(xkey(k));
		} else {
			if (omap == null)
				return -1;
			p = omap.get(k);
		}
		return p == null ? -1 : p;
	}

	/**
	 * Registers `k -> p` in the appropriate auxiliary map for the key's type.
	 *
	 * @param k Key value.
	 * @param p Position of the key inside `hk`/`hv`.
	 */
	function hregister(k:Dynamic, p:Int):Void {
		if (Std.isOfType(k, String)) {
			if (smap == null)
				smap = new StringMap();
			smap.set(k, p);
		} else if (Std.isOfType(k, Int)) {
			if (imap == null)
				imap = new IntMap();
			var i:Int = k;
			imap.set(i, p);
		} else if (Std.isOfType(k, LFloat) || Std.isOfType(k, LInt64) || Std.isOfType(k, Bool)) {
			if (xmap == null)
				xmap = new StringMap();
			xmap.set(xkey(k), p);
		} else {
			if (omap == null)
				omap = new ObjectMap();
			omap.set(k, p);
		}
	}

	/**
	 * Removes tombstoned entries from the hash part and rebuilds the
	 * auxiliary index maps. Called lazily when the number of dead entries
	 * grows past a threshold.
	 */
	function compact():Void {
		var nk = [];
		var nv = [];
		for (i in 0...hk.length)
			if (hv[i] != null) {
				nk.push(hk[i]);
				nv.push(hv[i]);
			}
		hk = nk;
		hv = nv;
		dead = 0;
		smap = null;
		imap = null;
		omap = null;
		xmap = null;
		for (i in 0...hk.length)
			hregister(hk[i], i);
	}

	/**
	 * Inserts or updates a key in the hash part. Setting the value to `null`
	 * marks the slot as a tombstone instead of physically removing it, so
	 * iteration can continue safely.
	 *
	 * @param k Key value (must not be `nil` or `NaN`).
	 * @param v Value to store, or `null` to delete.
	 */
	function hset(k:Dynamic, v:Dynamic):Void {
		var p = hfind(k);
		if (p >= 0) {
			var old = hv[p];
			hv[p] = v;
			if (v == null) {
				if (old != null)
					dead++;
			} else if (old == null)
				dead--;
			return;
		}
		if (v == null)
			return;
		if (hk == null) {
			hk = [];
			hv = [];
		} else if (dead > 8 && dead * 2 > hk.length)
			compact();
		p = hk.length;
		hk.push(k);
		hv.push(v);
		hregister(k, p);
	}

	/**
	 * Moves any entries currently stored in the hash part whose keys are
	 * consecutive integers starting at `arr.length + 1` into the array part.
	 */
	public function migrate():Void {
		if (imap == null)
			return;
		while (true) {
			var p = imap.get(arr.length + 1);
			if (p == null)
				return;
			var v = hv[p];
			if (v == null)
				return;
			arr.push(v);
			hv[p] = null;
			dead++;
		}
	}

	/**
	 * Reads a string key.
	 *
	 * @param k String key.
	 * @returns The stored value, or `null` if absent.
	 */
	public inline function getStr(k:String):Dynamic {
		if (smap == null)
			return null;
		var p = smap.get(k);
		return p == null ? null : hv[p];
	}

	/**
	 * Sets a string key.
	 *
	 * @param k String key.
	 * @param v Value to store (`null` deletes).
	 */
	public function setStr(k:String, v:Dynamic):Void
		hset(k, v);

	/**
	 * Reads an integer key.
	 *
	 * @param i Integer key.
	 * @returns The stored value, or `null` if absent.
	 */
	public inline function getInt(i:Int):Dynamic {
		if (i >= 1 && i <= arr.length)
			return arr[i - 1];
		if (imap == null)
			return null;
		var p = imap.get(i);
		return p == null ? null : hv[p];
	}

	/**
	 * Sets an integer key. Assigning `null` to the last array slot shrinks the
	 * array part; assigning to `arr.length + 1` appends and migrates any
	 * contiguous entries from the hash part.
	 *
	 * @param i Integer key.
	 * @param v Value to store (`null` deletes).
	 */
	public function setInt(i:Int, v:Dynamic):Void {
		var n = arr.length;
		if (i >= 1 && i <= n) {
			arr[i - 1] = v;
			if (v == null && i == n) {
				while (arr.length > 0 && arr[arr.length - 1] == null)
					arr.pop();
			}
			return;
		}
		if (i == n + 1) {
			if (v != null) {
				arr.push(v);
				migrate();
			}
			return;
		}
		hset(i, v);
	}

	/**
	 * Raw get with any key type. Integral floats are normalized to `Int`.
	 *
	 * @param k Key value.
	 * @returns The stored value, or `null` if absent.
	 */
	public function get(k:Dynamic):Dynamic {
		if (Std.isOfType(k, String))
			return getStr(k);
		if (Std.isOfType(k, Int)) {
			var i:Int = k;
			return getInt(i);
		}
		if (k == null)
			return null;
		if (Std.isOfType(k, LFloat)) {
			var nk = LNum.floatToInt((cast k : LFloat).v);
			if (nk != null)
				return get(nk);
		}
		var p = hfind(k);
		return p < 0 ? null : hv[p];
	}

	/**
	 * Raw set. The caller is responsible for rejecting `nil` and `NaN` keys,
	 * as required by Lua semantics.
	 *
	 * @param k Key value.
	 * @param v Value to store (`null` deletes).
	 */
	public function set(k:Dynamic, v:Dynamic):Void {
		if (Std.isOfType(k, String)) {
			hset(k, v);
			return;
		}
		if (Std.isOfType(k, Int)) {
			var i:Int = k;
			setInt(i, v);
			return;
		}
		if (Std.isOfType(k, LFloat)) {
			var nk = LNum.floatToInt((cast k : LFloat).v);
			if (nk != null) {
				set(nk, v);
				return;
			}
		}
		hset(k, v);
	}

	/**
	 * Bulk-assigns a sequence of values starting at index `start` (used by
	 * table constructors). Unlike {@link setInt}, intermediate `null`s are
	 * kept, matching Lua's `{1, nil, 3}` semantics.
	 *
	 * @param start First target index.
	 * @param src Source array.
	 * @param from First source index.
	 * @param n Number of elements to copy.
	 */
	public function setList(start:Int, src:Array<Dynamic>, from:Int, n:Int):Void {
		if (start == arr.length + 1) {
			for (i in 0...n)
				arr.push(src[from + i]);
			while (arr.length > 0 && arr[arr.length - 1] == null)
				arr.pop();
			migrate();
		} else
			for (i in 0...n)
				setInt(start + i, src[from + i]);
	}

	/**
	 * Returns the array-part length, which is one of the borders used by the
	 * `#` operator.
	 *
	 * @returns Number of elements in the array part.
	 */
	public inline function length():Int
		return arr.length;

	/**
	 * Implements the `next` iterator. Returns `[key, value]`, or `null` when
	 * iteration is complete.
	 *
	 * @param k Previous key (or `null` to start).
	 * @returns `[key, value]` for the next live entry, or `null` at the end.
	 * @throws LuaError If `k` is not a valid key (never existed or was removed while iterating).
	 */
	public function next(k:Dynamic):Array<Dynamic> {
		var i:Int;
		if (k == null)
			i = 0;
		else {
			if (Std.isOfType(k, LFloat)) {
				var nk = LNum.floatToInt((cast k : LFloat).v);
				if (nk != null)
					k = nk;
			}
			if (Std.isOfType(k, Int) && (cast k : Int) >= 1 && (cast k : Int) <= arr.length)
				i = k;
			else {
				var p = hfind(k);
				if (p < 0) {
					// The array may have shrunk during iteration; tolerate that case.
					if (Std.isOfType(k, Int))
						i = arr.length;
					else
						throw new LuaError("invalid key to 'next'", true);
				} else
					i = arr.length + p + 1;
			}
		}
		var n = arr.length;
		while (i < n) {
			var v = arr[i];
			if (v != null)
				return [i + 1, v];
			i++;
		}
		if (hk == null)
			return null;
		var h = i - n;
		while (h < hk.length) {
			var v = hv[h];
			if (v != null)
				return [hk[h], v];
			h++;
		}
		return null;
	}

	/**
	 * Approximate number of live entries in the hash part (excluding tombstones).
	 *
	 * @returns Number of non-null hash entries.
	 */
	public function hashCount():Int
		return hk == null ? 0 : hk.length - dead;

	/**
	 * Copies the array part into a fresh Haxe `Array`.
	 *
	 * @returns A shallow copy of the array part.
	 */
	public function toArray():Array<Dynamic> {
		var r = [];
		for (i in 0...arr.length)
			r.push(arr[i]);
		return r;
	}
}
