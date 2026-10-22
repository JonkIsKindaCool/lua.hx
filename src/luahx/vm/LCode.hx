package luahx.vm;

import luahx.vm.LAst;
import luahx.vm.LObject;
import luahx.vm.LOp;
import luahx.vm.LParser;

private typedef LabelInfo = {pc:Int, nactive:Int, line:Int};
private typedef Pending = {name:String, idx:Int, nactive:Int, line:Int};

/**
 * Lexical block context used while resolving `goto`/label pairs.
 *
 * Labels declared in a block are visible to nested blocks but not vice
 * versa; unresolved `goto`s are forwarded to the parent context on exit.
 */
private class BlockCtx {
	public var labels:Map<String, LabelInfo> = new Map();
	public var pending:Array<Pending> = [];
	public var parent:BlockCtx;

	public function new(parent:BlockCtx)
		this.parent = parent;
}

/**
 * Active loop context: collects the indices of pending `break` jump
 * instructions so they can be patched when the loop's exit label is known.
 */
private class LoopCtx {
	public var breaks:Array<Int> = [];
	public var baseActive:Int;

	public function new(b:Int)
		baseActive = b;
}

/**
 * lcode.c — AST-to-bytecode compiler for the stack-based VM.
 *
 * Translates the `FuncInfo` trees produced by {@link LParser} into a
 * {@link Proto} whose instructions are stored in parallel arrays
 * (`ops`, `a`, `b`, `c`, `lines`, `d1`, `d2`).
 */
class LCode {
	var p:Proto;
	var fi:FuncInfo;
	var source:String;
	var nactive:Int = 0;
	var line:Int = 0;

	/** Deduplication map: constant key -> index in `p.consts`. */
	var consts:Map<String, Int> = new Map();

	var blk:BlockCtx = null;
	var loops:Array<LoopCtx> = [];

	function new(fi:FuncInfo, source:String) {
		this.fi = fi;
		this.source = source;
	}

	/**
	 * Compiles a parsed function prototype into bytecode.
	 *
	 * @param fi Function AST produced by the parser.
	 * @param source Chunk name used in error messages.
	 * @returns The compiled prototype.
	 */
	public static function compile(fi:FuncInfo, source:String):Proto
		return new LCode(fi, source).compileFunc();

	/**
	 * Raises a compilation error with the source chunk and line.
	 *
	 * @param msg Error message.
	 * @param ln Source line.
	 */
	function error(msg:String, ln:Int):Dynamic
		throw new LuaError(source + ":" + ln + ": " + msg);

	inline function pc():Int
		return p.ops.length;

	/**
	 * Appends one instruction to the prototype and returns its index.
	 *
	 * @param op Opcode.
	 * @param a Operand `a`.
	 * @param b Operand `b`.
	 * @param c Operand `c`.
	 * @returns The instruction index.
	 */
	function emit(op:Int, a:Int = 0, b:Int = 0, c:Int = 0):Int {
		p.ops.push(op);
		p.a.push(a);
		p.b.push(b);
		p.c.push(c);
		p.lines.push(line);
		p.d1.push(null);
		p.d2.push(null);
		return p.ops.length - 1;
	}

	/**
	 * Like {@link emit} but also records the descriptive operands `d1`/`d2`
	 * (used to build error messages for `__index`/`__newindex`/etc.).
	 *
	 * @param op Opcode.
	 * @param a Operand `a`.
	 * @param b Operand `b`.
	 * @param c Operand `c`.
	 * @param d1 First operand description.
	 * @param d2 Second operand description.
	 * @returns The instruction index.
	 */
	function emitD(op:Int, a:Int, b:Int, c:Int, d1:String, d2:String = null):Int {
		var i = emit(op, a, b, c);
		p.d1[i] = d1;
		p.d2[i] = d2;
		return i;
	}

	/**
	 * Returns the index of `v` in the constant pool, inserting it if absent.
	 * Numeric constants are keyed by their exact bit pattern so equal values
	 * always share a slot.
	 *
	 * @param v Constant value.
	 * @returns The constant index.
	 */
	function constIdx(v:Dynamic):Int {
		var key:String;
		if (Std.isOfType(v, String))
			key = "s" + v;
		else if (Std.isOfType(v, Int))
			key = "i" + v;
		else if (Std.isOfType(v, LFloat))
			key = "f" + haxe.Int64.toStr(LNum.encodeIEEE((cast v : LFloat).v, 11, 52));
		else if (Std.isOfType(v, LInt64))
			key = "I" + haxe.Int64.toStr((cast v : LInt64).v);
		else
			key = null;
		if (key != null) {
			var i = consts.get(key);
			if (i != null)
				return i;
			p.consts.push(v);
			consts.set(key, p.consts.length - 1);
			return p.consts.length - 1;
		}
		p.consts.push(v);
		return p.consts.length - 1;
	}

