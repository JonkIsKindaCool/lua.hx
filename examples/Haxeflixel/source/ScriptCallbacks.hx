package;

import flixel.FlxBasic;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.input.keyboard.FlxKey;
import flixel.text.FlxText;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import luahx.Lua;
import luahx.vm.LObject.LuaError;
import luahx.vm.LObject.LuaFunction;
import openfl.utils.Assets;

class ScriptCallbacks {
	public static var lua:Script;
	public static var hxObjects:Map<String, Dynamic> = new Map();
	public static var timers:Map<String, FlxTimer> = new Map();
	public static var tweens:Map<String, FlxTween> = new Map();

	public static var onError:String->Void = function(msg) trace("[lua] " + msg);

	public static var classAliases:Map<String, String> = [
		"FlxG" => "flixel.FlxG",
		"FlxSprite" => "flixel.FlxSprite",
		"FlxObject" => "flixel.FlxObject",
		"FlxBasic" => "flixel.FlxBasic",
		"FlxGroup" => "flixel.group.FlxGroup",
		"FlxTypedGroup" => "flixel.group.FlxGroup.FlxTypedGroup",
		"FlxSpriteGroup" => "flixel.group.FlxSpriteGroup",
		"FlxText" => "flixel.text.FlxText",
		"FlxMath" => "flixel.math.FlxMath",
		"FlxPoint" => "flixel.math.FlxPoint",
		"FlxRect" => "flixel.math.FlxRect",
		"FlxTween" => "flixel.tweens.FlxTween",
		"FlxEase" => "flixel.tweens.FlxEase",
		"FlxTimer" => "flixel.util.FlxTimer",
		"FlxCamera" => "flixel.FlxCamera",
		"FlxState" => "flixel.FlxState",
		"FlxBackdrop" => "flixel.addons.display.FlxBackdrop",
	];

