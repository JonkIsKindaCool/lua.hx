package luahx.vm;

import luahx.vm.LAst;
import luahx.vm.LLex;
import luahx.vm.LObject;

private typedef Scope = {nactive:Int, ng:Int, strict:Bool};
private typedef GName = {name:String, isConst:Bool};

/**
 * lparser.c — Recursive-descent parser for Lua 5.5.
 *
 * Produces an AST whose variable references have already been resolved to
 * locals or upvalues (`ELocal` / `EUpval`), leaving `_ENV` indexing only for
 * identifiers that do not correspond to any local/upvalue in scope.
 */
class LParser {
	public static inline var OP_CONCAT = 20;
	public static inline var OP_EQ = 21;
	public static inline var OP_NE = 22;
	public static inline var OP_LT = 23;
	public static inline var OP_LE = 24;
	public static inline var OP_GT = 25;
	public static inline var OP_GE = 26;
	public static inline var OP_NOT = 30;
	public static inline var OP_LEN = 31;
	static inline var UNARY_PRIORITY = 12;

	var ls:LLex;
	var fs:FuncInfo;
	var gnames:Array<GName> = [];
	var gstrict:Bool = false;

	function new(ls:LLex) {
		this.ls = ls;
	}

	/**
	 * Parses a complete chunk into a main function prototype. The main
	 * function is variadic and captures `_ENV` as its sole upvalue.
	 *
	 * @param src Source code.
	 * @param chunk Chunk name (used in error messages).
	 * @returns The main `FuncInfo`.
	 */
	public static function parse(src:String, chunk:String):FuncInfo {
		var ls = new LLex(src, chunk);
		var p = new LParser(ls);
		var main = new FuncInfo(null);
		main.isVararg = true;
		main.upvals.push(new UpvalDesc("_ENV", true, 0));
		main.upvalVars.push(null);
		p.fs = main;
		ls.next();
		main.body = p.block();
		if (ls.tk != LLex.TK_EOS)
			ls.errorToken("<eof> expected");
		main.lastLine = ls.line;
		return main;
	}

	/**
	 * Ensures the current token is `t`.
	 *
	 * @param t Expected token kind.
	 */
	function check(t:Int):Void {
		if (ls.tk != t)
			ls.errorToken(LLex.tok2str(t) + " expected");
	}

	/**
	 * If the current token is `t`, advances and returns `true`.
	 *
	 * @param t Token kind to match.
	 * @returns Whether the token was consumed.
	 */
	function testNext(t:Int):Bool {
		if (ls.tk == t) {
			ls.next();
			return true;
		}
		return false;
	}

	/**
	 * Consumes the current token, requiring it to be `t`.
	 *
	 * @param t Expected token kind.
	 */
	function checkNext(t:Int):Void {
		check(t);
		ls.next();
	}

	/**
	 * Consumes `what`, reporting a "to close `who`" error if it is missing.
	 *
	 * @param what Token that must be matched (e.g. `end`).
	 * @param who Token that opened the construct (e.g. `if`).
	 * @param where Line where `who` appeared.
	 */
	function checkMatch(what:Int, who:Int, where:Int):Void {
		if (!testNext(what)) {
			if (where == ls.line)
				ls.errorToken(LLex.tok2str(what) + " expected");
			else
				ls.errorToken(LLex.tok2str(what) + " expected (to close " + LLex.tok2str(who) + " at line " + where + ")");
		}
	}

	/**
	 * Reads the current token as a name and advances.
	 *
	 * @returns The identifier text.
	 */
	function strCheckName():String {
		check(LLex.TK_NAME);
		var s = ls.sv;
		ls.next();
		return s;
	}

	/**
	 * Raises a syntax error at the current lexer position.
	 *
	 * @param msg Error message.
	 */
	function semError(msg:String):Dynamic
		return ls.error(msg);

	/**
	 * Captures the current lexical scope state (active locals, declared
	 * globals, strictness) so it can be restored by {@link leaveScope}.
	 *
	 * @returns The saved scope.
	 */
	function enterScope():Scope
		return {nactive: fs.actives.length, ng: gnames.length, strict: gstrict};