	/**
	 * Builds a human-readable description of an expression for runtime
	 * error messages (e.g. `local 'x'`, `global 'print'`, `field 'y'`).
	 *
	 * @param e Expression to describe.
	 * @returns The description, or `null` if it cannot be described.
	 */
	function descOf(e:Expr):String {
		switch (e) {
			case ELocal(v):
				return "local '" + v.name + "'";
			case EUpval(_, n):
				return "upvalue '" + n + "'";
			case EIndex(obj, EConst(k), _):
				if (!Std.isOfType(k, String))
					return null;
				var isEnv = switch (obj) {
					case ELocal(v): v.name == "_ENV";
					case EUpval(_, n): n == "_ENV";
					default: false;
				}
				return (isEnv ? "global '" : "field '") + k + "'";
			case EMethCall(_, n, _, _):
				return "method '" + n + "'";
			case EConst(k):
				if (Std.isOfType(k, String))
					return "constant '" + k + "'";
				return null;
			default:
				return null;
		}
	}

	/**
	 * Compiles the function body described by `fi`, emitting a final
	 * `RETURN`. Captured parameters are wrapped in cells at the entry.
	 *
	 * @returns The compiled prototype.
	 */
	function compileFunc():Proto {
		p = new Proto();
		p.source = source;
		p.nparams = fi.nparams;
		p.isVararg = fi.isVararg;
		p.upvals = fi.upvals;
		p.lineDefined = fi.line;
		p.lastLine = fi.lastLine;
		line = fi.line;
		nactive = fi.nparams;
		for (v in fi.params)
			if (v.captured)
				emit(LOp.NEWCELL, v.slot);
		compileBlock(fi.body, false);
		line = fi.lastLine;
		emit(LOp.RETURN, 0, 0, 0);
		return p;
	}

	/**
	 * Searches the current block and its ancestors for a defined label.
	 *
	 * @param name Label name.
	 * @returns The label info, or `null` if not yet defined.
	 */
	function lookupLabel(name:String):LabelInfo {
		var c = blk;
		while (c != null) {
			var l = c.labels.get(name);
			if (l != null)
				return l;
			c = c.parent;
		}
		return null;
	}

	/**
	 * Defines a label at the current program counter and resolves any
	 * pending `goto`s targeting it.
	 *
	 * @param name Label name.
	 * @param ln Source line.
	 * @param act Number of active locals at the label's position.
	 */
	function defineLabel(name:String, ln:Int, act:Int):Void {
		var prev = lookupLabel(name);
		if (prev != null)
			error("label '" + name + "' already defined on line " + prev.line, ln);
		var info = {pc: pc(), nactive: act, line: ln};
		blk.labels.set(name, info);
		var rest = [];
		for (g in blk.pending) {
			if (g.name == name) {
				if (info.nactive > g.nactive)
					error("<goto " + name + "> at line " + g.line + " jumps into the scope of a local", g.line);
				p.a[g.idx] = info.pc;
				p.b[g.idx] = g.nactive - info.nactive;
			} else
				rest.push(g);
		}
		blk.pending = rest;
	}

	/**
	 * Compiles a lexical block, tracking active locals and label scoping.
	 *
	 * @param b Block to compile.
	 * @param popAtEnd Whether to emit `CLOSE`/`POPN` at the end (used for
	 *                 nested blocks that discard their locals).
	 * @param beforeEnd Optional callback invoked just before the block's
	 *                  cleanup code is emitted (used by `repeat` to place
	 *                  the `until` condition inside the loop's scope).
	 */
	function compileBlock(b:Block, popAtEnd:Bool, beforeEnd:Void->Void = null):Void {
		var start = nactive;
		var ctx = new BlockCtx(blk);
		blk = ctx;
		var endLabels:Array<{n:String, l:Int}> = [];
		// Labels that appear at the very end of the block are emitted after
		// the loop/block epilogue, so they see the outer scope.
		for (s in b.stmts) {
			switch (s) {
				case SLabel(n, l, true):
					endLabels.push({n: n, l: l});
				default:
					stmt(s);
			}
		}
		if (beforeEnd != null)
			beforeEnd();
		if (popAtEnd) {
			if (b.hasClose)
				emit(LOp.CLOSE, start);
			if (nactive - start > 0)
				emit(LOp.POPN, nactive - start);
		}
		nactive = start;
		for (l in endLabels)
			defineLabel(l.n, l.l, start);
		blk = ctx.parent;
		if (ctx.pending.length > 0) {
			if (blk == null) {
				var g = ctx.pending[0];
				error("no visible label '" + g.name + "' for goto at line " + g.line, g.line);
			}
			for (g in ctx.pending)
				blk.pending.push(g);
		}
	}

