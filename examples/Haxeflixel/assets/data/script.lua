local SPEED = 220
local seconds = 0
local hits = 0
local wasOverlapping = false

function onCreate()
    print("[test] onCreate")

    setProperty("FlxG.camera.bgColor", getColor("0xFF1B1B2F"))
    cameraFlash("WHITE", 0.6)

    makeGraphic("player", 48, 48, "0xFFE94560")
    screenCenter("player")
    add("player")

    createObject("enemy", "FlxSprite", {420, 160})
    makeGraphic("enemy", 64, 64, "CYAN")
    add("enemy")

    makeText("label", "Hello from Lua!", 10, 10, 620, 16)
    add("label")

    makeText("help", "WASD / arrows: move | SPACE: shake | R: reset | click: move enemy", 10, 456, 620, 10)
    add("help")

    tween("pulse", "player.scale", {x = 1.25, y = 1.25}, 0.6, {
        ease = "quadOut",
        type = "pingpong",
    })

    setProperty("enemy.alpha", 0)
    tween("fadein", "enemy", {alpha = 1}, 1.0, {
        ease = "quadOut",
        onComplete = function(tag) print("[test] tween finished:", tag) end,
    })

    startTimer("tick", 1, function(tag, loopsLeft)
        seconds = seconds + 1
        print(string.format("[test] timer '%s' -> %d s", tag, seconds))
    end, 0)

    startTimer("hello", 2, "onHelloTimer")

    print("[test] FlxG.width =", getProperty("FlxG.width"))
    print("[test] lerp(0, 10, 0.5) =", callMethodFromClass("FlxMath", "lerp", {0, 10, 0.5}))
    print("[test] random int:", getRandomInt(1, 6), "random float:", getRandomFloat(0, 1))

    local ok, err = pcall(getProperty, "does.not.exist")
    print("[test] pcall with invalid path ->", ok, err)

    local ok2, err2 = pcall(createObject, "x", "No.Such.Class", {})
    print("[test] pcall with invalid class ->", ok2, err2)
end

function onHelloTimer(tag)
    print("[test] named timer fired:", tag)
    setProperty("label.text", "Named timer OK")
end

local function moveAxis(neg1, neg2, pos1, pos2)
    local d = 0
    if keyPressed(neg1) or keyPressed(neg2) then d = d - 1 end
    if keyPressed(pos1) or keyPressed(pos2) then d = d + 1 end
    return d
end

function onUpdate(elapsed)
    local dx = moveAxis("A", "LEFT", "D", "RIGHT")
    local dy = moveAxis("W", "UP", "S", "DOWN")
    if dx ~= 0 then setProperty("player.x", getProperty("player.x") + dx * SPEED * elapsed) end
    if dy ~= 0 then setProperty("player.y", getProperty("player.y") + dy * SPEED * elapsed) end

    if keyJustPressed("SPACE") then
        cameraShake(0.02, 0.3)
    end

    if keyJustPressed("R") then
        screenCenter("player")
        hits = 0
        setProperty("enemy.x", 420)
        setProperty("enemy.y", 160)
    end

    if mouseJustPressed("left") then
        setProperty("enemy.x", mouseX() - getProperty("enemy.width") / 2)
        setProperty("enemy.y", mouseY() - getProperty("enemy.height") / 2)
    end

    local overlapping = overlaps("player", "enemy")
    if overlapping and not wasOverlapping then
        hits = hits + 1
        setProperty("enemy.color", getColor(getRandomBool(50) and "YELLOW" or "LIME"))
        cameraFlash("0x55FFFFFF", 0.15)
    end
    wasOverlapping = overlapping

    setProperty("label.text", string.format(
        "x=%.0f y=%.0f | hits=%d | t=%ds | fps=%.0f",
        getProperty("player.x"), getProperty("player.y"), hits, seconds, 1 / math.max(elapsed, 0.0001)))
end