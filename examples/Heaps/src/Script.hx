package;

import hxd.Res;
import haxe.Resource;
import haxe.ds.StringMap;
import luahx.Lua;

class Script extends Lua {
    public function new(file:String) {
        super(true);
        
        ScriptCallbacks.register(this);

        doString(Res.load(file).toText());
    }
}