	/**
	 * Compiles a single statement, dispatching on its AST variant.
	 *
	 * @param s Statement to compile.
	 */
	function stmt(s:Stmt):Void {
		switch (s) {
			case SLocal(vars, exprs, ln):
				line = ln;
				exprListAdjust(exprs, vars.length);
				nactive += vars.length;
				for (v in vars) {
					if (v.captured)
						emit(LOp.NEWCELL, v.slot);
					if (v.attr == 2)
						emitD(LOp.TBC, v.slot, 0, 0, "variable '" + v.name + "'");
				}
			case SLocalFunc(v, f, ln):
				line = ln;
				// Pre-declare the local as nil so the body can refer to itself.
				emit(LOp.NIL);
				nactive++;
				if (v.captured)
					emit(LOp.NEWCELL, v.slot);
				closure(f);
				emit(v.captured ? LOp.SETCELL : LOp.SETLOC, v.slot);
			case SAssign(targets, exprs, ln):
				line = ln;
				assign(targets, exprs);
			case SCall(e, ln):
				line = ln;
				call(e, 0);
			case SDo(b):
				compileBlock(b, true);
			case SWhile(cond, b, ln):
				line = ln;
				var start = pc();
				expr(cond);
				var jf = emit(LOp.JMPF);
				var lc = new LoopCtx(nactive);
				loops.push(lc);
				compileBlock(b, true);
				loops.pop();
				emit(LOp.JMP, start);
				p.a[jf] = pc();
				for (j in lc.breaks)
					p.a[j] = pc();
			case SRepeat(b, cond, ln):
				line = ln;
				var start = pc();
				var lc = new LoopCtx(nactive);
				loops.push(lc);
				var base = nactive;
				// The condition is emitted inside the loop body's scope so it
				// can refer to locals declared in the body.
				compileBlock(b, true, function() {
					expr(cond);
					var jt = emit(LOp.JMPT);
					var n = nactive - base;
					if (b.hasClose)
						emit(LOp.CLOSE, base);
					if (n > 0)
						emit(LOp.POPN, n);
					emit(LOp.JMP, start);
					p.a[jt] = pc();
				});
				loops.pop();
				for (j in lc.breaks)
					p.a[j] = pc();
			case SIf(conds, blocks, els, ln):
				line = ln;
				var ends = [];
				for (i in 0...conds.length) {
					expr(conds[i]);
					var jf = emit(LOp.JMPF);
					compileBlock(blocks[i], true);
					if (i < conds.length - 1 || els != null)
						ends.push(emit(LOp.JMP));
					p.a[jf] = pc();
				}
				if (els != null)
					compileBlock(els, true);
				for (j in ends)
					p.a[j] = pc();
			case SNumFor(v, init, limit, step, b, ln):
				line = ln;
				var base = nactive;
				expr(init);
				expr(limit);
				if (step != null)
					expr(step);
				else
					emit(LOp.CONST, constIdx(1));
				nactive += 3;
				var fp = emit(LOp.FORPREP, base);
				nactive++;
				var body = pc();
				if (v.captured)
					emit(LOp.NEWCELL, v.slot);
				var lc = new LoopCtx(base);
				loops.push(lc);
				compileBlock(b, true);
				loops.pop();
				line = ln;
				emit(LOp.FORLOOP, base, body);
				p.b[fp] = pc();
				emit(LOp.POPN, 4);
				nactive = base;
				for (j in lc.breaks)
					p.a[j] = pc();
			case SGenFor(vars, exprs, b, ln):
				line = ln;
				var base = nactive;
				exprListAdjust(exprs, 4);
				nactive += 4;
				// The iterator state is a to-be-closed value so `__close` runs on exit.
				emitD(LOp.TBC, base + 3, 1, 0, "variable '(for state)'");
				var jmp = emit(LOp.JMP);
				var body = pc();
				nactive += vars.length;
				for (v in vars)
					if (v.captured)
						emit(LOp.NEWCELL, v.slot);
				var lc = new LoopCtx(base);
				loops.push(lc);
				compileBlock(b, true);
				loops.pop();
				p.a[jmp] = pc();
				line = ln;
				emit(LOp.TFORCALL, base, vars.length);
				emit(LOp.TFORLOOP, base, body);
				emit(LOp.CLOSE, base);
				emit(LOp.POPN, 4 + vars.length);
				nactive = base;
				for (j in lc.breaks)
					p.a[j] = pc();
			case SReturn(exprs, ln):
				line = ln;
				// Single-call returns are emitted as TAILCALL.
				if (exprs.length == 1) {
					switch (exprs[0]) {
						case ECall(_, _, _), EMethCall(_, _, _, _):
							call(exprs[0], -1, true);
							emit(LOp.RETURN, 0, 0, 1);
							return;
						default:
					}
				}
				var r = exprListOpen(exprs);
				emit(LOp.RETURN, r.fixed, 0, r.open ? 1 : 0);
			case SBreak(ln):
				line = ln;
				if (loops.length == 0)
					error("break outside a loop at line " + ln, ln);
				var lc = loops[loops.length - 1];
				// JMPN drops the loop's locals before jumping; the target is patched later.
				var j = emit(LOp.JMPN, 0, nactive - lc.baseActive);
				lc.breaks.push(j);
			case SGoto(name, ln):
				line = ln;
				var l = lookupLabel(name);
				if (l != null)
					emit(LOp.JMPN, l.pc, nactive - l.nactive);
				else {
					var j = emit(LOp.JMPN, 0, 0);
					blk.pending.push({
						name: name,
						idx: j,
						nactive: nactive,
						line: ln
					});
				}
			case SLabel(name, ln, _):
				defineLabel(name, ln, nactive);
		}
	}