	public static function register(lua:Script):Void {
		ScriptCallbacks.lua = lua;

		reg("createObject", createObject);
		reg("getObject", function(a) return getObj(a[0]));
		reg("hasObject", function(a) return hxObjects.exists(str(a[0])));
		reg("removeObject", removeObject);
		reg("destroyObject", destroyObject);
		reg("clearObjects", function(a) { clearObjects(); return null; });

		reg("getProperty", function(a) return getProperty(str(a[0])));
		reg("setProperty", function(a) { setProperty(str(a[0]), val(a[1])); return null; });
		reg("getPropertyFromClass", function(a) return getProperty(str(a[0]) + "." + str(a[1])));
		reg("setPropertyFromClass", function(a) { setProperty(str(a[0]) + "." + str(a[1]), val(a[2])); return null; });
		reg("callMethod", function(a) return callMethod(str(a[0]), arr(a[1])));
		reg("callMethodFromClass", callMethodFromClass);

		reg("add", function(a) { FlxG.state.add(cast getObj(a[0])); return null; });
		reg("insert", function(a) { FlxG.state.insert(Std.int(a[0]), cast getObj(a[1])); return null; });
		reg("remove", function(a) { FlxG.state.remove(cast getObj(a[0]), has(a, 1) ? a[1] == true : true); return null; });
		reg("addToGroup", function(a) { (cast getObj(a[0]) : flixel.group.FlxGroup).add(cast getObj(a[1])); return null; });
		reg("switchState", switchState);
		reg("resetState", function(a) { FlxG.resetState(); return null; });

		reg("makeSprite", makeSprite);
		reg("makeGraphic", makeGraphic);
		reg("loadGraphic", loadGraphic);
		reg("makeText", makeText);
		reg("screenCenter", screenCenter);
		reg("addAnimation", addAnimation);
		reg("playAnimation", playAnimation);
		reg("overlaps", function(a) return FlxG.overlap(cast getObj(a[0]), cast getObj(a[1])));

		reg("tween", tween);
		reg("cancelTween", function(a) { cancelTween(str(a[0])); return null; });
		reg("startTimer", startTimer);
		reg("cancelTimer", function(a) { cancelTimer(str(a[0])); return null; });

		reg("cameraShake", function(a) { FlxG.camera.shake(num(a, 0, 0.05), num(a, 1, 0.5)); return null; });
		reg("cameraFlash", function(a) { FlxG.camera.flash(toColor(has(a, 0) ? a[0] : "WHITE"), num(a, 1, 0.5)); return null; });
		reg("cameraFade", function(a) { FlxG.camera.fade(toColor(has(a, 0) ? a[0] : "BLACK"), num(a, 1, 0.5), has(a, 2) && a[2] == true); return null; });
		reg("cameraFollow", function(a) { FlxG.camera.follow(cast getObj(a[0]), null, num(a, 1, 1)); return null; });

		reg("playSound", function(a) { FlxG.sound.play(str(a[0]), num(a, 1, 1), has(a, 2) && a[2] == true); return null; });
		reg("playMusic", function(a) { FlxG.sound.playMusic(str(a[0]), num(a, 1, 1), !has(a, 2) || a[2] == true); return null; });
		reg("stopMusic", function(a) { if (FlxG.sound.music != null) FlxG.sound.music.stop(); return null; });

		reg("keyPressed", function(a) return FlxG.keys.anyPressed([toKey(a[0])]));
		reg("keyJustPressed", function(a) return FlxG.keys.anyJustPressed([toKey(a[0])]));
		reg("keyJustReleased", function(a) return FlxG.keys.anyJustReleased([toKey(a[0])]));
		reg("mouseX", function(a) return FlxG.mouse.x);
		reg("mouseY", function(a) return FlxG.mouse.y);
		reg("mouseScreenX", function(a) return FlxG.mouse.viewX);
		reg("mouseScreenY", function(a) return FlxG.mouse.viewY);
		reg("mousePressed", function(a) return mouseState(str(a[0]), false));
		reg("mouseJustPressed", function(a) return mouseState(str(a[0]), true));

		reg("getColor", function(a) return toColor(a[0]));
		reg("getRandomInt", function(a) return FlxG.random.int(Std.int(num(a, 0, 0)), Std.int(num(a, 1, 100))));
		reg("getRandomFloat", function(a) return FlxG.random.float(num(a, 0, 0), num(a, 1, 1)));
		reg("getRandomBool", function(a) return FlxG.random.bool(num(a, 0, 50)));
		reg("assetExists", function(a) return Assets.exists(str(a[0])));
		reg("getAssetText", function(a) return Assets.getText(str(a[0])));
		reg("debugPrint", function(a) { trace([for (x in a) Std.string(x)].join("\t")); return null; });
	}

	static function reg(name:String, fn:Array<Dynamic>->Dynamic):Void {
		lua.register(name, function(args:Array<Dynamic>):Dynamic {
			try {
				return fn(args);
			} catch (e:LuaError) {
				throw e;
			} catch (e:Dynamic) {
				throw new LuaError(name + ": " + Std.string(e), true);
			}
		});
	}
	public static function call(name:String, ?args:Array<Dynamic>):Dynamic {
		var f = lua.getGlobal(name);
		if (f == null) return null;
		return invoke(f, args);
	}

	public static function invoke(cb:Dynamic, ?args:Array<Dynamic>):Dynamic {
		if (cb == null) return null;
		if (Std.isOfType(cb, String)) cb = lua.getGlobal(cb);
		if (!Std.isOfType(cb, LuaFunction)) return null;
		try {
			var r = lua.call(cb, args == null ? [] : args);
			return r.length > 0 ? r[0] : null;
		} catch (e:LuaError) {
			onError(e.toString());
			return null;
		}
	}

	public static function clearObjects():Void {
		for (t in timers) t.cancel();
		for (t in tweens) t.cancel();
		timers.clear();
		tweens.clear();
		for (tag in [for (k in hxObjects.keys()) k]) destroyObject([tag]);
		hxObjects.clear();
	}

