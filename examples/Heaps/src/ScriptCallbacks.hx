package;

import haxe.ds.StringMap;
import h2d.Object;
import h2d.Scene;
import h2d.Bitmap;
import h2d.Text;
import h2d.Tile;
import h2d.Anim;
import h2d.col.Bounds;
import h2d.Font;
import hxd.Window;
import hxd.Key;
import hxd.Res;
import hxd.Event;
import luahx.Lua;
import luahx.vm.LObject.LuaError;
import luahx.vm.LObject.LuaFunction;

class ScriptCallbacks {
	public static var lua:Script;
	public static var scene:Scene;
	public static var defaultFont:Font;
	public static var hxObjects:StringMap<Dynamic> = new StringMap();
	public static var onError:String->Void = function(msg) trace("[lua] " + msg);

	static var timers:StringMap<TimerData> = new StringMap();
	static var tweens:StringMap<TweenData> = new StringMap();
	static var activeAnims:StringMap<Anim> = new StringMap();
	static var overlay:Null<Bitmap> = null;
	static var music:Null<hxd.snd.Channel> = null;
	static var activeShake:Null<ShakeData> = null;
	static var autoTweenId:Int = 0;
	static var _animFrames:StringMap<Array<Tile>> = new StringMap();
	static var mouseInitialized:Bool = false;

	static var colorNames:StringMap<Int> = [
		"WHITE" => 0xFFFFFFFF,
		"BLACK" => 0xFF000000,
		"RED" => 0xFFFF0000,
		"GREEN" => 0xFF00FF00,
		"BLUE" => 0xFF0000FF,
		"CYAN" => 0xFF00FFFF,
		"MAGENTA" => 0xFFFF00FF,
		"YELLOW" => 0xFFFFFF00,
		"GRAY" => 0xFF808080,
	];

	static var easings:StringMap<Float->Float> = [
		"linear" => t -> t,
		"quadin" => t -> t * t,
		"quadout" => t -> t * (2 - t),
		"quadinout" => t -> t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t,
		"cubicin" => t -> t * t * t,
		"cubicout" => t -> {
			var u = t - 1;
			u * u * u + 1;
		},
		"cubicinout" => t -> t < 0.5 ? 4 * t * t * t : {var u = 2 * t - 2; 0.5 * u * u * u + 1;},
		"sinein" => t -> 1 - Math.cos(t * Math.PI / 2),
		"sineout" => t -> Math.sin(t * Math.PI / 2),
		"sineinout" => t -> -(Math.cos(Math.PI * t) - 1) / 2,
		"expoin" => t -> t == 0 ? 0.0 : Math.pow(2, 10 * (t - 1)),
		"expoout" => t -> t == 1 ? 1.0 : 1 - Math.pow(2, -10 * t),
		"backin" => t -> t * t * (2.70158 * t - 1.70158),
		"backout" => t -> {
			var u = t - 1;
			u * u * (2.70158 * u + 1.70158) + 1;
		},
		"bounceout" => t -> {
			if (t < 1 / 2.75)
				7.5625 * t * t;
			else if (t < 2 / 2.75) {
				var u = t - 1.5 / 2.75;
				7.5625 * u * u + 0.75;
			} else if (t < 2.5 / 2.75) {
				var u = t - 2.25 / 2.75;
				7.5625 * u * u + 0.9375;
			} else {
				var u = t - 2.625 / 2.75;
				7.5625 * u * u + 0.984375;
			}
		},
	];

	public static var classAliases:StringMap<String> = [
		"Object" => "h2d.Object",
		"Scene" => "h2d.Scene",
		"Bitmap" => "h2d.Bitmap",
		"Text" => "h2d.Text",
		"Tile" => "h2d.Tile",
		"Anim" => "h2d.Anim",
		"Font" => "h2d.Font",
		"Bounds" => "h2d.col.Bounds",
		"Window" => "hxd.Window",
		"Key" => "hxd.Key",
		"Res" => "hxd.Res",
		"Sound" => "hxd.snd.Sound",
	];

