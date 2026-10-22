package luahx.vm;

import haxe.Int64;
import luahx.vm.LObject;
import luahx.vm.LOp;
import luahx.vm.LState;

/**
 * lvm.c — VM main loop.
 *
 * Lua->Lua calls do not recurse on the Haxe call stack; instead, frames are
 * allocated on the heap (`co.ci` linked list) and the interpreter loops in place.
 */
class LVM {
	static final TWO52:Float = 4503599627370496.0;

	/**
	 * Runs the interpreter until a boundary frame returns or the coroutine yields.
	 *
	 * @param L The owning Lua state (used for metamethods, error handling, etc.).
	 * @param co The coroutine whose frames and stack are executed.
	 */
	public static function execute(L:LuaState, co:Coroutine):Void {
		var stack = co.stack;
		while (true) {
			var ci = co.ci;
			var cl = ci.cl;
			var p = cl.p;
			var ops = p.ops;
			var OA = p.a;
			var OB = p.b;
			var OC = p.c;
			var K = p.consts;
			var base = ci.base;
			var pc = ci.pc;
			try {
				while (true) {
					var op = ops[pc];
					var a = OA[pc];
					var b = OB[pc];
					pc++;
					if (op >= cast (LOp.ADD, Int) && op <= LOp.ADD + 11) { // binary arithmetic (ADD..BNOT-ish range)
						var sp = co.sp;
						var x = stack[sp - 2];
						var y = stack[sp - 1];
						var r = LNum.arith(op - LOp.ADD, x, y);
						if (r == LNum.FAIL)
							r = L.arithMeta(op - LOp.ADD, x, y, p.d1[pc - 1], p.d2[pc - 1]);
						stack[sp - 2] = r;
						co.sp = sp - 1;
						continue;
					}
					switch (op) {
						case NIL:
							stack[co.sp++] = null;
						case NILN:
							for (i in 0...a)
								stack[co.sp++] = null;
						case TRUE:
							stack[co.sp++] = true;
						case FALSE:
							stack[co.sp++] = false;
						case CONST:
							stack[co.sp++] = K[a];
						case VARARG:
							var va = ci.varargs;
							var n = va.length;
							if (b < 0) {
								for (i in 0...n)
									stack[co.sp++] = va[i];
								co.nmulti = n;
							} else
								for (i in 0...b)
									stack[co.sp++] = i < n ? va[i] : null;
						case GETLOC:
							stack[co.sp++] = stack[base + a];
						case SETLOC:
							stack[base + a] = stack[--co.sp];
						case GETCELL:
							stack[co.sp++] = (cast stack[base + a] : Cell).v;
						case SETCELL:
							(cast stack[base + a] : Cell).v = stack[--co.sp];
						case NEWCELL:
							stack[base + a] = new Cell(stack[base + a]);
						case GETUP:
							stack[co.sp++] = cl.upvals[a].v;
						case SETUP:
							cl.upvals[a].v = stack[--co.sp];
						case GETFIELD:
							var o = stack[co.sp - 1];
							var k:String = K[a];
							var v:Dynamic;
							if (Std.isOfType(o, LTable)) {
								var t:LTable = cast o;
								v = t.getStr(k);
								if (v == null && t.meta != null)
									v = L.index(o, k, p.d1[pc - 1]);
							} else
								v = L.index(o, k, p.d1[pc - 1]);
							stack[co.sp - 1] = v;
						case GETTABLE:
							var sp = co.sp;
							var o = stack[sp - 2];
							var k = stack[sp - 1];
							var v:Dynamic;
							if (Std.isOfType(o, LTable)) {
								var t:LTable = cast o;
								v = t.get(k);
								if (v == null && t.meta != null)
									v = L.index(o, k, p.d1[pc - 1]);
							} else
								v = L.index(o, k, p.d1[pc - 1]);
							stack[sp - 2] = v;
							co.sp = sp - 1;
						case SETTABLE:
							var sp = co.sp;
							var o = stack[sp - 3];
							var k = stack[sp - 2];
							var v = stack[sp - 1];
							if (Std.isOfType(o, LTable) && (cast o : LTable).meta == null)
								L.rawSet(cast o, k, v);
							else
								L.setIndex(o, k, v, p.d1[pc - 1]);
							co.sp = sp - 3;
						case SETFIELD:
							var sp = co.sp;
							var o = stack[sp - 2];
							var v = stack[sp - 1];
							if (Std.isOfType(o, LTable) && (cast o : LTable).meta == null)
								(cast o : LTable).setStr(K[a], v);
							else
								L.setIndex(o, K[a], v, p.d1[pc - 1]);
							co.sp = sp - 2;
						case SETTAB_D:
							var sp = co.sp;
							var v = stack[sp - 1];
							var k = stack[sp - 2 - a];
							var o = stack[sp - 3 - a];
							L.setIndex(o, k, v, p.d1[pc - 1]);
							co.sp = sp - 1;
						case NEWTABLE:
							stack[co.sp++] = new LTable();
						case INITFIELD:
							var sp = co.sp;
							(cast stack[sp - 2 - b] : LTable).setStr(K[a], stack[sp - 1]);
							co.sp = sp - 1;
						case INITTABLE:
							var sp = co.sp;
							L.rawSet(cast stack[sp - 3 - b], stack[sp - 2], stack[sp - 1]);
							co.sp = sp - 2;
						case SETLIST:
							var n = OC[pc - 1] == 1 ? b + co.nmulti : b;
							var sp = co.sp;
							(cast stack[sp - n - 1] : LTable).setList(a, stack, sp - n, n);
							co.sp = sp - n;
						case SELF:
							var o = stack[co.sp - 1];
							var f:Dynamic;
							if (Std.isOfType(o, LTable)) {
								var t:LTable = cast o;
								f = t.getStr(K[a]);
								if (f == null && t.meta != null)
									f = L.index(o, K[a], p.d1[pc - 1]);
							} else
								f = L.index(o, K[a], p.d1[pc - 1]);
							stack[co.sp - 1] = f;
							stack[co.sp++] = o;
						case CALL:
							var nargs = a + (OC[pc - 1] == 1 ? co.nmulti : 0);
							ci.pc = pc;
							var r = L.precall(co, co.sp - nargs - 1, nargs, b, p.d1[pc - 1]);
							if (r == 1)
								break; // Haxe native call finished: continue in this loop.
							if (r == 2)
								return; // Yielded: unwind to the caller of execute.
						case TAILCALL:
							var nargs = a + (OC[pc - 1] == 1 ? co.nmulti : 0);
							var funcIdx = co.sp - nargs - 1;
							ci.pc = pc;
							var f = stack[funcIdx];
							// Tail call to a Lua closure with no pending to-be-closed vars: reuse the frame.
							if (Std.isOfType(f, LuaClosure) && !(co.tbc.length > 0 && co.tbc[co.tbc.length - 1] >= base)) {
								var dest = base - 1;
								for (i in 0...nargs + 1)
									stack[dest + i] = stack[funcIdx + i];
								co.ci = ci.prev;
								var ni = L.pushLua(co, cast f, dest, nargs, ci.retPos, ci.nres);
								ni.isBoundary = ci.isBoundary;
								ni.isPcall = ci.isPcall;
								ni.handler = ci.handler;
								break;
							}
							var r = L.precall(co, funcIdx, nargs, -1, p.d1[pc - 1]);
							if (r == 1)
								break;
							if (r == 2)
								return;
						case RETURN:
							var n = a + (OC[pc - 1] == 1 ? co.nmulti : 0);
							var first = co.sp - n;
							if (co.tbc.length > 0 && co.tbc[co.tbc.length - 1] >= base) {
								var e = L.closeTbc(co, base, null);
								if (e != null)
									throw e;
							}
							var retPos = ci.retPos;
							var nres = ci.nres;
							var off = ci.isPcall ? 1 : 0;
							if (off == 1)
								stack[retPos] = true; // pcall prepends an `ok` flag.
							for (i in 0...n)
								stack[retPos + off + i] = stack[first + i];
							var total = n + off;
							if (nres < 0) {
								// Multret: forward actual result count to the caller.
								co.sp = retPos + total;
								co.nmulti = total;
							} else {
								for (i in total...nres)
									stack[retPos + i] = null;
								co.sp = retPos + nres;
							}
							co.ci = ci.prev;
							if (ci.isBoundary)
								return;
							break;
						case UNM, LOp.BNOT:
							var x = stack[co.sp - 1];
							var r = LNum.arith(op - LOp.ADD, x, x);
							if (r == LNum.FAIL)
								r = L.arithMeta(op - LOp.ADD, x, x, p.d1[pc - 1], p.d1[pc - 1]);
							stack[co.sp - 1] = r;
						case NOT:
							stack[co.sp - 1] = LuaState.isFalse(stack[co.sp - 1]);
						case LEN:
							var x = stack[co.sp - 1];
							if (Std.isOfType(x, LTable) && (cast x : LTable).meta == null)
								stack[co.sp - 1] = (cast x : LTable).length();
							else
								stack[co.sp - 1] = L.len(x, p.d1[pc - 1]);
						case CONCAT:
							L.concatN(co, a);
						case EQ, LOp.NE:
							var sp = co.sp;
							var x = stack[sp - 2];
							var y = stack[sp - 1];
							var r = (Std.isOfType(x, Int) && Std.isOfType(y, Int)) ? ((cast x : Int) == (cast y : Int)) : L.eq(x, y);
							stack[sp - 2] = op == LOp.EQ ? r : !r;
							co.sp = sp - 1;
						case LT, LOp.GT, LOp.LE, LOp.GE:
							var sp = co.sp;
							var x = stack[sp - 2];
							var y = stack[sp - 1];
							var r:Bool;
							if (Std.isOfType(x, Int) && Std.isOfType(y, Int)) {
								var xi:Int = x;
								var yi:Int = y;
								r = op == LOp.LT ? xi < yi : (op == LOp.GT ? xi > yi : (op == LOp.LE ? xi <= yi : xi >= yi));
							} else
								r = op == LOp.LT ? L.lt(x, y) : (op == LOp.GT ? L.lt(y, x) : (op == LOp.LE ? L.le(x, y) : L.le(y, x)));
							stack[sp - 2] = r;
							co.sp = sp - 1;
						case JMP:
							pc = a;
						case JMPN:
							var nsp = co.sp - b;
							if (co.tbc.length > 0 && co.tbc[co.tbc.length - 1] >= nsp) {
								var e = L.closeTbc(co, nsp, null);
								if (e != null)
									throw e;
							}
							co.sp = nsp;
							pc = a;
						case JMPF:
							if (LuaState.isFalse(stack[--co.sp]))
								pc = a;
						case JMPT:
							if (!LuaState.isFalse(stack[--co.sp]))
								pc = a;
						case TESTF:
							if (LuaState.isFalse(stack[co.sp - 1]))
								pc = a;
							else
								co.sp--;
						case TESTT:
							if (!LuaState.isFalse(stack[co.sp - 1]))
								pc = a;
							else
								co.sp--;
						case POP:
							co.sp--;
						case POPN:
							co.sp -= a;
						case FORPREP:
							var ra = base + a;
							if (forPrep(L, stack, ra)) {
								stack[ra + 3] = null;
								pc = b;
							}
							co.sp = ra + 4;
						case FORLOOP:
							var ra = base + a;
							var st:ForState = cast stack[ra];
							if (st.isFloat) {
								st.idx += st.step;
								if (st.step > 0 ? st.idx <= st.count : st.count <= st.idx) {
									stack[ra + 3] = new LFloat(st.idx);
									pc = b;
								}
							} else if (!st.big) {
								if (st.count > 0) {
									st.count -= 1;
									st.idx += st.step;
									stack[ra + 3] = LNum.mkIntF(st.idx);
									pc = b;
								}
							} else if (st.c64 != Int64.ofInt(0)) {
								st.c64 = st.c64 - Int64.ofInt(1);
								st.i64 = st.i64 + st.s64;
								stack[ra + 3] = LNum.mkInt(st.i64);
								pc = b;
							}
						case TFORCALL:
							var ra = base + a;
							var f = stack[ra];
							var s = stack[ra + 1];
							var ctl = stack[ra + 2];
							// Fast paths for the two iterators that dominate real workloads.
							if (f == L.nextFn && Std.isOfType(s, LTable)) {
								var r = (cast s : LTable).next(ctl);
								if (r == null) {
									for (i in 0...b)
										stack[ra + 4 + i] = null;
								} else {
									stack[ra + 4] = r[0];
									if (b > 1)
										stack[ra + 5] = r[1];
									for (i in 2...b)
										stack[ra + 4 + i] = null;
								}
								co.sp = ra + 4 + b;
							} else if (f == L.ipairsFn && LNum.isInteger(ctl)) {
								var i1 = LNum.arith(LNum.OP_ADD, ctl, 1);
								var v = (Std.isOfType(s, LTable) && (cast s : LTable).meta == null) ? (cast s : LTable).get(i1) : L.index(s, i1, null);
								if (v == null)
									stack[ra + 4] = null;
								else {
									stack[ra + 4] = i1;
									if (b > 1)
										stack[ra + 5] = v;
								}
								var lim = v == null ? 1 : 2;
								for (i in lim...b)
									stack[ra + 4 + i] = null;
								co.sp = ra + 4 + b;
							} else {
								// Generic iterator: set up an actual call frame.
								stack[ra + 4] = f;
								stack[ra + 5] = s;
								stack[ra + 6] = ctl;
								co.sp = ra + 7;
								ci.pc = pc;
								var r = L.precall(co, ra + 4, 2, b, null);
								if (r == 1)
									break;
								if (r == 2)
									return;
							}
						case TFORLOOP:
							var ra = base + a;
							var v = stack[ra + 4];
							if (v != null) {
								stack[ra + 2] = v;
								pc = b;
							}
						case CLOSURE:
							var np = p.protos[a];
							var ups:Array<Cell> = [];
							for (d in np.upvals)
								ups.push(d.inStack ? (cast stack[base + d.idx] : Cell) : cl.upvals[d.idx]);
							stack[co.sp++] = new LuaClosure(np, ups);
						case TBC:
							var ra = base + a;
							var v = stack[ra];
							if (Std.isOfType(v, Cell))
								v = (cast v : Cell).v;
							if (!LuaState.isFalse(v)) {
								if (L.getMM(v, "__close") == null)
									L.rtError(p.d1[pc - 1] + " got a non-closable value");
								co.tbc.push(ra);
							}
						case CLOSE:
							var lvl = base + a;
							if (co.tbc.length > 0 && co.tbc[co.tbc.length - 1] >= lvl) {
								var e = L.closeTbc(co, lvl, null);
								if (e != null)
									throw e;
							}
						default:
					}
				}
			} catch (ex:Dynamic) {
				var e:LuaError = Std.isOfType(ex, LuaError) ? ex : new LuaError("internal error: " + Std.string(ex), true);
				if (e.pending) {
					// First time we see this error: prefix the error location if the value is a string.
					e.pending = false;
					if (Std.isOfType(e.value, String))
						e.value = LuaState.whereCI(ci, pc - 1) + e.value;
				}
				ci.pc = pc;
				// Walk up to the nearest pcall or boundary frame to catch the error.
				var c = co.ci;
				while (c != null && !c.isPcall && !c.isBoundary)
					c = c.prev;
				if (c != null && c.isPcall) {
					var err = e;
					if (c.handler != null) {
						try {
							err = new LuaError(LuaState.first(L.call(c.handler, [e.value])));
						} catch (e2:LuaError) {
							err = e2;
						}
					}
					err = L.closeTbc(co, c.base, err);
					co.ci = c.prev;
					L.placeResults(co, c.retPos, [false, err.value], c.nres);
				} else {
					var err2 = L.closeTbc(co, c != null ? c.base : 0, e);
					if (c != null) {
						co.ci = c.prev;
						co.sp = c.retPos;
					}
					throw err2;
				}
			}
		}
	}