	/**
	 * Compiles an assignment. Single-target assignments are optimized to a
	 * direct store; multi-target ones pre-evaluate indexed targets and use
	 * `SETTAB_D` to reach them relative to the top of the stack.
	 *
	 * @param targets Destination expressions.
	 * @param exprs Source expressions (adjusted to `targets.length` values).
	 */
	function assign(targets:Array<Expr>, exprs:Array<Expr>):Void {
		if (targets.length == 1 && exprs.length == 1) {
			switch (targets[0]) {
				case ELocal(v):
					expr(exprs[0]);
					emit(v.captured ? LOp.SETCELL : LOp.SETLOC, v.slot);
				case EUpval(i, _):
					expr(exprs[0]);
					emit(LOp.SETUP, i);
				case EIndex(obj, key, ln):
					expr(obj);
					switch (key) {
						case EConst(k) if (Std.isOfType(k, String)):
							expr(exprs[0]);
							line = ln;
							emitD(LOp.SETFIELD, constIdx(k), 0, 0, descOf(obj));
						default:
							expr(key);
							expr(exprs[0]);
							line = ln;
							emitD(LOp.SETTABLE, 0, 0, 0, descOf(obj));
					}
				default:
			}
			return;
		}
		// Pre-evaluate indexed targets so `t[i] = ...` sees the original `t`/`i`
		// even if a later assignment mutates them.
		var nIdx = 0;
		for (t in targets) {
			switch (t) {
				case EIndex(obj, key, _):
					expr(obj);
					expr(key);
					nIdx++;
				default:
			}
		}
		exprListAdjust(exprs, targets.length);
		var later = nIdx;
		var i = targets.length - 1;
		while (i >= 0) {
			switch (targets[i]) {
				case ELocal(v):
					emit(v.captured ? LOp.SETCELL : LOp.SETLOC, v.slot);
				case EUpval(u, _):
					emit(LOp.SETUP, u);
				case EIndex(obj, _, ln):
					later--;
					line = ln;
					emitD(LOp.SETTAB_D, i + 2 * (nIdx - 1 - later), 0, 0, descOf(obj));
				default:
			}
			i--;
		}
		if (nIdx > 0)
			emit(LOp.POPN, 2 * nIdx);
	}