	public static function register(lua:Script):Void {
		ScriptCallbacks.lua = lua;
		initMouse();

		reg("createObject", createObject);
		reg("getObject", function(a) return getObj(a[0]));
		reg("hasObject", function(a) return hxObjects.exists(str(a[0])));
		reg("removeObject", removeObject);
		reg("destroyObject", destroyObject);
		reg("clearObjects", function(a) {
			clearObjects();
			return null;
		});

		reg("getProperty", function(a) return getProperty(str(a[0])));
		reg("setProperty", function(a) {
			setProperty(str(a[0]), val(a[1]));
			return null;
		});
		reg("getPropertyFromClass", function(a) return getProperty(str(a[0]) + "." + str(a[1])));
		reg("setPropertyFromClass", function(a) {
			setProperty(str(a[0]) + "." + str(a[1]), val(a[2]));
			return null;
		});
		reg("callMethod", function(a) return callMethod(str(a[0]), arr(a[1])));
		reg("callMethodFromClass", callMethodFromClass);

		reg("add", function(a) {
			scene.addChild(cast getObj(a[0]));
			return null;
		});
		reg("insert", function(a) {
			scene.addChildAt(cast getObj(a[1]), Std.int(num(a, 0, 0)));
			return null;
		});
		reg("remove", function(a) {
			(cast getObj(a[0]) : h2d.Object).remove();
			return null;
		});
		reg("addToGroup", function(a) {
			(cast getObj(a[0]) : h2d.Object).addChild(cast getObj(a[1]));
			return null;
		});
		reg("resetState", function(a) {
			clearObjects();
			if (scene != null)
				scene.removeChildren();
			return null;
		});

		reg("makeSprite", makeSprite);
		reg("makeGraphic", makeGraphic);
		reg("resizeGraphic", resizeGraphic);
		reg("loadGraphic", loadGraphic);
		reg("makeText", makeText);
		reg("screenCenter", screenCenter);
		reg("addAnimation", addAnimation);
		reg("playAnimation", playAnimation);
		reg("overlaps", overlaps);

		reg("tween", tween);
		reg("cancelTween", function(a) {
			cancelTween(str(a[0]));
			return null;
		});
		reg("startTimer", startTimer);
		reg("cancelTimer", function(a) {
			cancelTimer(str(a[0]));
			return null;
		});

		reg("cameraShake", cameraShake);
		reg("cameraFlash", cameraFlash);
		reg("cameraFade", cameraFade);

		reg("playSound", playSound);
		reg("playMusic", playMusic);
		reg("stopMusic", function(a) {
			stopMusic();
			return null;
		});

		reg("keyPressed", function(a) return Key.isDown(toKey(a[0])));
		reg("keyJustPressed", function(a) return Key.isPressed(toKey(a[0])));
		reg("keyJustReleased", function(a) return Key.isReleased(toKey(a[0])));
		reg("mouseX", function(a) return Window.getInstance().mouseX);
		reg("mouseY", function(a) return Window.getInstance().mouseY);
		reg("mouseScreenX", function(a) return Window.getInstance().mouseX);
		reg("mouseScreenY", function(a) return Window.getInstance().mouseY);
		reg("mousePressed", function(a) return MouseState.isDown(toMouseBtn(a[0])));
		reg("mouseJustPressed", function(a) return MouseState.isPressed(toMouseBtn(a[0])));

		reg("getColor", function(a) return toColor(a[0]));
		reg("getRandomInt", function(a) {
			var mn = Std.int(num(a, 0, 0)), mx = Std.int(num(a, 1, 100));
			return mn + Std.random(mx - mn + 1);
		});
		reg("getRandomFloat", function(a) {
			var mn = num(a, 0, 0), mx = num(a, 1, 1);
			return mn + Math.random() * (mx - mn);
		});
		reg("getRandomBool", function(a) return Math.random() < num(a, 0, 50) / 100);
		reg("lerp", function(a) return lerp(num(a, 0, 0), num(a, 1, 1), num(a, 2, 0.5)));
		reg("clamp", function(a) {
			var v = num(a, 0, 0), lo = num(a, 1, 0), hi = num(a, 2, 1);
			return v < lo ? lo : (v > hi ? hi : v);
		});
		reg("assetExists", function(a) {
			try {
				Res.load(str(a[0]));
				return true;
			} catch (_)
				return false;
		});
		reg("getAssetText", function(a) {
			try {
				return Res.load(str(a[0])).toText();
			} catch (_)
				throw 'asset not found: ${a[0]}';
		});
		reg("debugPrint", function(a) {
			trace([for (x in a) Std.string(x)].join("\t"));
			return null;
		});
	}

