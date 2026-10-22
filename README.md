# lua.hx

**Lua 5.5 for every Haxe target.** A from-scratch implementation of the Lua 5.5 language and standard
library written in pure Haxe: no native bindings, no threads, no external dependencies.

It mirrors the structure of the reference C implementation (`llex`, `lparser`, `lcode`, `lvm`, `ldo`,
`ltable`, `lstrlib`, …) and ships with a Haxe-friendly wrapper (`luahx.Lua`) for embedding, scripting,
modding and sandboxing.

```haxe
import luahx.Lua;

class Main {
  static function main() {
    var lua = new Lua();

    // Expose a Haxe function to Lua
    lua.register("add", args -> args[0] + args[1]);

    lua.doString("print('2 + 3 =', add(2, 3))");

    // Get values back
    var results = lua.doString("return 'hello', 42, {1, 2, 3}");
    trace(results[0], results[1]);            // hello, 42

    // Call Lua functions from Haxe
    var double = lua.toFunction(lua.doString("return function(x) return x * 2 end")[0]);
    trace(double(21));                        // 42
  }
}
```

## Features

- **Lua 5.5 language**: integers and floats (real 64-bit integers), `goto`, integer division, bitwise operators,
  `<const>` / `<close>` variables, `global` declarations, read-only loop variables, metatables and all metamethods.
- **Coroutines on every target**: implemented with heap-allocated stacks (like PUC-Lua), so they do not need
  threads or target-specific features. `yield` works across Lua calls, `pcall`/`xpcall`, `for-in` iterators
  and `<close>` scopes.
- **Standard library**: `base`, `string` (Lua patterns, `format`, `pack`/`unpack`), `table`, `math`
  (xoshiro256\*\* PRNG, same as real Lua), `utf8`, `coroutine`, `os`, `io`, and a subset of `debug`.
- **Exact number formatting**: `%g`, `%f`, `%e`, `%a` and `tostring` on floats are computed with exact arithmetic and
  match the reference implementation.
- **Embedding API** with automatic Haxe ⇄ Lua value conversion, output/input redirection, a pluggable source
  loader for `require`, and a sandbox mode with no standard libraries.
