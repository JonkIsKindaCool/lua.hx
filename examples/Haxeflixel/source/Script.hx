package;

import haxe.ds.StringMap;
import openfl.Assets;
import luahx.Lua;

class Script extends Lua {
    public function new(file:String) {
        super(true);
        
        ScriptCallbacks.register(this);

        doString(Assets.getText(file));
    }
}