	/**
	 * Restores a previously captured scope, dropping locals and globals
	 * declared inside it.
	 *
	 * @param s Previously saved scope.
	 */
	function leaveScope(s:Scope):Void {
		fs.actives.splice(s.nactive, fs.actives.length - s.nactive);
		gnames.splice(s.ng, gnames.length - s.ng);
		gstrict = s.strict;
	}

	/**
	 * Declares a new local in the current function.
	 *
	 * @param name Identifier.
	 * @param attr Variable attribute (`0` none, `1` const, `2` close).
	 * @returns The new `VarInfo`.
	 */
	function newLocal(name:String, attr:Int = 0):VarInfo {
		var v = new VarInfo(name, fs.actives.length, attr);
		fs.actives.push(v);
		return v;
	}

	/**
	 * Declares a hidden (compiler-internal) local, used for `for` state slots.
	 *
	 * @param name Internal name (never user-visible).
	 * @returns The new `VarInfo`.
	 */
	function hiddenLocal(name:String):VarInfo {
		var v = newLocal(name);
		v.hidden = true;
		return v;
	}

	/**
	 * Searches `f`'s active locals for `name`, ignoring hidden locals.
	 *
	 * @param f Function to search.
	 * @param name Identifier.
	 * @returns The matching `VarInfo`, or `null`.
	 */
	static function findLocal(f:FuncInfo, name:String):VarInfo {
		var i = f.actives.length - 1;
		while (i >= 0) {
			var v = f.actives[i];
			if (!v.hidden && v.name == name)
				return v;
			i--;
		}
		return null;
	}

	/**
	 * Resolves `name` as an upvalue of `f`, walking up through parent
	 * functions as needed and marking captured locals. Returns the upvalue
	 * index in `f`, or `-1` if not found.
	 *
	 * @param f Function whose upvalue list is being extended.
	 * @param name Identifier.
	 * @returns Upvalue index within `f`, or `-1`.
	 */
	static function findUpval(f:FuncInfo, name:String):Int {
		for (i in 0...f.upvals.length)
			if (f.upvals[i].name == name)
				return i;
		if (f.parent == null)
			return -1;
		var v = findLocal(f.parent, name);
		if (v != null) {
			v.captured = true;
			f.upvals.push(new UpvalDesc(name, true, v.slot));
			f.upvalVars.push(v);
			return f.upvals.length - 1;
		}
		var idx = findUpval(f.parent, name);
		if (idx < 0)
			return -1;
		f.upvals.push(new UpvalDesc(name, false, idx));
		f.upvalVars.push(f.parent.upvalVars[idx]);
		return f.upvals.length - 1;
	}

	/**
	 * Resolves a name to a local or upvalue reference, or `null` if the name
	 * is not bound in the current function's lexical environment.
	 *
	 * @param name Identifier.
	 * @returns A local/upvalue expression, or `null`.
	 */
	function resolveName(name:String):Expr {
		var v = findLocal(fs, name);
		if (v != null)
			return ELocal(v);
		var u = findUpval(fs, name);
		if (u >= 0)
			return EUpval(u, name);
		return null;
	}

	/**
	 * Checks whether `name` is declared as a global in any currently active
	 * `global` block.
	 *
	 * @param name Identifier.
	 * @returns `true` if the name is declared.
	 */
	function isDeclaredGlobal(name:String):Bool {
		var i = gnames.length - 1;
		while (i >= 0) {
			if (gnames[i].name == name)
				return true;
			i--;
		}
		return false;
	}

	/**
	 * Resolves a single identifier as an expression. Locals and upvalues
	 * resolve directly; undeclared names become `_ENV.name` (subject to the
	 * `global` strictness mode).
	 *
	 * @param name Identifier.
	 * @returns The resulting expression.
	 */
	function singlevar(name:String):Expr {
		var e = resolveName(name);
		if (e != null)
			return e;
		if (gstrict && !isDeclaredGlobal(name))
			semError("variable '" + name + "' not declared");
		return EIndex(resolveName("_ENV"), EConst(name), ls.line);
	}