- **Verified against real Lua**: test scripts are run side by side with Lua 5.4.6 on several Haxe targets and
  produce identical output (see [Status](#status)).

## Installation

```
haxelib install lua.hx
```

Or straight from a checkout / repository:

```
haxelib git lua.hx <repository-url>
haxelib dev lua.hx path/to/lua.hx
```

Then add it to your project:

```
-lib lua.hx
```

Requires Haxe 4.0 or newer (developed and tested with 4.3.3).

## Usage

### Running code

```haxe
var lua = new Lua();                       // all standard libraries
var sandbox = new Lua(false);              // no libraries at all

lua.doString("x = 10");                    // run a chunk
var r = lua.doString("return x * 2");      // r == [20]
var fn = lua.load("return ...", "=my chunk");   // compile only (returns a Lua function)
```

Errors are thrown as `luahx.vm.LObject.LuaError` (the Lua error value is in `e.value`):

```haxe
try {
  lua.doString("error('boom')", "=script");
} catch (e:LuaError) {
  trace(e.value);                          // script:1: boom
}
```

### Globals and Haxe functions

```haxe
lua.setGlobal("player", {name: "Ann", hp: 100});   // anonymous object -> Lua table
lua.setGlobal("items", ["sword", "shield"]);       // Array -> Lua sequence
lua.getGlobal("score");

lua.register("log", args -> { trace(args); return null; });           // returns 0 or 1 value
lua.registerMulti("divmod", a -> [Std.int(a[0] / a[1]), a[0] % a[1]]); // returns several values
```

Exceptions thrown inside a registered function as `LuaError` are catchable from Lua with `pcall`.

### Calling Lua from Haxe

```haxe
var f = lua.doString("return function(a, b) return a * b, a + b end")[0];
lua.call(f, [6, 7]);                       // [42, 13]

var haxeFn:Dynamic = lua.toFunction(f);    // variadic Haxe function (returns the first result)
haxeFn(6, 7);                              // 42
```

### Coroutines from Haxe

```haxe
var co = lua.newCoroutine(lua.doString(
  "return function(a) local b = coroutine.yield(a + 1) return b * 2 end")[0]);

lua.resume(co, [10]);                      // { ok: true, values: [11] }
lua.resume(co, [21]);                      // { ok: true, values: [42] }
lua.status(co);                            // "dead"
```

### Input, output and modules

```haxe
lua.setOutput(s -> myConsole.write(s));    // print / io.write
lua.setErrorOutput(s -> myConsole.err(s)); // io.stderr / warn
lua.setInput(() -> readNextLineOrNull());  // io.read / io.lines on stdin

// require / dofile / loadfile work on any target, including those without a file system
lua.setSourceLoader(path -> path == "./config.lua" ? "return { debug = true }" : null);
lua.doString("local cfg = require('config')");
```

`package.path` is `./?.lua;./?/init.lua` by default; each candidate path is passed to your loader.

### Tables

```haxe
var t = lua.newTable();
lua.tableSet(t, "key", "value");           // respects metamethods, converts values
lua.tableGet(t, "key");
lua.toHaxe(t, true);                       // deep conversion to Array / anonymous object
```

## API reference

| Member | Description |
|---|---|
| `new Lua(openLibs = true)` | Create an independent Lua state. |
| `doString(code, ?chunkName)` | Compile and run; returns the results converted to Haxe. Throws `LuaError`. |
| `load(code, ?chunkName)` | Compile a chunk and return the Lua function. |
| `call(f, args)` | Call any Lua callable with Haxe arguments; returns converted results. |
| `toFunction(f)` | Wrap a Lua function as a variadic Haxe function. |
| `setGlobal(name, v)` / `getGlobal(name)` | Read/write globals with value conversion. |
| `register(name, fn)` / `registerMulti(name, fn)` | Expose Haxe functions as Lua globals. |
| `makeFunction` / `makeFunctionMulti` | Same, but return the function value instead of setting a global. |
| `newCoroutine(f)` / `resume(co, ?args)` / `status(co)` | Drive coroutines from Haxe. |
| `newTable()` / `tableGet` / `tableSet` | Table helpers. |
| `setOutput` / `setErrorOutput` / `setInput` | Redirect standard streams (Unicode strings). |
| `setSourceLoader(f)` | Provide source code for `require`, `dofile`, `loadfile`. |
| `toHaxe(v, deep = false)` / `fromHaxe(v)` / `fromInt64(i)` | Value conversion. |
| `state` | The underlying `luahx.vm.LuaState` (full low-level access to the VM). |

### Value conversion

| Haxe → Lua | Lua → Haxe |
|---|---|
| `null` → `nil` | `nil` → `null` |
| `Bool` → boolean | boolean → `Bool` |
| `Int` → integer | integer → `Int` (or `haxe.Int64` when it does not fit 32 bits) |
| `Float` → float | float → `Float` |
| `String` → string (encoded as UTF-8) | string → `String` (decoded from UTF-8) |
| `Array` → table (1-based sequence) | table → `LTable` (`deep = true`: `Array` or anonymous object) |
| anonymous object, `Map` → table | function → Lua function value (use `toFunction` to call it from Haxe) |
| Haxe function → Lua function | coroutine → `Coroutine` |

Lua strings are byte strings internally (each `char` of the underlying `String` is one byte, 0–255). The wrapper
converts to/from Unicode at the boundary, so `#"é"` is `2` in Lua exactly as in the reference implementation.

## Status
| Target | Status |
|---|---|
| eval (`--interp`) | ✅ output identical to reference Lua |
| Neko | ✅ output identical |
| JavaScript (Node.js) | ✅ output identical |
| Python | ✅ output identical |
| HashLink | ✅ output identical |
| C++, JVM, C#, PHP, Lua | ⚠️ not tested yet — contributions and reports welcome |

The embedding API (`test/WrapperTest.hx`) passes on eval, Neko, JavaScript and Python. Lua 5.5-specific behavior
(`test/t55.lua`) was checked by hand since no 5.5 reference binary was available.

## Architecture

| Module (`src/luahx/…`) | Counterpart in PUC-Lua | Role |
|---|---|---|
| `vm/LLex.hx` | `llex.c` | Lexer |
| `vm/LParser.hx`, `vm/LAst.hx` | `lparser.c` | Parser producing an AST with resolved variables |
| `vm/LCode.hx`, `vm/LOp.hx` | `lcode.c`, `lopcodes.h` | Bytecode compiler (stack machine) |
| `vm/LVM.hx` | `lvm.c` | Interpreter loop; Lua→Lua calls do not recurse on the Haxe stack |
| `vm/LState.hx` | `lstate.c`, `ldo.c`, `ltm.c` | State, calls, errors, metamethods, coroutines |
| `vm/LTable.hx` | `ltable.c` | Array part + insertion-ordered hash part |
| `vm/LNum.hx` | `lobject.c` | 64-bit integers, floats, string↔number conversion, exact formatting |
| `lib/L*Lib.hx` | `l*lib.c` | Standard libraries |
| `Lua.hx` | — | Haxe wrapper |

## Differences from reference Lua and known limitations

- **No `yield` across native boundaries.** You cannot yield from inside a metamethod function (`__index`, `__add`, …),
  a `table.sort` comparator, a `string.gsub` callback, etc.; this raises
  `attempt to yield across a C-call boundary`. Yielding through Lua functions, `pcall`, `xpcall`, `for-in`
  iterators and `<close>` works.
- **No observable garbage collection.** `__gc` and `__mode` are ignored; `collectgarbage("count")` returns a constant.
- **Not implemented:** `string.dump` and binary chunks, `io.popen`, `io.tmpfile`, most of `debug`
  (`traceback`, `getinfo`, `getmetatable`, `setmetatable`, `getupvalue` and no-op hooks are provided).
- **File and OS access** (`io.open`, `os.remove`, `os.rename`, `os.getenv`, `os.exit`) is only available on `sys` targets.
- **`utf8.offset`** returns both the start and end position of the character, as in Lua 5.5.
- `tostring(0/0)` prints `nan` (Linux/x86 builds of Lua print `-nan`).
- **Performance:** roughly 8× slower than PUC-Lua on Node.js (`fib(30)` ≈ 0.5 s); considerably slower on
  inherently slow targets such as eval and Neko. Other targets have not been benchmarked.
- **hxcpp:** its `String` is UTF-8 internally, so the byte-string model (characters ≥ 128) has not been verified there.

## Running the tests

```
# Embedding API tests
haxe -cp src -cp test -main WrapperTest --interp

# Lua 5.5 features
haxe -cp src -cp test --run Main test/t55.lua
```

## Contributing

Bug reports with a minimal Lua snippet are the most useful: please include the Haxe target and, if possible,
the output of the reference `lua` binary for comparison.

## License

MIT. See `haxelib.json`.