	static inline function has(a:Array<Dynamic>, i:Int):Bool
		return i < a.length && a[i] != null;

	static inline function str(v:Dynamic):String
		return v == null ? null : Std.string(v);

	static function num(a:Array<Dynamic>, i:Int, def:Float):Float
		return has(a, i) ? (a[i] : Float) : def;

	static function val(v:Dynamic):Dynamic
		return lua.toHaxe(v, true);

	static function arr(v:Dynamic):Array<Dynamic> {
		if (v == null) return [];
		var d = val(v);
		return Std.isOfType(d, Array) ? d : [d];
	}

	public static function resolveClass(name:String):Class<Dynamic> {
		var full = classAliases.exists(name) ? classAliases.get(name) : name;
		var cls = Type.resolveClass(full);
		return cls;
	}

	public static function getObj(v:Dynamic):Dynamic {
		if (Std.isOfType(v, String)) {
			var o = hxObjects.get(v);
			return o != null ? o : getProperty(v);
		}
		return v;
	}

	public static function toColor(v:Dynamic):Int {
		if (v == null) return FlxColor.WHITE;
		if (Std.isOfType(v, String)) {
			var s:String = v;
			var c = FlxColor.fromString(s);
			if (c == null) throw 'invalid color: $s';
			return c;
		}
		return Std.int(v);
	}

	static function toKey(v:Dynamic):FlxKey {
		var k = FlxKey.fromString(str(v).toUpperCase());
		return k;
	}

	static function mouseState(button:String, justPressed:Bool):Bool {
		var m = FlxG.mouse;
		if (button == "right") return justPressed ? m.justPressedRight : m.pressedRight;
		if (button == "middle") return justPressed ? m.justPressedMiddle : m.pressedMiddle;
		return justPressed ? m.justPressed : m.pressed;
	}

	static function tokenize(path:String):Array<Dynamic> {
		var out:Array<Dynamic> = [];
		for (part in path.split(".")) {
			var b = part.indexOf("[");
			if (b < 0) {
				out.push(part);
				continue;
			}
			if (b > 0) out.push(part.substr(0, b));
			var rest = part.substr(b);
			while (rest.length > 0 && rest.charAt(0) == "[") {
				var e = rest.indexOf("]");
				if (e < 0) throw 'malformed path: $path';
				var inner = rest.substring(1, e);
				var n = Std.parseInt(inner);
				out.push(n != null ? n : inner);
				rest = rest.substr(e + 1);
			}
		}
		return out;
	}

	static function resolveRoot(tokens:Array<Dynamic>):{obj:Dynamic, next:Int} {
		var first:Dynamic = tokens[0];
		if (Std.isOfType(first, String)) {
			if (hxObjects.exists(first)) return {obj: hxObjects.get(first), next: 1};
			var name = "";
			for (i in 0...tokens.length) {
				if (!Std.isOfType(tokens[i], String)) break;
				name += (i > 0 ? "." : "") + tokens[i];
				var cls = resolveClass(name);
				if (cls != null) return {obj: cls, next: i + 1};
			}
		}
		return {obj: FlxG.state, next: 0};
	}

	static function step(obj:Dynamic, t:Dynamic):Dynamic {
		if (obj == null) throw 'null object while accessing "$t"';
		if (Std.isOfType(t, Int)) {
			if (Std.isOfType(obj, Array)) return (cast obj : Array<Dynamic>)[t];
			throw 'cannot index non-array with [$t]';
		}
		if (Std.isOfType(obj, haxe.Constraints.IMap)) return (cast obj : haxe.Constraints.IMap<Dynamic, Dynamic>).get(t);
		return Reflect.getProperty(obj, t);
	}

	public static function getProperty(path:String):Dynamic {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		for (i in root.next...tokens.length) obj = step(obj, tokens[i]);
		return obj;
	}