	/**
	 * Returns `true` if the current token terminates a block.
	 *
	 * @param withUntil Whether `until` also terminates the block.
	 * @returns Whether the token is a block-following token.
	 */
	function blockFollow(withUntil:Bool):Bool {
		switch (ls.tk) {
			case LLex.TK_ELSE, LLex.TK_ELSEIF, LLex.TK_END, LLex.TK_EOS:
				return true;
			case LLex.TK_UNTIL:
				return withUntil;
			default:
				return false;
		}
	}

	/**
	 * Parses statements up to the end of the block. Does not open a new
	 * scope (the caller is responsible for that). Trailing labels are marked
	 * as "last", which the code generator uses to omit useless jumps.
	 *
	 * @param b Block being filled.
	 */
	function statList(b:Block):Void {
		var start = fs.actives.length;
		while (!blockFollow(true)) {
			if (ls.tk == LLex.TK_RETURN) {
				b.stmts.push(retStat());
				break;
			}
			var s = statement(b);
			if (s != null)
				b.stmts.push(s);
		}
		// Mark labels that end the block as "last".
		var i = b.stmts.length - 1;
		while (i >= 0) {
			switch (b.stmts[i]) {
				case SLabel(n, l, _):
					b.stmts[i] = SLabel(n, l, true);
				default:
					break;
			}
			i--;
		}
	}

	/**
	 * Parses a lexical block, opening and closing its scope automatically.
	 *
	 * @returns The new block.
	 */
	function block():Block {
		var sc = enterScope();
		var b = new Block();
		statList(b);
		b.nlocals = fs.actives.length - sc.nactive;
		leaveScope(sc);
		return b;
	}

	/**
	 * Parses a single statement, dispatching on the current token.
	 *
	 * @param cur Enclosing block (used to flag `to-be-closed` locals).
	 * @returns The parsed statement, or `null` for empty statements.
	 */
	function statement(cur:Block):Stmt {
		var line = ls.line;
		switch (ls.tk) {
			case 59: // ;
				ls.next();
				return null;
			case LLex.TK_IF:
				return ifStat(line);
			case LLex.TK_WHILE:
				ls.next();
				var cond = expr();
				checkNext(LLex.TK_DO);
				var b = block();
				checkMatch(LLex.TK_END, LLex.TK_WHILE, line);
				return SWhile(cond, b, line);
			case LLex.TK_DO:
				ls.next();
				var b = block();
				checkMatch(LLex.TK_END, LLex.TK_DO, line);
				return SDo(b);
			case LLex.TK_FOR:
				return forStat(line);
			case LLex.TK_REPEAT:
				ls.next();
				// The scope of `repeat` extends over the `until` condition.
				var sc = enterScope();
				var b = new Block();
				statList(b);
				checkMatch(LLex.TK_UNTIL, LLex.TK_REPEAT, line);
				var cond = expr();
				b.nlocals = fs.actives.length - sc.nactive;
				leaveScope(sc);
				return SRepeat(b, cond, line);
			case LLex.TK_FUNCTION:
				return funcStat(line);
			case LLex.TK_LOCAL:
				ls.next();
				if (testNext(LLex.TK_FUNCTION))
					return localFunc(line);
				return localStat(cur, line);
			case LLex.TK_GLOBAL:
				return globalStat(line);
			case LLex.TK_DBCOLON:
				ls.next();
				var name = strCheckName();
				checkNext(LLex.TK_DBCOLON);
				return SLabel(name, line, false);
			case LLex.TK_RETURN:
				return retStat();
			case LLex.TK_BREAK:
				ls.next();
				return SBreak(line);
			case LLex.TK_GOTO:
				ls.next();
				return SGoto(strCheckName(), line);
			default:
				return exprStat(line);
		}
	}

