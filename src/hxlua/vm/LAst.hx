package luahx.vm;

import luahx.vm.LObject;

/**
 * A local variable resolved by the parser.
 *
 * `slot` is the variable's position within the stack frame; `captured`
 * indicates that the variable is referenced by at least one nested closure
 * and must therefore live inside a {@link Cell} rather than the plain stack.
 */
final class VarInfo {
	public var name:String;
	public var slot:Int;
	public var captured:Bool = false;

	/** Attribute: `0` normal, `1` `<const>`, `2` `<close>`. */
	public var attr:Int = 0;

	public var hidden:Bool = false;

	public function new(name:String, slot:Int, attr:Int = 0) {
		this.name = name;
		this.slot = slot;
		this.attr = attr;
	}
}

/**
 * A single entry in a table constructor.
 *
 * - `Pos(e)`: positional entry (`{e}`), implicitly indexed by position.
 * - `Named(k, v)`: keyed entry (`{[k] = v}` or `{k = v}`).
 */
enum TItem {
	Pos(e:Expr);
	Named(k:Expr, v:Expr);
}

/**
 * Expression AST node.
 *
 * Variable references have already been resolved to `ELocal`/`EUpval`;
 * only identifiers that are not bound in the current lexical environment
 * are represented as `_ENV.name` (an `EIndex` on the `_ENV` upvalue).
 */
enum Expr {
	ENil;
	ETrue;
	EFalse;
	EConst(v:Dynamic);
	EVararg;
	ELocal(v:VarInfo);
	EUpval(idx:Int, name:String);
	EIndex(obj:Expr, key:Expr, line:Int);
	ECall(fn:Expr, args:Array<Expr>, line:Int);
	EMethCall(obj:Expr, name:String, args:Array<Expr>, line:Int);
	EFunc(fi:FuncInfo);
	EBin(op:Int, a:Expr, b:Expr, line:Int);
	EUn(op:Int, a:Expr, line:Int);
	EAnd(a:Expr, b:Expr);
	EOr(a:Expr, b:Expr);
	ETable(items:Array<TItem>, line:Int);

	/** Parenthesized expression: forces single-value context for its inner expression. */
	EParen(e:Expr);
}

/**
 * Statement AST node.
 *
 * `SLabel` carries an `atEnd` flag set by the parser when the label is the
 * last statement of its block; the code generator emits those labels after
 * the block's epilogue so they see the outer scope.
 */
enum Stmt {
	SLocal(vars:Array<VarInfo>, exprs:Array<Expr>, line:Int);
	SAssign(targets:Array<Expr>, exprs:Array<Expr>, line:Int);
	SCall(e:Expr, line:Int);
	SDo(b:Block);
	SWhile(cond:Expr, b:Block, line:Int);
	SRepeat(b:Block, cond:Expr, line:Int);
	SIf(conds:Array<Expr>, blocks:Array<Block>, els:Block, line:Int);
	SNumFor(v:VarInfo, init:Expr, limit:Expr, step:Expr, b:Block, line:Int);
	SGenFor(vars:Array<VarInfo>, exprs:Array<Expr>, b:Block, line:Int);
	SLocalFunc(v:VarInfo, f:FuncInfo, line:Int);
	SReturn(exprs:Array<Expr>, line:Int);
	SBreak(line:Int);
	SGoto(label:String, line:Int);
	SLabel(name:String, line:Int, atEnd:Bool);
}

/**
 * A lexical block: a list of statements plus the bookkeeping needed by the
 * code generator.
 */
final class Block {
	public var stmts:Array<Stmt> = [];

	/** Number of locals declared directly in this block. */
	public var nlocals:Int = 0;

	/** Whether the block declares any `<close>` variable (drives `CLOSE` emission). */
	public var hasClose:Bool = false;

	public function new() {}
}

/**
 * Function descriptor produced by the parser.
 *
 * Tracks active locals, upvalue descriptors and captured variables while the
 * function body is being parsed; the parent link allows upvalue resolution
 * to walk the lexical chain.
 */
final class FuncInfo {
	public var parent:FuncInfo;
	public var nparams:Int = 0;
	public var isVararg:Bool = false;
	public var body:Block;

	/** Upvalues of this function (index -> descriptor). */
	public var upvals:Array<UpvalDesc> = [];

	/** `VarInfo` corresponding to each upvalue, when it comes from a parent local. */
	public var upvalVars:Array<VarInfo> = [];

	public var line:Int = 0;
	public var lastLine:Int = 0;

	/** Locals currently in scope while parsing the body. */
	public var actives:Array<VarInfo> = [];

	public var params:Array<VarInfo> = [];

	public function new(parent:FuncInfo) {
		this.parent = parent;
	}
}