	public static function setProperty(path:String, value:Dynamic):Void {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		if (root.next >= tokens.length) throw 'cannot assign to "$path": it is an object, not a property';
		for (i in root.next...tokens.length - 1) obj = step(obj, tokens[i]);
		var last:Dynamic = tokens[tokens.length - 1];
		if (obj == null) throw 'null object while assigning "$path"';
		if (Std.isOfType(last, Int)) (cast obj : Array<Dynamic>)[last] = value;
		else if (Std.isOfType(obj, haxe.Constraints.IMap)) (cast obj : haxe.Constraints.IMap<Dynamic, Dynamic>).set(last, value);
		else Reflect.setProperty(obj, last, value);
	}

	public static function createObject(args:Array<Dynamic>):Dynamic {
		var tag:String = args[0];
		var type:String = args[1];
		var cargs:Array<Dynamic> = arr(args[2]);

		var cls = resolveClass(type);
		if (cls == null) throw 'class not found: $type';
		var obj:Dynamic = Type.createInstance(cls, cargs);
		hxObjects.set(tag, obj);

		return obj;
	}

	static function removeObject(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var obj = hxObjects.get(tag);
		if (obj == null) return false;
		if (Std.isOfType(obj, FlxBasic)) FlxG.state.remove(cast obj, true);
		if (!has(a, 1) || a[1] == true) destroyIfPossible(obj);
		hxObjects.remove(tag);
		return true;
	}

	static function destroyObject(a:Array<Dynamic>):Dynamic
		return removeObject([a[0], true]);

	static function destroyIfPossible(obj:Dynamic):Void {
		if (Std.isOfType(obj, FlxBasic)) (cast obj : FlxBasic).destroy();
		else if (Reflect.hasField(obj, "destroy") || Reflect.isFunction(Reflect.field(obj, "destroy"))) Reflect.callMethod(obj, Reflect.field(obj, "destroy"), []);
	}

	public static function callMethod(path:String, args:Array<Dynamic>):Dynamic {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		if (root.next >= tokens.length) throw 'not a method path: $path';
		for (i in root.next...tokens.length - 1) obj = step(obj, tokens[i]);
		var name:String = tokens[tokens.length - 1];
		if (obj == null) throw 'null object while calling "$path"';
		var f = Reflect.field(obj, name);
		if (f == null) f = Reflect.getProperty(obj, name);
		if (!Reflect.isFunction(f)) throw '"$path" is not a function';
		return Reflect.callMethod(obj, f, args);
	}

	static function callMethodFromClass(a:Array<Dynamic>):Dynamic {
		var cls = resolveClass(str(a[0]));
		if (cls == null) throw 'class not found: ${a[0]}';
		var f = Reflect.field(cls, str(a[1]));
		if (!Reflect.isFunction(f)) throw '${a[0]}.${a[1]} is not a static function';
		return Reflect.callMethod(cls, f, arr(a[2]));
	}

	static function switchState(a:Array<Dynamic>):Dynamic {
		var cls = resolveClass(str(a[0]));
		if (cls == null) throw 'class not found: ${a[0]}';
		clearObjects();
		FlxG.switchState(Type.createInstance(cls, arr(a[1])));
		return null;
	}

	static function makeSprite(a:Array<Dynamic>):Dynamic {
		var s = new FlxSprite(num(a, 1, 0), num(a, 2, 0));
		if (has(a, 3)) s.loadGraphic(str(a[3]));
		hxObjects.set(str(a[0]), s);
		return a[0];
	}

	static function makeGraphic(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var s:FlxSprite = hxObjects.get(tag);
		if (s == null) {
			s = new FlxSprite();
			hxObjects.set(tag, s);
		}
		s.makeGraphic(Std.int(num(a, 1, 10)), Std.int(num(a, 2, 10)), toColor(has(a, 3) ? a[3] : "WHITE"));
		return tag;
	}