	/**
	 * Parses an `if` / `elseif` / `else` chain.
	 *
	 * @param line Line of the `if` keyword.
	 * @returns The parsed `SIf` statement.
	 */
	function ifStat(line:Int):Stmt {
		var conds = [];
		var blocks = [];
		var els:Block = null;
		ls.next();
		conds.push(expr());
		checkNext(LLex.TK_THEN);
		blocks.push(block());
		while (true) {
			if (ls.tk == LLex.TK_ELSEIF) {
				ls.next();
				conds.push(expr());
				checkNext(LLex.TK_THEN);
				blocks.push(block());
			} else if (ls.tk == LLex.TK_ELSE) {
				ls.next();
				els = block();
				break;
			} else
				break;
		}
		checkMatch(LLex.TK_END, LLex.TK_IF, line);
		return SIf(conds, blocks, els, line);
	}

	/**
	 * Parses a numeric or generic `for` loop.
	 *
	 * Numeric loops reserve three hidden slots for the `for` state object,
	 * limit and step; generic loops reserve four (state + the three iterator
	 * values used by the VM).
	 *
	 * @param line Line of the `for` keyword.
	 * @returns The parsed loop statement.
	 */
	function forStat(line:Int):Stmt {
		ls.next();
		var n1 = strCheckName();
		if (ls.tk == 61) { // `=`, numeric loop
			ls.next();
			var init = expr();
			checkNext(44);
			var limit = expr();
			var step:Expr = null;
			if (testNext(44))
				step = expr();
			checkNext(LLex.TK_DO);
			var sc = enterScope();
			hiddenLocal("(for state)");
			hiddenLocal("(for state)");
			hiddenLocal("(for state)");
			var v = newLocal(n1, 1);
			var b = block();
			leaveScope(sc);
			checkMatch(LLex.TK_END, LLex.TK_FOR, line);
			return SNumFor(v, init, limit, step, b, line);
		}
		var names = [n1];
		while (testNext(44))
			names.push(strCheckName());
		checkNext(LLex.TK_IN);
		var exprs = exprList();
		checkNext(LLex.TK_DO);
		var sc = enterScope();
		hiddenLocal("(for state)");
		hiddenLocal("(for state)");
		hiddenLocal("(for state)");
		hiddenLocal("(for state)");
		var vars = [];
		for (i in 0...names.length)
			vars.push(newLocal(names[i], i == 0 ? 1 : 0));
		var b = block();
		leaveScope(sc);
		checkMatch(LLex.TK_END, LLex.TK_FOR, line);
		return SGenFor(vars, exprs, b, line);
	}

	/**
	 * Parses a `function name(...) ... end` statement, including `a.b.c` and
	 * `a:b` method forms.
	 *
	 * @param line Line of the `function` keyword.
	 * @returns The assignment statement.
	 */
	function funcStat(line:Int):Stmt {
		ls.next();
		var nline = ls.line;
		var name = strCheckName();
		var target = singlevar(name);
		var isMethod = false;
		var fullName = name;
		while (ls.tk == 46 || ls.tk == 58) {
			var colon = ls.tk == 58;
			ls.next();
			var key = strCheckName();
			target = EIndex(target, EConst(key), nline);
			fullName += (colon ? ":" : ".") + key;
			if (colon) {
				isMethod = true;
				break;
			}
		}
		checkAssignable(target);
		var f = funcBody(isMethod, line);
		return SAssign([target], [EFunc(f)], line);
	}

	/**
	 * Parses `local function name(...) ... end`. The local is declared
	 * before the body so the function can refer to itself recursively.
	 *
	 * @param line Line of the `local` keyword.
	 * @returns The parsed statement.
	 */
	function localFunc(line:Int):Stmt {
		var name = strCheckName();
		var v = newLocal(name);
		var f = funcBody(false, line);
		return SLocalFunc(v, f, line);
	}