	static function initMouse():Void {
		if (mouseInitialized)
			return;
		Window.getInstance().addEventTarget(function(e:Event) {
			switch (e.kind) {
				case EPush:
					MouseState.setPressed(e.button, true);
				case ERelease:
					MouseState.setPressed(e.button, false);
				default:
			}
		});
		mouseInitialized = true;
	}

	public static function resetMouseState():Void {
		MouseState.reset();
	}

	static inline function lerp(a:Float, b:Float, t:Float):Float
		return a + (b - a) * t;

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
		if (f == null)
			return null;
		return invoke(f, args);
	}

	public static function invoke(cb:Dynamic, ?args:Array<Dynamic>):Dynamic {
		if (cb == null)
			return null;
		if (Std.isOfType(cb, String))
			cb = lua.getGlobal(cb);
		if (!Std.isOfType(cb, LuaFunction))
			return null;
		try {
			var r = lua.call(cb, args == null ? [] : args);
			return r.length > 0 ? r[0] : null;
		} catch (e:LuaError) {
			onError(e.toString());
			return null;
		}
	}

	public static function update(dt:Float):Void {
		for (tag in [for (k in timers.keys()) k]) {
			var t = timers.get(tag);
			if (t == null)
				continue;
			t.elapsed += dt;
			var safeDur = Math.max(t.duration, 0.0001);
			while (t.elapsed >= safeDur) {
				t.elapsed -= safeDur;
				var cb = t.cb;
				var loopsLeft = t.loopsLeft;
				if (loopsLeft > 1)
					t.loopsLeft--;
				else
					timers.remove(tag);
				invoke(cb, [tag, loopsLeft]);
				if (!timers.exists(tag))
					break;
			}
		}

		for (tag in [for (k in tweens.keys()) k]) {
			var t = tweens.get(tag);
			if (t == null)
				continue;
			if (!t.started) {
				t.started = true;
				if (t.onStart != null)
					invoke(t.onStart, [tag]);
			}
			t.elapsed += dt;
			var p = t.duration > 0 ? Math.min(1.0, t.elapsed / t.duration) : 1.0;
			var ep = t.ease(p);
			for (prop in t.props) {
				Reflect.setProperty(t.target, prop.name, prop.from + (prop.to - prop.from) * ep);
			}
			if (t.onUpdate != null)
				invoke(t.onUpdate, [tag]);
			if (p >= 1.0) {
				if (t.loop) {
					t.elapsed = 0;
				} else {
					tweens.remove(tag);
					if (t.onComplete != null)
						invoke(t.onComplete, [tag]);
				}
			}
		}

		if (activeShake != null && scene != null) {
			activeShake.elapsed += dt;
			if (activeShake.elapsed >= activeShake.duration) {
				scene.x = activeShake.ox;
				scene.y = activeShake.oy;
				activeShake = null;
			} else {
				var decay = 1.0 - activeShake.elapsed / activeShake.duration;
				var i = activeShake.intensity * decay;
				scene.x = activeShake.ox + (Math.random() * 2 - 1) * i;
				scene.y = activeShake.oy + (Math.random() * 2 - 1) * i;
			}
		}
	}

	public static function clearObjects():Void {
		timers.clear();
		tweens.clear();
		activeAnims.clear();
		_animFrames.clear();
		for (tag in [for (k in hxObjects.keys()) k])
			destroyObject([tag]);
		hxObjects.clear();
		if (activeShake != null && scene != null) {
			scene.x = activeShake.ox;
			scene.y = activeShake.oy;
			activeShake = null;
		}
	}

	static inline function has(a:Array<Dynamic>, i:Int):Bool
		return i < a.length && a[i] != null;

	static inline function truthy(v:Dynamic):Bool {
		if (v == null)
			return false;
		if (Std.isOfType(v, Bool))
			return v;
		if (Std.isOfType(v, Int) || Std.isOfType(v, Float))
			return v != 0;
		return true;
	}

	static inline function str(v:Dynamic):String
		return v == null ? null : Std.string(v);

	static function num(a:Array<Dynamic>, i:Int, def:Float):Float
		return has(a, i) ? (a[i] : Float) : def;

	static function val(v:Dynamic):Dynamic
		return lua.toHaxe(v, true);

	static function arr(v:Dynamic):Array<Dynamic> {
		if (v == null)
			return [];
		var d = val(v);
		return Std.isOfType(d, Array) ? d : [d];
	}

	public static function resolveClass(name:String):Class<Dynamic> {
		var full = classAliases.exists(name) ? classAliases.get(name) : name;
		return Type.resolveClass(full);
	}

	public static function getObj(v:Dynamic):Dynamic {
		if (Std.isOfType(v, String)) {
			var o = hxObjects.get(v);
			if (o != null)
				return o;
			try {
				return getProperty(v);
			} catch (_)
				return null;
		}
		return v;
	}

	public static function toColor(v:Dynamic):Int {
		if (v == null)
			return 0xFFFFFFFF;

		if (Std.isOfType(v, String)) {
			var s:String = v.toUpperCase();

			if (colorNames.exists(s))
				return colorNames.get(s);

			if (s.charAt(0) == "#")
				s = s.substr(1);
			else if (s.substr(0, 2) == "0X")
				s = s.substr(2);
			if (s.length == 6)
				s = "FF" + s;
			var n = Std.parseInt("0x" + s);
			if (n == null)
				throw 'invalid color: $v';
			return n;
		}
		return Std.int(v);
	}

	static function toKey(v:Dynamic):Int {
		if (Std.isOfType(v, Int))
			return v;
		var s = str(v).toUpperCase();
		var f:Dynamic = Reflect.field(Key, s);
		if (f == null)
			throw 'unknown key: $s';
		return f;
	}

	static function toMouseBtn(v:Dynamic):Int {
		var s = str(v).toLowerCase();
		return switch (s) {
			case "left": 0;
			case "right": 1;
			case "middle", "center": 2;
			default:
				var n = Std.parseInt(s);
				n != null ? n : 0;
		}
	}

	static function tokenize(path:String):Array<Dynamic> {
		var out:Array<Dynamic> = [];
		for (part in path.split(".")) {
			var b = part.indexOf("[");
			if (b < 0) {
				out.push(part);
				continue;
			}
			if (b > 0)
				out.push(part.substr(0, b));
			var rest = part.substr(b);
			while (rest.length > 0 && rest.charAt(0) == "[") {
				var e = rest.indexOf("]");
				if (e < 0)
					throw 'malformed path: $path';
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
			if (hxObjects.exists(first))
				return {obj: hxObjects.get(first), next: 1};
			if (first == "scene")
				return {obj: scene, next: 1};
			if (first == "window")
				return {obj: Window.getInstance(), next: 1};
			if (first == "Key")
				return {obj: Key, next: 1};
			if (first == "Res")
				return {obj: Res, next: 1};
			var name = "";
			for (i in 0...tokens.length) {
				if (!Std.isOfType(tokens[i], String))
					break;
				name += (i > 0 ? "." : "") + tokens[i];
				var cls = resolveClass(name);
				if (cls != null)
					return {obj: cls, next: i + 1};
			}
		}
		return {obj: scene, next: 0};
	}

	static function step(obj:Dynamic, t:Dynamic):Dynamic {
		if (obj == null)
			throw 'null object while accessing "$t"';
		if (Std.isOfType(t, Int)) {
			if (Std.isOfType(obj, Array))
				return (cast obj : Array<Dynamic>)[t];
			throw 'cannot index non-array with [$t]';
		}
		if (Std.isOfType(obj, haxe.Constraints.IMap))
			return (cast obj : haxe.Constraints.IMap<Dynamic, Dynamic>).get(t);
		return Reflect.getProperty(obj, t);
	}

	public static function getProperty(path:String):Dynamic {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		for (i in root.next...tokens.length)
			obj = step(obj, tokens[i]);
		return obj;
	}

	public static function setProperty(path:String, value:Dynamic):Void {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		if (root.next >= tokens.length)
			throw 'cannot assign to "$path": it is an object, not a property';
		for (i in root.next...tokens.length - 1)
			obj = step(obj, tokens[i]);
		var last:Dynamic = tokens[tokens.length - 1];
		if (obj == null)
			throw 'null object while assigning "$path"';
		if (Std.isOfType(last, Int))
			(cast obj : Array<Dynamic>)
		[last] = value;
	else if (Std.isOfType(obj, haxe.Constraints.IMap))
		(cast obj : haxe.Constraints.IMap<Dynamic, Dynamic>).set(last, value);
	else
		Reflect.setProperty(obj, last, value);
	}

	public static function createObject(args:Array<Dynamic>):Dynamic {
		var tag:String = args[0];
		var type:String = args[1];
		var cargs:Array<Dynamic> = arr(args[2]);
		var cls = resolveClass(type);
		if (cls == null)
			throw 'class not found: $type';
		var obj:Dynamic = Type.createInstance(cls, cargs);
		hxObjects.set(tag, obj);
		return obj;
	}

	static function removeObject(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var obj = hxObjects.get(tag);
		if (obj == null)
			return false;
		if (Std.isOfType(obj, h2d.Object))
			(cast obj : h2d.Object).remove();
		if (!has(a, 1) || truthy(a[1]))
			destroyIfPossible(obj);
		hxObjects.remove(tag);
		return true;
	}

	static function destroyObject(a:Array<Dynamic>):Dynamic
		return removeObject([a[0], true]);

	static function destroyIfPossible(obj:Dynamic):Void {
		if (Std.isOfType(obj, h2d.Object))
			(cast obj : h2d.Object).remove();
		if (Reflect.hasField(obj, "destroy") && Reflect.isFunction(Reflect.field(obj, "destroy")))
			Reflect.callMethod(obj, Reflect.field(obj, "destroy"), []);
	}

	public static function callMethod(path:String, args:Array<Dynamic>):Dynamic {
		var tokens = tokenize(path);
		var root = resolveRoot(tokens);
		var obj:Dynamic = root.obj;
		if (root.next >= tokens.length)
			throw 'not a method path: $path';
		for (i in root.next...tokens.length - 1)
			obj = step(obj, tokens[i]);
		var name:String = tokens[tokens.length - 1];
		if (obj == null)
			throw 'null object while calling "$path"';
		var f = Reflect.field(obj, name);
		if (f == null)
			f = Reflect.getProperty(obj, name);
		if (!Reflect.isFunction(f))
			throw '"$path" is not a function';
		return Reflect.callMethod(obj, f, args);
	}

	static function callMethodFromClass(a:Array<Dynamic>):Dynamic {
		var cls = resolveClass(str(a[0]));
		if (cls == null)
			throw 'class not found: ${a[0]}';
		var f = Reflect.field(cls, str(a[1]));
		if (!Reflect.isFunction(f))
			throw '${a[0]}.${a[1]} is not a static function';
		return Reflect.callMethod(cls, f, arr(a[2]));
	}

	static function makeSprite(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var tile:Tile = has(a, 3) ? Res.load(str(a[3])).toTile() : Tile.fromColor(0xFFFFFFFF, 1, 1);
		var bmp = new Bitmap(tile);
		bmp.x = num(a, 1, 0);
		bmp.y = num(a, 2, 0);
		hxObjects.set(tag, bmp);
		return tag;
	}

	static function makeGraphic(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var bmp = new Bitmap(Tile.fromColor(toColor(has(a, 3) ? a[3] : "WHITE"), Std.int(num(a, 1, 10)), Std.int(num(a, 2, 10))));
		hxObjects.set(tag, bmp);
		return tag;
	}

	static function loadGraphic(a:Array<Dynamic>):Dynamic {
		var bmp:h2d.Bitmap = cast getObj(a[0]);
		if (bmp == null)
			throw 'object not found: ${a[0]}';
		bmp.tile = Res.load(str(a[1])).toTile();
		return null;
	}

	static function makeText(a:Array<Dynamic>):Dynamic {
		if (defaultFont == null)
			throw "ScriptCallbacks.defaultFont is not set";
		var tag = str(a[0]);
		var t = new Text(defaultFont);
		t.text = str(a[1]);
		t.x = num(a, 2, 0);
		t.y = num(a, 3, 0);
		var w = num(a, 4, 0);
		if (w > 0)
			t.maxWidth = w;
		hxObjects.set(tag, t);
		return tag;
	}

	static function screenCenter(a:Array<Dynamic>):Dynamic {
		var o:h2d.Object = cast getObj(a[0]);
		if (o == null || scene == null)
			return null;
		var axes = has(a, 1) ? str(a[1]).toLowerCase() : "xy";
		var b = o.getBounds();
		if (axes.indexOf("x") >= 0)
			o.x = (scene.width - b.width) * 0.5 - b.x;
		if (axes.indexOf("y") >= 0)
			o.y = (scene.height - b.height) * 0.5 - b.y;
		return null;
	}

	static function addAnimation(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var name = str(a[1]);
		var tiles:Array<Tile> = [for (f in arr(a[2])) Res.load(str(f)).toTile()];
		_animFrames.set(tag + "." + name, tiles);
		return null;
	}

	static function playAnimation(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var name = str(a[1]);
		var key = tag + "." + name;
		if (!_animFrames.exists(key))
			throw 'animation not found: $key';
		var tiles = _animFrames.get(key);
		var speed = num(a, 3, 30);
		var loop = !has(a, 4) || truthy(a[4]);
		var obj:h2d.Object = cast getObj(tag);
		if (obj == null)
			throw 'object not found: $tag';
		if (activeAnims.exists(key))
			activeAnims.get(key).remove();
		var anim = new Anim(tiles, speed);
		anim.loop = loop;
		anim.play(tiles, 0);
		obj.addChild(anim);
		activeAnims.set(key, anim);
		return null;
	}

	static function overlaps(a:Array<Dynamic>):Bool {
		var o1:h2d.Object = cast getObj(a[0]);
		var o2:h2d.Object = cast getObj(a[1]);
		if (o1 == null || o2 == null)
			return false;
		return o1.getBounds().intersects(o2.getBounds());
	}

	static function tween(a:Array<Dynamic>):Dynamic {
		var tag = has(a, 0) ? str(a[0]) : null;
		var target = getObj(a[1]);
		var props:Dynamic = val(a[2]);
		var duration = num(a, 3, 1);
		var o:Dynamic = has(a, 4) ? val(a[4]) : null;
		return tweenImpl(tag, target, props, duration, o);
	}

	static function tweenImpl(tag:String, target:Dynamic, props:Dynamic, duration:Float, o:Dynamic):String {
		if (tag == null)
			tag = "__auto_" + (autoTweenId++);
		cancelTween(tag);

		var t = new TweenData();
		t.tag = tag;
		t.target = target;
		t.duration = duration;

		var easeName:String = "linear";
		if (o != null) {
			var e:Dynamic = Reflect.field(o, "ease");
			if (e != null)
				easeName = str(e).toLowerCase();
		}
		t.ease = easings.exists(easeName) ? easings.get(easeName) : (x->x);

		if (o != null) {
			t.onComplete = Reflect.field(o, "onComplete");
			t.onUpdate = Reflect.field(o, "onUpdate");
			t.onStart = Reflect.field(o, "onStart");
			t.loop = truthy(Reflect.field(o, "loop"));
		}

		for (field in Reflect.fields(props)) {
			var from:Dynamic = Reflect.getProperty(target, field);
			var to:Dynamic = Reflect.field(props, field);
			var fromF = Std.parseFloat(Std.string(from));
			var toF = Std.parseFloat(Std.string(to));
			if (!Math.isNaN(fromF) && !Math.isNaN(toF))
				t.props.push({name: field, from: fromF, to: toF});
		}
		tweens.set(tag, t);
		return tag;
	}

	static function cancelTween(tag:String):Void {
		if (tag == null)
			return;
		if (tweens.exists(tag))
			tweens.remove(tag);
	}

	static function startTimer(a:Array<Dynamic>):Dynamic {
		var tag = str(a[0]);
		var delay = num(a, 1, 1);
		var cb = a[2];
		var loops = Std.int(num(a, 3, 1));
		cancelTimer(tag);
		timers.set(tag, new TimerData(delay, cb, loops));
		return tag;
	}

	static function cancelTimer(tag:String):Void {
		if (tag != null)
			timers.remove(tag);
	}

	static function ensureOverlay(color:Int):Void {
		if (scene == null)
			return;
		if (overlay == null) {
			overlay = new Bitmap(Tile.fromColor(color, 1, 1));
			scene.addChild(overlay);
		} else if (overlay.parent == null) {
			scene.addChild(overlay);
		}
		overlay.tile = Tile.fromColor(color, Std.int(scene.width), Std.int(scene.height));
		overlay.x = 0;
		overlay.y = 0;
		overlay.visible = true;
	}

	static function cameraFlash(a:Array<Dynamic>):Dynamic {
		var color = toColor(has(a, 0) ? a[0] : "WHITE");
		var duration = num(a, 1, 0.5);
		ensureOverlay(color);
		overlay.alpha = 1.0;
		tweenImpl(null, overlay, {alpha: 0.0}, duration, null);
		return null;
	}

	static function cameraFade(a:Array<Dynamic>):Dynamic {
		var color = toColor(has(a, 0) ? a[0] : "BLACK");
		var duration = num(a, 1, 0.5);
		var fadeIn = has(a, 2) && truthy(a[2]);
		ensureOverlay(color);
		overlay.alpha = fadeIn ? 1.0 : 0.0;
		tweenImpl(null, overlay, {alpha: fadeIn ? 0.0 : 1.0}, duration, null);
		return null;
	}

	static function cameraShake(a:Array<Dynamic>):Dynamic {
		var intensity = num(a, 0, 0.05) * 100.0;
		var duration = num(a, 1, 0.5);
		if (scene == null)
			return null;
		if (activeShake != null) {
			scene.x = activeShake.ox;
			scene.y = activeShake.oy;
		}
		activeShake = new ShakeData();
		activeShake.duration = duration;
		activeShake.intensity = intensity;
		activeShake.ox = scene.x;
		activeShake.oy = scene.y;
		return null;
	}

	static function playSound(a:Array<Dynamic>):Dynamic {
		var path = str(a[0]);
		var vol = num(a, 1, 1);
		var loop = has(a, 2) && truthy(a[2]);
		var snd = Res.load(path).toSound();
		var ch = snd.play(loop);
		if (ch != null)
			ch.volume = vol;
		return null;
	}

	static function playMusic(a:Array<Dynamic>):Dynamic {
		var path = str(a[0]);
		var vol = num(a, 1, 1);
		stopMusic();
		var snd = Res.load(path).toSound();
		music = snd.play(true);
		if (music != null)
			music.volume = vol;
		return null;
	}

	static function stopMusic():Void {
		if (music != null) {
			music.stop();
			music = null;
		}
	}

	static function resizeGraphic(a:Array<Dynamic>):Dynamic {
		var bmp:h2d.Bitmap = cast getObj(a[0]);
		if (bmp == null)
			throw 'object not found: ${a[0]}';
		var w = Std.int(num(a, 1, 10));
		var h = Std.int(num(a, 2, 10));
		var color = toColor(has(a, 3) ? a[3] : "WHITE");
		bmp.tile = Tile.fromColor(color, w, h);
		return null;
	}
}