	static function loadGraphic(a:Array<Dynamic>):Dynamic {
		var s:FlxSprite = getObj(a[0]);
		s.loadGraphic(str(a[1]), has(a, 2) && a[2] == true, Std.int(num(a, 3, 0)), Std.int(num(a, 4, 0)));
		return null;
	}

	static function makeText(a:Array<Dynamic>):Dynamic {
		var t = new FlxText(num(a, 2, 0), num(a, 3, 0), num(a, 4, 0), str(a[1]), Std.int(num(a, 5, 8)));
		hxObjects.set(str(a[0]), t);
		return a[0];
	}

	static function screenCenter(a:Array<Dynamic>):Dynamic {
		var o:FlxSprite = getObj(a[0]);
		var axes = has(a, 1) ? str(a[1]).toLowerCase() : "xy";
		if (axes == "x") o.screenCenter(flixel.util.FlxAxes.X);
		else if (axes == "y") o.screenCenter(flixel.util.FlxAxes.Y);
		else o.screenCenter();
		return null;
	}

	static function addAnimation(a:Array<Dynamic>):Dynamic {
		var s:FlxSprite = getObj(a[0]);
		var frames:Array<Int> = [for (f in arr(a[2])) Std.int(f)];
		s.animation.add(str(a[1]), frames, Std.int(num(a, 3, 30)), !has(a, 4) || a[4] == true);
		return null;
	}

	static function playAnimation(a:Array<Dynamic>):Dynamic {
		var s:FlxSprite = getObj(a[0]);
		s.animation.play(str(a[1]), has(a, 2) && a[2] == true, has(a, 3) && a[3] == true, Std.int(num(a, 4, 0)));
		return null;
	}

	static function tween(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var target = getObj(a[1]);
		var props:Dynamic = val(a[2]);
		var duration = num(a, 3, 1);
		var o:Dynamic = has(a, 4) ? val(a[4]) : {};
		var opts:Dynamic = {};

		if (o.ease != null) {
			var ease = Reflect.field(FlxEase, str(o.ease));
			if (ease == null) throw 'unknown ease: ${o.ease}';
			opts.ease = ease;
		}
		if (o.startDelay != null) opts.startDelay = o.startDelay;
		if (o.loopDelay != null) opts.loopDelay = o.loopDelay;
		if (o.type != null) {
			opts.type = switch (str(o.type).toLowerCase()) {
				case "persist": 1;
				case "looping", "loop": 2;
				case "pingpong": 4;
				case "oneshot": 8;
				case "backward": 16;
				default: throw 'unknown tween type: ${o.type}';
			};
		}
		var onComplete = o.onComplete;
		var onUpdate = o.onUpdate;
		var onStart = o.onStart;
		opts.onComplete = function(_) {
			if (tag != null) tweens.remove(tag);
			invoke(onComplete, [tag]);
		};
		if (onUpdate != null) opts.onUpdate = function(_) invoke(onUpdate, [tag]);
		if (onStart != null) opts.onStart = function(_) invoke(onStart, [tag]);

		if (tag != null) cancelTween(tag);
		var tw = FlxTween.tween(target, props, duration, opts);
		if (tag != null) tweens.set(tag, tw);
		return tag;
	}

	static function cancelTween(tag:String):Void {
		var t = tweens.get(tag);
		if (t != null) {
			t.cancel();
			tweens.remove(tag);
		}
	}

	static function startTimer(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var cb = a[2];
		cancelTimer(tag);
		var timer = new FlxTimer();
		timers.set(tag, timer);
		timer.start(num(a, 1, 1), function(t:FlxTimer) {
			if (t.finished) timers.remove(tag);
			invoke(cb, [tag, t.loopsLeft]);
		}, Std.int(num(a, 3, 1)));
		return tag;
	}

	static function cancelTimer(tag:String):Void {
		var t = timers.get(tag);
		if (t != null) {
			t.cancel();
			timers.remove(tag);
		}
	}
}