	/**
	 * Parses an optional `<attrib>` after a local/global name.
	 *
	 * @returns `0` for none, `1` for `<const>`, `2` for `<close>`.
	 */
	function getAttr():Int {
		if (testNext(60)) { // `<`
			var a = strCheckName();
			checkNext(62); // `>`
			if (a == "const")
				return 1;
			if (a == "close")
				return 2;
			return cast semError("unknown attribute '" + a + "'");
		}
		return 0;
	}

	/**
	 * Parses a `local` declaration with optional attributes.
	 *
	 * @param cur Enclosing block (used to flag `to-be-closed` locals).
	 * @param line Line of the `local` keyword.
	 * @returns The parsed statement.
	 */
	function localStat(cur:Block, line:Int):Stmt {
		var names:Array<String> = [];
		var attrs:Array<Int> = [];
		var lead = getAttr();
		var nclose = 0;
		do {
			names.push(strCheckName());
			var a = getAttr();
			if (a == 0)
				a = lead;
			attrs.push(a);
			if (a == 2) {
				nclose++;
				if (nclose > 1)
					semError("multiple to-be-closed variables in local list");
			}
		} while (testNext(44));
		var exprs = [];
		if (testNext(61))
			exprs = exprList();
		var vars = [];
		for (i in 0...names.length)
			vars.push(newLocal(names[i], attrs[i]));
		if (nclose > 0)
			cur.hasClose = true;
		return SLocal(vars, exprs, line);
	}

	/**
	 * Parses a `global` declaration.
	 *
	 * Supports `global function f() ... end`, `global *` (disables strict
	 * mode), and one or more comma-separated names with optional attributes.
	 * Declared names become valid in strict mode until the enclosing scope
	 * ends.
	 *
	 * @param line Line of the `global` keyword.
	 * @returns The parsed statement, or `null` for `global *` / pure declarations.
	 */
	function globalStat(line:Int):Stmt {
		ls.next();
		if (testNext(LLex.TK_FUNCTION)) {
			var name = strCheckName();
			gnames.push({name: name, isConst: false});
			var target = singlevar(name);
			var f = funcBody(false, line);
			return SAssign([target], [EFunc(f)], line);
		}
		var lead = getAttr();
		if (ls.tk == 42) { // `global *`
			ls.next();
			gstrict = false;
			return null;
		}
		var names:Array<String> = [];
		var consts:Array<Bool> = [];
		do {
			names.push(strCheckName());
			var a = getAttr();
			if (a == 0)
				a = lead;
			if (a == 2)
				semError("global variables cannot be to-be-closed");
			consts.push(a == 1);
		} while (testNext(44));
		for (i in 0...names.length)
			gnames.push({name: names[i], isConst: consts[i]});
		gstrict = true;
		if (ls.tk == 61) {
			ls.next();
			var exprs = exprList();
			var targets = [];
			for (n in names)
				targets.push(EIndex(resolveName("_ENV"), EConst(n), line));
			return SAssign(targets, exprs, line);
		}
		return null;
	}

	/**
	 * Parses a `return` statement (optionally with a value list).
	 *
	 * @returns The parsed `SReturn`.
	 */
	function retStat():Stmt {
		var line = ls.line;
		ls.next();
		var exprs = [];
		if (!blockFollow(true) && ls.tk != 59)
			exprs = exprList();
		testNext(59);
		if (!blockFollow(true))
			ls.errorToken("<eof> expected");
		return SReturn(exprs, line);
	}

	/**
	 * Verifies that `e` is a valid assignment target and, when the target is
	 * a `const`, raises a semantic error.
	 *
	 * @param e Candidate target expression.
	 */
	function checkAssignable(e:Expr):Void {
		switch (e) {
			case ELocal(v):
				if (v.attr != 0)
					semError("attempt to assign to const variable '" + v.name + "'");
			case EUpval(i, name):
				var v = fs.upvalVars[i];
				if (v != null && v.attr != 0)
					semError("attempt to assign to const variable '" + name + "'");
			case EIndex(obj, EConst(k), _):
				// Writes through `_ENV` must honor declared const globals.
				var isEnv = switch (obj) {
					case ELocal(v): v.name == "_ENV";
					case EUpval(_, n): n == "_ENV";
					default: false;
				}
				if (isEnv && Std.isOfType(k, String)) {
					var i = gnames.length - 1;
					while (i >= 0) {
						if (gnames[i].name == k) {
							if (gnames[i].isConst)
								semError("attempt to assign to const variable '" + k + "'");
							break;
						}
						i--;
					}
				}
			case EIndex(_, _, _):
			default:
				ls.errorToken("syntax error");
		}
	}