	/**
	 * Prepares a numeric `for` loop and stores the loop state in `stack[ra]`.
	 *
	 * Integer loops use an integer fast-path when both the initial value and the
	 * step are integers; the control variable can be tracked as a float when all
	 * relevant magnitudes fit in 2^52, and otherwise falls back to full `Int64`
	 * arithmetic. Float loops just store `idx`, `step` and `limit` directly.
	 *
	 * @param L The Lua state (for raising runtime errors).
	 * @param stack The coroutine stack.
	 * @param ra Absolute stack index of the loop's base register (base + A).
	 * @returns `true` if the loop body must be skipped (empty range).
	 */
	static function forPrep(L:LuaState, stack:Array<Dynamic>, ra:Int):Bool {
		var init = stack[ra];
		var plimit = stack[ra + 1];
		var pstep = stack[ra + 2];
		var st = new ForState();
		if (LNum.isInteger(init) && LNum.isInteger(pstep)) {
			var i0 = LNum.toI64(init);
			var s0 = LNum.toI64(pstep);
			var zero = Int64.ofInt(0);
			if (s0 == zero)
				L.rtError("'for' step is zero");
			var lim:Int64 = zero;
			var skip = false;
			var ln = LNum.toNumber(plimit);
			if (ln == null)
				L.rtError("'for' limit must be a number");
			if (LNum.isInteger(ln))
				lim = LNum.toI64(ln);
			else {
				// Non-integer limit: round toward the range (ceil for positive step, floor otherwise).
				var f = LNum.toFloat(ln);
				if (f != f)
					skip = true; // NaN -> empty range.
				else {
					var fv = s0 < zero ? LNum.fceil(f) : LNum.ffloor(f);
					if (fv >= 9223372036854775808.0) {
						if (s0 < zero)
							skip = true;
						lim = LNum.MAXINT;
					} else if (fv < -9223372036854775808.0) {
						if (s0 > zero)
							skip = true;
						lim = LNum.MININT;
					} else
						lim = LNum.f2i(fv);
				}
			}
			if (!skip)
				skip = s0 > zero ? i0 > lim : i0 < lim;
			if (skip)
				return true;
			var cnt:Int64;
			if (s0 > zero) {
				cnt = lim - i0;
				if (s0 != Int64.ofInt(1))
					cnt = LNum.udiv(cnt, s0);
			} else {
				cnt = i0 - lim;
				cnt = LNum.udiv(cnt, (-(s0 + Int64.ofInt(1))) + Int64.ofInt(1));
			}
			var fi0 = LNum.i64ToFloat(i0);
			var fl = LNum.i64ToFloat(lim);
			var fs = LNum.i64ToFloat(s0);
			var fc = LNum.i64ToFloat(cnt);
			// If everything fits in 2^52 we can count in floating point without precision loss.
			if (cnt >= zero && Math.abs(fi0) < TWO52 && Math.abs(fl) < TWO52 && Math.abs(fs) < TWO52 && fc < TWO52) {
				st.idx = fi0;
				st.step = fs;
				st.count = fc;
			} else {
				st.big = true;
				st.i64 = i0;
				st.s64 = s0;
				st.c64 = cnt;
			}
			stack[ra] = st;
			stack[ra + 3] = init;
			return false;
		}
		// Float loop: coerce everything to floats.
		var fi = LNum.toNumber(init);
		if (fi == null)
			L.rtError("'for' initial value must be a number");
		var fl = LNum.toNumber(plimit);
		if (fl == null)
			L.rtError("'for' limit must be a number");
		var fs = LNum.toNumber(pstep);
		if (fs == null)
			L.rtError("'for' step must be a number");
		var vi = LNum.toFloat(fi);
		var vl = LNum.toFloat(fl);
		var vs = LNum.toFloat(fs);
		if (vs == 0)
			L.rtError("'for' step is zero");
		if (vs > 0 ? vl < vi : vi < vl)
			return true;
		st.isFloat = true;
		st.idx = vi;
		st.step = vs;
		st.count = vl;
		stack[ra] = st;
		stack[ra + 3] = new LFloat(vi);
		return false;
	}
}
