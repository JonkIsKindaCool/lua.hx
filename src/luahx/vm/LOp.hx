package luahx.vm;

/**
 * lopcodes.h — VM instruction set (stack-based machine).
 *
 * Operands `a`, `b` and `c` are encoded inline; their meaning depends on
 * the opcode. Arithmetic opcodes are laid out contiguously starting at
 * {@link ADD}, following the order of `LNum.OP_*`. The unary variants are
 * also placed at fixed offsets from `ADD` (`UNM = ADD + 12`, `BNOT = ADD + 13`)
 * so the VM can dispatch them with the same `op - ADD` index.
 */
enum abstract LOp(Int) from Int to Int {
	/** No operation. */
	var NOP = 0;

	/** Push `nil`. */
	var NIL = 1;

	/** Push `a` nils (`a` = count). */
	var NILN = 2;

	/** Push `true`. */
	var TRUE = 3;

	/** Push `false`. */
	var FALSE = 4;

	/** Push the constant at index `a`. */
	var CONST = 5;

	/** Push varargs. `b` = requested count (`-1` = all). */
	var VARARG = 6;

	/** Push a copy of the local at absolute slot `a`. */
	var GETLOC = 7;

	/** Pop a value into the local at absolute slot `a`. */
	var SETLOC = 8;

	/** Push the value of the cell at absolute slot `a`. */
	var GETCELL = 9;

	/** Pop a value into the cell at absolute slot `a`. */
	var SETCELL = 10;

	/** Wrap the value at absolute slot `a` in a fresh cell. */
	var NEWCELL = 11;

	/** Push upvalue `a`. */
	var GETUP = 12;

	/** Pop a value into upvalue `a`. */
	var SETUP = 13;

	/** Replace the top of the stack with `t.k` (`k` = constant string at index `a`). */
	var GETFIELD = 14;

	/** Replace the top two values with `t[k]`. */
	var GETTABLE = 15;

	/** Pop `t, k, v` and store `t[k] = v`. */
	var SETTABLE = 16;

	/** Pop `t, v` and store `t.k = v` (`k` = constant at index `a`). */
	var SETFIELD = 17;

	/** Like `SETFIELD`, but the key lives `a` slots below the top. */
	var SETTAB_D = 18;

	/** Push a fresh empty table. */
	var NEWTABLE = 19;

	/** Set field `k` (`a` = const index) on the table `b` slots below the top, popping the value. */
	var INITFIELD = 20;

	/** Set `t[k] = v` on the table `b` slots below the top, popping both. */
	var INITTABLE = 21;

	/** Fill table positions from `b` stack values starting at `a`; `c` marks an open (vararg) list. */
	var SETLIST = 22;

	/** Push `t.k, t` for method-call sugar (`t:k(...)`); `a` = const index. */
	var SELF = 23;

	/** Call. `a` = nargs, `b` = expected results (`-1` = all), `c` = open argument list. */
	var CALL = 24;

	/** Tail call; reuses the current frame when possible. */
	var TAILCALL = 25;

	/** Return. `a` = number of values, `c` = open list. */
	var RETURN = 26;

	/**
	 * First arithmetic opcode. The full set is `ADD + LNum.OP_*`; the unary
	 * variants `UNM` and `BNOT` are also positioned relative to `ADD`
	 * (`ADD + 12` and `ADD + 13` respectively).
	 */
	var ADD = 27;

	/** Unary minus (`ADD + 12`). */
	var UNM = 39;

	/** Bitwise NOT (`ADD + 13`). */
	var BNOT = 40;

	/** Logical NOT. */
	var NOT = 41;

	/** Length operator `#`. */
	var LEN = 42;

	/** Concatenate the top `a` values. */
	var CONCAT = 43;

	/** Equality `==`. */
	var EQ = 44;

	/** Inequality `~=`. */
	var NE = 45;

	/** Less than `<`. */
	var LT = 46;

	/** Less or equal `<=`. */
	var LE = 47;

	/** Greater than `>`. */
	var GT = 48;

	/** Greater or equal `>=`. */
	var GE = 49;

	/** Unconditional jump to `a`. */
	var JMP = 50;

	/** Jump to `a` after dropping `b` stack slots. */
	var JMPN = 51;

	/** Pop a value and jump to `a` if it is false. */
	var JMPF = 52;

	/** Pop a value and jump to `a` if it is true. */
	var JMPT = 53;

	/** Short-circuit `and`: if the top is false, jump to `a`; otherwise pop it. */
	var TESTF = 54;

	/** Short-circuit `or`: if the top is true, jump to `a`; otherwise pop it. */
	var TESTT = 55;

	/** Pop one value. */
	var POP = 56;

	/** Pop `a` values. */
	var POPN = 57;

	/** Prepare a numeric `for` loop. */
	var FORPREP = 58;

	/** Step a numeric `for` loop; jump back to `b` while in range. */
	var FORLOOP = 59;

	/** Call the generic iterator for `for ... in`. */
	var TFORCALL = 60;

	/** Loop back to `b` while the generic iterator's control variable is non-nil. */
	var TFORLOOP = 61;

	/** Build a closure from prototype `a`. */
	var CLOSURE = 62;

	/** Mark the local at slot `a` as to-be-closed. */
	var TBC = 63;

	/** Close all to-be-closed variables at stack level `>= a`. */
	var CLOSE = 64;

	/**
	 * Arithmetic between an opcode constant and an integer offset. Used to
	 * enumerate the arithmetic opcode range (`ADD`, `ADD + 1`, ...) in the
	 * VM dispatch loop.
	 *
	 * @param a Opcode constant.
	 * @param b Integer offset.
	 * @returns The resulting opcode value as an `Int`.
	 */
	@:commutative @:op(A + B) static inline function add(a:LOp, b:Int):Int
		return (a : Int) + b;
}