private class TimerData {
	public var duration:Float;
	public var elapsed:Float = 0;
	public var loopsLeft:Int;
	public var cb:Dynamic;

	public function new(d:Float, cb:Dynamic, loops:Int) {
		duration = d;
		this.cb = cb;
		loopsLeft = loops;
	}
}

private class TweenData {
	public var tag:String;
	public var target:Dynamic;
	public var props:Array<{name:String, from:Float, to:Float}> = [];
	public var duration:Float;
	public var elapsed:Float = 0;
	public var ease:Float->Float;
	public var onComplete:Dynamic;
	public var onUpdate:Dynamic;
	public var onStart:Dynamic;
	public var started:Bool = false;
	public var loop:Bool = false;

	public function new() {}
}

private class ShakeData {
	public var elapsed:Float = 0;
	public var duration:Float;
	public var intensity:Float;
	public var ox:Float;
	public var oy:Float;

	public function new() {}
}

class MouseState {
	static var buttons:Array<Bool> = [false, false, false];
	static var justPressedButtons:Array<Bool> = [false, false, false];

	public static function setPressed(button:Int, value:Bool):Void {
		if (button < 0 || button > 2)
			return;
		if (value && !buttons[button]) {
			justPressedButtons[button] = true;
		}
		buttons[button] = value;
	}

	public static function isDown(button:Int):Bool {
		if (button < 0 || button > 2)
			return false;
		return buttons[button];
	}

	public static function isPressed(button:Int):Bool {
		if (button < 0 || button > 2)
			return false;
		return justPressedButtons[button];
	}

	public static function reset():Void {
		for (i in 0...3)
			justPressedButtons[i] = false;
	}
}