	/**
	 * Parses either an assignment or an expression statement (a single call).
	 *
	 * @param line Line of the first token.
	 * @returns The parsed statement.
	 */
	function exprStat(line:Int):Stmt {
		var e = suffixedExp();
		if (ls.tk == 61 || ls.tk == 44) {
			var targets = [e];
			checkAssignable(e);
			while (testNext(44)) {
				var t = suffixedExp();
				checkAssignable(t);
				targets.push(t);
			}
			checkNext(61);
			var exprs = exprList();
			return SAssign(targets, exprs, line);
		}
		switch (e) {
			case ECall(_, _, _), EMethCall(_, _, _, _):
				return SCall(e, line);
			default:
				ls.errorToken("syntax error");
				return null;
		}
	}

	/**
	 * Parses a comma-separated list of expressions.
	 *
	 * @returns The parsed expressions.
	 */
	function exprList():Array<Expr> {
		var l = [expr()];
		while (testNext(44))
			l.push(expr());
		return l;
	}

	/**
	 * Parses an expression using the full precedence grammar.
	 *
	 * @returns The parsed expression.
	 */
	function expr():Expr
		return subExpr(0);

	/**
	 * Maps a token to the corresponding unary operator code.
	 *
	 * @param t Token kind.
	 * @returns Operator code, or `-1` if `t` is not a unary operator.
	 */
	static function unaryOp(t:Int):Int {
		switch (t) {
			case LLex.TK_NOT:
				return OP_NOT;
			case 45:
				return LNum.OP_UNM;
			case 126:
				return LNum.OP_BNOT;
			case 35:
				return OP_LEN;
			default:
				return -1;
		}
	}

	/**
	 * Maps a token to the corresponding binary operator code.
	 *
	 * @param t Token kind.
	 * @returns Operator code, or `-1` if `t` is not a binary operator.
	 */
	static function binaryOp(t:Int):Int {
		switch (t) {
			case 43:
				return LNum.OP_ADD;
			case 45:
				return LNum.OP_SUB;
			case 42:
				return LNum.OP_MUL;
			case 37:
				return LNum.OP_MOD;
			case 94:
				return LNum.OP_POW;
			case 47:
				return LNum.OP_DIV;
			case LLex.TK_IDIV:
				return LNum.OP_IDIV;
			case 38:
				return LNum.OP_BAND;
			case 124:
				return LNum.OP_BOR;
			case 126:
				return LNum.OP_BXOR;
			case LLex.TK_SHL:
				return LNum.OP_SHL;
			case LLex.TK_SHR:
				return LNum.OP_SHR;
			case LLex.TK_CONCAT:
				return OP_CONCAT;
			case LLex.TK_NE:
				return OP_NE;
			case LLex.TK_EQ:
				return OP_EQ;
			case 60:
				return OP_LT;
			case LLex.TK_LE:
				return OP_LE;
			case 62:
				return OP_GT;
			case LLex.TK_GE:
				return OP_GE;
			case LLex.TK_AND:
				return 40;
			case LLex.TK_OR:
				return 41;
			default:
				return -1;
		}
	}