	/**
	 * Returns `true` for expressions that can produce a variable number of
	 * values (calls and `...`).
	 *
	 * @param e Expression to test.
	 * @returns Whether the expression is multi-valued.
	 */
	function isMulti(e:Expr):Bool {
		switch (e) {
			case ECall(_, _, _), EMethCall(_, _, _, _), EVararg:
				return true;
			default:
				return false;
		}
	}

	/**
	 * Compiles a nested function and emits the `CLOSURE` instruction that
	 * materializes it at runtime.
	 *
	 * @param f Function AST.
	 */
	function closure(f:FuncInfo):Void {
		var child = new LCode(f, source).compileFunc();
		p.protos.push(child);
		emit(LOp.CLOSURE, p.protos.length - 1);
	}

	/**
	 * Compiles a call expression.
	 *
	 * @param e Expression (must be `ECall` or `EMethCall`).
	 * @param nres Number of expected results (`-1` = all).
	 * @param tail Whether to emit `TAILCALL` instead of `CALL`.
	 */
	function call(e:Expr, nres:Int, tail:Bool = false):Void {
		switch (e) {
			case ECall(fn, args, ln):
				expr(fn);
				var r = exprListOpen(args);
				line = ln;
				emitD(tail ? LOp.TAILCALL : LOp.CALL, r.fixed, nres, r.open ? 1 : 0, descOf(fn));
			case EMethCall(obj, name, args, ln):
				expr(obj);
				line = ln;
				emitD(LOp.SELF, constIdx(name), 0, 0, descOf(obj));
				var r = exprListOpen(args);
				line = ln;
				emitD(tail ? LOp.TAILCALL : LOp.CALL, r.fixed + 1, nres, r.open ? 1 : 0, "method '" + name + "'");
			default:
		}
	}

	/**
	 * Compiles a comma-separated expression list where the last expression
	 * may contribute multiple values.
	 *
	 * @param es Expressions to compile.
	 * @returns The number of fixed values plus whether the list is open.
	 */
	function exprListOpen(es:Array<Expr>):{fixed:Int, open:Bool} {
		var n = es.length;
		if (n == 0)
			return {fixed: 0, open: false};
		for (i in 0...n - 1)
			expr(es[i]);
		var last = es[n - 1];
		if (isMulti(last)) {
			multi(last, -1);
			return {fixed: n - 1, open: true};
		}
		expr(last);
		return {fixed: n, open: false};
	}

	/**
	 * Emits a multi-valued expression, requesting `nres` values (`-1` = all).
	 *
	 * @param e Expression to compile.
	 * @param nres Number of results to request.
	 */
	function multi(e:Expr, nres:Int):Void {
		switch (e) {
			case EVararg:
				emit(LOp.VARARG, 0, nres);
			default:
				call(e, nres);
		}
	}

	/**
	 * Compiles an expression list producing exactly `n` values, filling or
	 * truncating the tail as needed.
	 *
	 * @param es Expressions to compile.
	 * @param n Target number of values.
	 */
	function exprListAdjust(es:Array<Expr>, n:Int):Void {
		if (es.length == 0) {
			pushNils(n);
			return;
		}
		for (i in 0...es.length) {
			var e = es[i];
			var last = i == es.length - 1;
			if (!last) {
				if (i < n)
					expr(e);
				else
					discard(e);
			} else {
				var remaining = n - i;
				if (remaining <= 0)
					discard(e);
				else if (isMulti(e))
					multi(e, remaining);
				else {
					expr(e);
					pushNils(remaining - 1);
				}
			}
		}
	}

	/**
	 * Compiles `e` and discards its value(s).
	 *
	 * @param e Expression to discard.
	 */
	function discard(e:Expr):Void {
		if (isMulti(e))
			multi(e, 0);
		else {
			expr(e);
			emit(LOp.POP);
		}
	}

	/**
	 * Pushes `n` nils onto the stack using the most compact form.
	 *
	 * @param n Number of nils.
	 */
	function pushNils(n:Int):Void {
		if (n == 1)
			emit(LOp.NIL);
		else if (n > 1)
			emit(LOp.NILN, n);
	}

	/**
	 * Flattens a right-associated `..` chain into a linear operand list so
	 * the VM can concatenate all operands with a single `CONCAT`.
	 *
	 * @param e Expression to flatten.
	 * @param out Destination array (appended to).
	 */
	function concatOperands(e:Expr, out:Array<Expr>):Void {
		switch (e) {
			case EBin(LParser.OP_CONCAT, a, b, _):
				out.push(a);
				concatOperands(b, out);
			default:
				out.push(e);
		}
	}

