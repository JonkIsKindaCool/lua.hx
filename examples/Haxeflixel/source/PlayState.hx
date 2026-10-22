package;

import flixel.FlxState;

class PlayState extends FlxState {
	var script:Script;

	override public function create() {
		super.create();

		script = new Script("assets/data/script.lua");
		ScriptCallbacks.call("onCreate", []);
	}

	override public function update(elapsed:Float) {
		super.update(elapsed);
		ScriptCallbacks.call("onUpdate", [elapsed]);
	}

	override public function destroy() {
		ScriptCallbacks.call("onDestroy");
		ScriptCallbacks.clearObjects();
		script = null;
		super.destroy();
	}
}