	/**
	 * Returns the left-binding power of a binary operator.
	 *
	 * @param op Operator code.
	 * @returns Binding power.
	 */
	static function leftPri(op:Int):Int {
		switch (op) {
			case LNum.OP_ADD, LNum.OP_SUB:
				return 10;
			case LNum.OP_MUL, LNum.OP_MOD, LNum.OP_DIV, LNum.OP_IDIV:
				return 11;
			case LNum.OP_POW:
				return 14;
			case LNum.OP_BAND:
				return 6;
			case LNum.OP_BOR:
				return 4;
			case LNum.OP_BXOR:
				return 5;
			case LNum.OP_SHL, LNum.OP_SHR:
				return 7;
			case OP_CONCAT:
				return 9;
			case 40:
				return 2;
			case 41:
				return 1;
			default:
				return 3;
		}
	}

	/**
	 * Returns the right-binding power of a binary operator (equal to the
	 * left one except for right-associative operators `^` and `..`).
	 *
	 * @param op Operator code.
	 * @returns Binding power.
	 */
	static function rightPri(op:Int):Int {
		switch (op) {
			case LNum.OP_POW:
				return 13;
			case OP_CONCAT:
				return 8;
			default:
				return leftPri(op);
		}
	}

	/**
	 * Parses a subexpression, stopping before any operator with binding
	 * power `<= limit` (precedence-climbing parser).
	 *
	 * @param limit Minimum right-binding power to consume.
	 * @returns The parsed expression.
	 */
	function subExpr(limit:Int):Expr {
		var e:Expr;
		var uop = unaryOp(ls.tk);
		if (uop >= 0) {
			var line = ls.line;
			ls.next();
			var operand = subExpr(UNARY_PRIORITY);
			e = foldUnary(uop, operand, line);
		} else
			e = simpleExp();
		var op = binaryOp(ls.tk);
		while (op >= 0 && leftPri(op) > limit) {
			var line = ls.line;
			ls.next();
			var rhs = subExpr(rightPri(op));
			e = op == 40 ? EAnd(e, rhs) : (op == 41 ? EOr(e, rhs) : EBin(op, e, rhs, line));
			op = binaryOp(ls.tk);
		}
		return e;
	}

	/**
	 * Attempts constant folding for unary `-` and `~` on numeric literals.
	 *
	 * @param op Operator code.
	 * @param a Operand.
	 * @param line Line of the operator.
	 * @returns Either a folded constant or an `EUn` node.
	 */
	function foldUnary(op:Int, a:Expr, line:Int):Expr {
		if (op == LNum.OP_UNM || op == LNum.OP_BNOT) {
			switch (a) {
				case EConst(v):
					if (LNum.isNumber(v)) {
						try {
							var r = LNum.arith(op, v, v);
							if (r != LNum.FAIL)
								return EConst(r);
						} catch (e:LuaError) {}
					}
				default:
			}
		}
		return EUn(op, a, line);
	}

	/**
	 * Parses a "simple" expression (literal, vararg, table constructor,
	 * function literal, or a primary suffixed expression).
	 *
	 * @returns The parsed expression.
	 */
	function simpleExp():Expr {
		switch (ls.tk) {
			case LLex.TK_FLT, LLex.TK_INT:
				var v = ls.nv;
				ls.next();
				return EConst(v);
			case LLex.TK_STRING:
				var s = ls.sv;
				ls.next();
				return EConst(s);
			case LLex.TK_NIL:
				ls.next();
				return ENil;
			case LLex.TK_TRUE:
				ls.next();
				return ETrue;
			case LLex.TK_FALSE:
				ls.next();
				return EFalse;
			case LLex.TK_DOTS:
				if (!fs.isVararg)
					ls.errorToken("cannot use '...' outside a vararg function");
				ls.next();
				return EVararg;
			case 123: // `{`
				return tableCons();
			case LLex.TK_FUNCTION:
				var line = ls.line;
				ls.next();
				return EFunc(funcBody(false, line));
			default:
				return suffixedExp();
		}
	}

	/**
	 * Parses a primary expression: an identifier or a parenthesized
	 * expression.
	 *
	 * @returns The parsed expression.
	 */
	function primaryExp():Expr {
		switch (ls.tk) {
			case LLex.TK_NAME:
				var name = ls.sv;
				ls.next();
				return singlevar(name);
			case 40: // `(`
				var line = ls.line;
				ls.next();
				var e = expr();
				checkMatch(41, 40, line);
				return EParen(e);
			default:
				ls.errorToken("unexpected symbol");
				return null;
		}
	}

