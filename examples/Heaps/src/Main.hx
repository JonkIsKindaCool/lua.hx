import hxd.Window;
import hxd.Res;
import hxd.res.DefaultFont;
import hxd.App;

class Main extends App {
	public function new() {
		super();
	}

	static function main() {
		Res.initEmbed();
		new Main();
	}

	var lua:Script;

	override function init() {
		ScriptCallbacks.scene = s2d;
		ScriptCallbacks.defaultFont = DefaultFont.get();

		lua = new Script("script.lua");
		ScriptCallbacks.register(lua);
		ScriptCallbacks.call("onCreate");
		ScriptCallbacks.call("onResize", [Window.getInstance().width, Window.getInstance().height]);
	}

	override function update(dt:Float) {
		ScriptCallbacks.update(dt);
		ScriptCallbacks.call("onUpdate", [dt]);
		ScriptCallbacks.resetMouseState();
	}

	override function onResize() {
		super.onResize();
		ScriptCallbacks.call("onResize", [Window.getInstance().width, Window.getInstance().height]);
	}
}