	/**
	 * Compiles an expression, leaving exactly one value on the stack.
	 *
	 * @param e Expression to compile.
	 */
	function expr(e:Expr):Void {
		switch (e) {
			case ENil:
				emit(LOp.NIL);
			case ETrue:
				emit(LOp.TRUE);
			case EFalse:
				emit(LOp.FALSE);
			case EConst(v):
				emit(LOp.CONST, constIdx(v));
			case EVararg:
				emit(LOp.VARARG, 0, 1);
			case ELocal(v):
				emit(v.captured ? LOp.GETCELL : LOp.GETLOC, v.slot);
			case EUpval(i, _):
				emit(LOp.GETUP, i);
			case EIndex(obj, key, ln):
				expr(obj);
				switch (key) {
					case EConst(k) if (Std.isOfType(k, String)):
						line = ln;
						emitD(LOp.GETFIELD, constIdx(k), 0, 0, descOf(obj));
					default:
						expr(key);
						line = ln;
						emitD(LOp.GETTABLE, 0, 0, 0, descOf(obj));
				}
			case ECall(_, _, _), EMethCall(_, _, _, _):
				call(e, 1);
			case EFunc(f):
				closure(f);
			case EParen(x):
				expr(x);
			case EAnd(a, b):
				expr(a);
				var j = emit(LOp.TESTF);
				expr(b);
				p.a[j] = pc();
			case EOr(a, b):
				expr(a);
				var j = emit(LOp.TESTT);
				expr(b);
				p.a[j] = pc();
			case EUn(op, a, ln):
				expr(a);
				line = ln;
				switch (op) {
					case LParser.OP_NOT: emit(LOp.NOT);
					case LParser.OP_LEN: emitD(LOp.LEN, 0, 0, 0, descOf(a));
					default: emitD(LOp.ADD + op, 0, 0, 0, descOf(a));
				}
			case EBin(op, a, b, ln):
				if (op == LParser.OP_CONCAT) {
					var ops = [];
					concatOperands(e, ops);
					for (x in ops)
						expr(x);
					line = ln;
					emit(LOp.CONCAT, ops.length);
					return;
				}
				expr(a);
				expr(b);
				line = ln;
				var opc = switch (op) {
					case LParser.OP_EQ: LOp.EQ;
					case LParser.OP_NE: LOp.NE;
					case LParser.OP_LT: LOp.LT;
					case LParser.OP_LE: LOp.LE;
					case LParser.OP_GT: LOp.GT;
					case LParser.OP_GE: LOp.GE;
					default: LOp.ADD + op;
				}
				emitD(opc, 0, 0, 0, descOf(a), descOf(b));
			case ETable(items, ln):
				table(items, ln);
		}
	}

	/**
	 * Compiles a table constructor, using `SETLIST` for positional entries
	 * in batches and `INITFIELD`/`INITTABLE` for named entries.
	 *
	 * @param items Constructor items (positional or named).
	 * @param ln Source line.
	 */
	function table(items:Array<TItem>, ln:Int):Void {
		line = ln;
		var narr = 0;
		for (it in items)
			if (it.match(Pos(_)))
				narr++;
		emit(LOp.NEWTABLE, narr, items.length - narr);
		var pending = 0;
		var nextIdx = 1;
		for (i in 0...items.length) {
			switch (items[i]) {
				case Pos(e):
					if (i == items.length - 1 && isMulti(e)) {
						// The trailing multi-valued expression feeds SETLIST directly.
						multi(e, -1);
						emit(LOp.SETLIST, nextIdx, pending, 1);
						pending = 0;
					} else {
						expr(e);
						pending++;
						// Batch in chunks of 50 to bound immediate operand sizes.
						if (pending == 50) {
							emit(LOp.SETLIST, nextIdx, pending, 0);
							nextIdx += pending;
							pending = 0;
						}
					}
				case Named(k, v):
					switch (k) {
						case EConst(kc) if (Std.isOfType(kc, String)):
							expr(v);
							emit(LOp.INITFIELD, constIdx(kc), pending);
						default:
							expr(k);
							expr(v);
							emit(LOp.INITTABLE, 0, pending);
					}
			}
		}
		if (pending > 0)
			emit(LOp.SETLIST, nextIdx, pending, 0);
	}
}