	/**
	 * Parses a primary expression followed by any number of suffixes
	 * (`.name`, `[expr]`, `:method(args)`, `(args)` and sugar forms).
	 *
	 * @returns The parsed expression.
	 */
	function suffixedExp():Expr {
		var line = ls.line;
		var e = primaryExp();
		while (true) {
			switch (ls.tk) {
				case 46: // `.`
					ls.next();
					e = EIndex(e, EConst(strCheckName()), line);
				case 91: // `[`
					ls.next();
					var k = expr();
					checkNext(93);
					e = EIndex(e, k, line);
				case 58: // `:`
					ls.next();
					var name = strCheckName();
					e = EMethCall(e, name, callArgs(), line);
				case 40, LLex.TK_STRING, 123:
					e = ECall(e, callArgs(), line);
				default:
					return e;
			}
		}
	}

	/**
	 * Parses the argument list of a call in any of its sugar forms:
	 * `(args)`, `"string"` and `{table}`.
	 *
	 * @returns The argument expressions.
	 */
	function callArgs():Array<Expr> {
		switch (ls.tk) {
			case LLex.TK_STRING:
				var s = ls.sv;
				ls.next();
				return [EConst(s)];
			case 123:
				return [tableCons()];
			case 40:
				var line = ls.line;
				ls.next();
				if (ls.tk == 41) {
					ls.next();
					return [];
				}
				var args = exprList();
				checkMatch(41, 40, line);
				return args;
			default:
				ls.errorToken("function arguments expected");
				return null;
		}
	}

	/**
	 * Parses a table constructor `{ ... }`, accepting `name = value`,
	 * `[expr] = value` and positional entries separated by `,` or `;`.
	 *
	 * @returns The parsed expression.
	 */
	function tableCons():Expr {
		var line = ls.line;
		checkNext(123);
		var items:Array<TItem> = [];
		while (ls.tk != 125) {
			if (ls.tk == LLex.TK_NAME && ls.lookahead() == 61) {
				var k = strCheckName();
				ls.next(); // `=`
				items.push(Named(EConst(k), expr()));
			} else if (ls.tk == 91) {
				ls.next();
				var k = expr();
				checkNext(93);
				checkNext(61);
				items.push(Named(k, expr()));
			} else
				items.push(Pos(expr()));
			if (!testNext(44) && !testNext(59))
				break;
		}
		checkMatch(125, 123, line);
		return ETable(items, line);
	}

	/**
	 * Parses a function body and returns its `FuncInfo`. Handles an implicit
	 * `self` parameter for `a:b()` method definitions, parameter lists and
	 * varargs.
	 *
	 * @param isMethod Whether to prepend an implicit `self` parameter.
	 * @param line Line of the enclosing `function` keyword.
	 * @returns The new `FuncInfo`.
	 */
	function funcBody(isMethod:Bool, line:Int):FuncInfo {
		var f = new FuncInfo(fs);
		f.line = line;
		fs = f;
		if (isMethod)
			f.params.push(newLocal("self"));
		checkNext(40);
		if (ls.tk != 41) {
			do {
				if (ls.tk == LLex.TK_NAME)
					f.params.push(newLocal(strCheckName()));
				else if (ls.tk == LLex.TK_DOTS) {
					ls.next();
					f.isVararg = true;
					break;
				} else
					ls.errorToken("<name> or '...' expected");
			} while (testNext(44));
		}
		f.nparams = f.params.length;
		checkNext(41);
		var body = new Block();
		statList(body);
		body.nlocals = f.actives.length - f.nparams;
		f.body = body;
		f.lastLine = ls.line;
		checkMatch(LLex.TK_END, LLex.TK_FUNCTION, line);
		fs = f.parent;
		return f;
	}
}
