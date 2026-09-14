-- Regression test for https://github.com/ekalinin/SpaceName/issues/13
--
-- Runs the spoon against a mocked `hs` global under LuaJIT:
--
--     luajit tests/test.lua init.lua
--
-- Covers:
--   * a space name survives ManagedSpaceID reassignment (macOS does this
--     after a reboot or a display reconfiguration)
--   * names saved by older versions under the space ID are migrated
--   * the primary space (empty uuid) can still be named
--   * menu items follow hs.screen.allScreens() order, not pairs() order
--   * window positions are saved relative to the screen and restored by
--     window id, then by app and title, then by app only
--   * save and restore visit every user space on every screen and come
--     back to the spaces that were active before
--   * the walk waits for a space to really become active and does not
--     hang when it never does

local spoonPath = arg[1] or "init.lua"

-- Mock state ----------------------------------------------------------------

local settings = {}
local displays = {}     -- hs.spaces.data_managedDisplaySpaces() result
local screens = {}      -- hs.screen.allScreens() result (ordered)
local mouseScreen = nil
local dialogAnswer = { "Cancel", "" }
local windows = {}      -- hs.window.allWindows() result
local files = {}        -- hs.json.write() destination
local lastAlert = nil
local timers = {}       -- hs.timer.doAfter() callbacks, run by flushTimers()
local visited = {}      -- hs.spaces.gotoSpace() calls
local failSpace = nil   -- hs.spaces.gotoSpace() fails for this space
local switchLag = 0     -- timer ticks before a switch takes effect
local pendingSwitch = nil

local function noop() end

local function newScreen(uuid, name, fullFrame)
    return {
        getUUID = function() return uuid end,
        name = function() return name end,
        fullFrame = function() return fullFrame end,
    }
end

local function newWindow(id, app, title, screen, frame, standard, space)
    local win = {
        space = space,
        id = function() return id end,
        title = function() return title end,
        isStandard = function() return standard ~= false end,
        screen = function() return screen end,
        frame = function() return frame end,
        application = function()
            return {
                bundleID = function() return app end,
                name = function() return app end,
            }
        end,
    }
    win.setFrame = function(_, newFrame) win.moved = newFrame end
    return win
end

local function newLogger()
    local logger = {}
    local methods = { "d", "df", "e", "ef", "i", "f", "w", "wf", "v", "vf" }
    for _, method in ipairs(methods) do
        logger[method] = noop
    end
    return logger
end

local function screenUuid(screen)
    if type(screen) == "table" then
        return screen:getUUID()
    end
    return screen
end

local function findDisplay(uuid)
    for _, display in ipairs(displays) do
        if display["Display Identifier"] == uuid then
            return display
        end
    end
    return nil
end

local function findSpace(spaceId)
    for _, display in ipairs(displays) do
        for _, space in ipairs(display.Spaces) do
            if space.ManagedSpaceID == spaceId then
                return space, display
            end
        end
    end
    return nil
end

local function isSpaceVisible(spaceId)
    local _, display = findSpace(spaceId)
    return display ~= nil
        and display["Current Space"].ManagedSpaceID == spaceId
end

local function spacesForUuid(uuid)
    local display = findDisplay(uuid)
    if display == nil then
        return nil, "screen not found"
    end
    local ids = {}
    for _, space in ipairs(display.Spaces) do
        table.insert(ids, space.ManagedSpaceID)
    end
    return ids
end

hs = {
    configdir = "/tmp/hammerspoon",
    logger = { new = newLogger },
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
        clear = function(key) settings[key] = nil end,
    },
    spaces = {
        data_managedDisplaySpaces = function() return displays end,
        spacesForScreen = function(screen)
            return spacesForUuid(screenUuid(screen))
        end,
        -- Plain hash table keyed by screen uuid, like the real module.
        allSpaces = function()
            local result = {}
            for _, screen in ipairs(screens) do
                result[screen:getUUID()] = spacesForUuid(screen:getUUID())
            end
            return result
        end,
        activeSpaceOnScreen = function(screen)
            local display = findDisplay(screenUuid(screen))
            if display == nil then
                return nil, "screen not found"
            end
            return display["Current Space"].ManagedSpaceID
        end,
        -- like the real function, the switch takes effect later
        gotoSpace = function(spaceId)
            local space, display = findSpace(spaceId)
            if space == nil or spaceId == failSpace then
                return nil, "cannot switch"
            end
            table.insert(visited, spaceId)
            if switchLag <= 0 then
                display["Current Space"] = space
                return true
            end
            pendingSwitch = {
                display = display, space = space, ticks = switchLag,
            }
            return true
        end,
        spaceType = function(spaceId)
            local space = findSpace(spaceId)
            if space == nil then
                return nil, "space not found"
            end
            return space.type == 4 and "fullscreen" or "user"
        end,
        watcher = {
            new = function() return { start = noop, stop = noop } end,
        },
    },
    screen = { allScreens = function() return screens end },
    window = {
        -- like the real function, only windows on visible spaces
        allWindows = function()
            local result = {}
            for _, win in ipairs(windows) do
                if win.space == nil or isSpaceVisible(win.space) then
                    table.insert(result, win)
                end
            end
            return result
        end,
    },
    timer = {
        doAfter = function(_, fn)
            table.insert(timers, fn)
            return { stop = noop }
        end,
    },
    json = {
        write = function(data, path) files[path] = data; return true end,
        read = function(path) return files[path] end,
    },
    alert = { show = function(msg) lastAlert = msg end },
    mouse = {
        getCurrentScreen = function() return mouseScreen end,
        absolutePosition = function() return { x = 0, y = 0 } end,
    },
    menubar = {
        new = function()
            return {
                setTitle = noop, setMenu = noop,
                delete = noop, popupMenu = noop,
            }
        end,
    },
    dialog = {
        textPrompt = function() return dialogAnswer[1], dialogAnswer[2] end,
    },
    fnutils = {
        partial = function(fn, ...)
            local args = { ... }
            return function(...) return fn(unpack(args), ...) end
        end,
    },
    spoons = { bindHotkeysToSpec = noop },
}

-- Helpers -------------------------------------------------------------------

local failures = 0

local function check(name, got, want)
    if got == want then
        print("PASS  " .. name)
        return
    end
    failures = failures + 1
    print(string.format("FAIL  %s: got %s, want %s",
        name, tostring(got), tostring(want)))
end

local function space(id, uuid, fullscreen)
    return {
        ManagedSpaceID = id, id64 = id, uuid = uuid,
        type = fullscreen and 4 or 0,
    }
end

-- Run space switch callbacks until the walk over spaces is finished.
-- Every tick moves a pending space switch one step closer to taking
-- effect, so a switch that needs several polls can be modelled.
local function flushTimers()
    while #timers > 0 do
        local fn = table.remove(timers, 1)
        if pendingSwitch ~= nil then
            pendingSwitch.ticks = pendingSwitch.ticks - 1
            if pendingSwitch.ticks <= 0 then
                pendingSwitch.display["Current Space"] = pendingSwitch.space
                pendingSwitch = nil
            end
        end
        fn()
    end
end

local function saveWindows()
    obj:_saveWindowPositions()
    flushTimers()
end

local function restoreWindows()
    obj:_restoreWindowPositions()
    flushTimers()
end

local function display(uuid, spaces, currentId)
    local current
    for _, s in ipairs(spaces) do
        if s.ManagedSpaceID == currentId then
            current = s
        end
    end
    return {
        ["Display Identifier"] = uuid,
        Spaces = spaces,
        ["Current Space"] = current,
    }
end

local function setName(name)
    dialogAnswer = { "Save", name }
    obj:_setSpaceName()
    dialogAnswer = { "Cancel", "" }
end

-- Setup ---------------------------------------------------------------------

local main = newScreen("MAIN-UUID", "Built-in")
local ext = newScreen("EXT-UUID", "External")
screens = { main }
mouseScreen = main
displays = { display("MAIN-UUID", { space(1, "") }, 1) }

obj = dofile(spoonPath)
obj:start()

-- Test 1: a name must follow the space when macOS reassigns IDs -------------

settings = {}
displays = { display("MAIN-UUID",
    { space(1, ""), space(3, "AAA"), space(4, "BBB") }, 3) }
setName("Work")
check("T1a name visible on the space it was set on",
    obj:_getSpaceIdOrNameBySpaceId(3), "Work")

-- "reboot": same spaces (same uuids), different ManagedSpaceIDs
displays = { display("MAIN-UUID",
    { space(1, ""), space(7, "AAA"), space(3, "BBB") }, 7) }
check("T1b name survives ID reassignment (uuid AAA -> id 7)",
    obj:_getSpaceIdOrNameBySpaceId(7), "Work")
check("T1c stale id does not leak the name (uuid BBB -> id 3)",
    obj:_getSpaceIdOrNameBySpaceId(3), 3)

-- Test 2: names stored by older versions under the ID are migrated ---------

settings = { ["spacenames.state.3"] = "Mail" }
check("T2a legacy name is still shown",
    obj:_getSpaceIdOrNameBySpaceId(3), "Mail")
check("T2b legacy name moved to uuid key",
    settings["spacenames.state.BBB"], "Mail")
check("T2c legacy key removed", settings["spacenames.state.3"], nil)

-- Test 3: primary space has an empty uuid and must still be nameable -------

settings = {}
displays = { display("MAIN-UUID",
    { space(1, ""), space(7, "AAA"), space(3, "BBB") }, 1) }
setName("Home")
check("T3a name on the empty-uuid space",
    obj:_getSpaceIdOrNameBySpaceId(1), "Home")
check("T3b other spaces unaffected", obj:_getSpaceIdOrNameBySpaceId(7), 7)

-- Test 4: menu lists screens in hs.screen.allScreens() order ---------------
-- allScreens() is ordered opposite to whatever pairs() yields for the uuid
-- keys, so code relying on pairs() order fails regardless of the hash seed.

settings = {}
local probe = { ["MAIN-UUID"] = true, ["EXT-UUID"] = true }
local firstByPairs = next(probe)
if firstByPairs == "MAIN-UUID" then
    screens = { ext, main }
else
    screens = { main, ext }
end
local first, second = screens[1], screens[2]
print("pairs() yields " .. firstByPairs .. " first; allScreens() order: "
    .. first:getUUID() .. ", " .. second:getUUID())

displays = {
    display("MAIN-UUID", { space(1, ""), space(7, "AAA") }, 1),
    display("EXT-UUID", { space(21, "CCC"), space(22, "DDD") }, 21),
}
hs.settings.set("spacenames.state.MonitorMode", "1")
mouseScreen = first
setName("One")
mouseScreen = second
setName("Two")
local items = obj:_getMenuItems()
check("T4a first menu item belongs to the first screen",
    items[1].title, "1:1 - One")
check("T4b third menu item belongs to the second screen",
    items[3].title, "2:1 - Two")

hs.settings.set("spacenames.state.MonitorMode", "0")
items = obj:_getMenuItems()
check("T4c single monitor mode shows the first screen",
    items[1].title, "1 - One")
check("T4d single monitor mode shows only the first screen",
    items[3].title, "-")

-- Test 5: window positions are saved per screen and restored ---------------

local function frame(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

local function menuTitles(menuItems)
    local titles = {}
    for _, item in ipairs(menuItems) do
        titles[item.title] = true
    end
    return titles
end

-- external screen sits to the right of the main one and is shifted up
local mainScreen = newScreen("MAIN-UUID", "Built-in", frame(0, 0, 1440, 900))
local extScreen = newScreen("EXT-UUID", "External",
    frame(1440, -540, 2560, 1440))
screens = { mainScreen, extScreen }

local term = newWindow(11, "com.iterm2", "zsh", extScreen,
    frame(1540, -490, 800, 600))
local notes = newWindow(12, "md.obsidian", "Notes", mainScreen,
    frame(10, 20, 700, 500))
local popup = newWindow(13, "com.iterm2", "", extScreen,
    frame(0, 0, 100, 10), false)
windows = { term, notes, popup }

saveWindows()
local saved = files[obj.windowsFile]
check("T5a save writes to obj.windowsFile",
    obj.windowsFile, "/tmp/hammerspoon/SpaceName.windows.json")
check("T5b non-standard windows are skipped", #saved, 2)
check("T5c screen uuid is saved", saved[1].screen, "EXT-UUID")
check("T5d frame is relative to the screen origin (x)",
    saved[1].frame.x, 100)
check("T5e frame is relative to the screen origin (y)",
    saved[1].frame.y, 50)
check("T5f app bundle id is saved", saved[1].app, "com.iterm2")
check("T5g save shows a summary", lastAlert, "SpaceName: saved 2 windows")

-- the external screen is reconnected at a different offset
extScreen = newScreen("EXT-UUID", "External", frame(1440, 0, 2560, 1440))
screens = { mainScreen, extScreen }
term = newWindow(11, "com.iterm2", "zsh", mainScreen, frame(0, 0, 800, 600))
windows = { term, notes }
restoreWindows()
check("T5h window follows the screen (x)", term.moved.x, 1540)
check("T5i window follows the screen (y)", term.moved.y, 50)
check("T5j window size is restored", term.moved.w, 800)
check("T5k restore shows a summary",
    lastAlert, "SpaceName: restored 2 of 2 windows")

-- "app restart": ids changed, title matches
term = newWindow(99, "com.iterm2", "zsh", mainScreen, frame(0, 0, 10, 10))
windows = { term }
restoreWindows()
check("T5l window matched by app and title", term.moved.x, 1540)

-- "reboot": ids and titles changed, only the app matches
term = newWindow(98, "com.iterm2", "~ (bash)", mainScreen,
    frame(0, 0, 10, 10))
windows = { term }
restoreWindows()
check("T5m window matched by app only", term.moved.x, 1540)

-- same id but another app: the id is stale, fall back to app matching
local swappedA = newWindow(12, "com.iterm2", "zsh", mainScreen,
    frame(0, 0, 10, 10))
local swappedB = newWindow(11, "md.obsidian", "Notes", mainScreen,
    frame(0, 0, 10, 10))
windows = { swappedA, swappedB }
restoreWindows()
check("T5n stale id does not move a window of another app",
    swappedA.moved.x, 1540)
check("T5o stale id does not move a window of another app",
    swappedB.moved.x, 10)

-- id match wins over title match, even for a later entry
local byIdA = newWindow(12, "com.iterm2", "Notes", mainScreen,
    frame(0, 0, 10, 10))
local byIdB = newWindow(11, "com.iterm2", "zsh", mainScreen,
    frame(0, 0, 10, 10))
windows = { byIdA, byIdB }
files[obj.windowsFile] = {
    { id = 11, app = "com.iterm2", title = "Notes", screen = "MAIN-UUID",
      frame = frame(1, 1, 10, 10) },
    { id = 12, app = "com.iterm2", title = "zsh", screen = "MAIN-UUID",
      frame = frame(2, 2, 10, 10) },
}
restoreWindows()
check("T5p id match wins over title match (first entry)", byIdB.moved.x, 1)
check("T5q id match wins over title match (second entry)", byIdA.moved.x, 2)

-- saved screen is not connected: window stays where it is
screens = { mainScreen }
term = newWindow(11, "com.iterm2", "zsh", mainScreen, frame(0, 0, 10, 10))
windows = { term }
files[obj.windowsFile] = saved
restoreWindows()
check("T5r window on a missing screen is skipped", term.moved, nil)
check("T5s missing screen is reported",
    lastAlert, "SpaceName: restored 0 of 2 windows")

-- nothing saved yet
files[obj.windowsFile] = nil
restoreWindows()
check("T5t restore without a file is reported",
    lastAlert, "SpaceName: no saved window positions")

local titles = menuTitles(obj:_getMenuItems())
check("T5u save menu item exists", titles["Save window positions"], true)
check("T5v restore menu item exists",
    titles["Restore window positions"], true)

-- Test 6: every user space on every screen is visited --------------------
-- main: space 1 (active), 7, 8 (fullscreen); ext: 21, 22 (active)

screens = { mainScreen, extScreen }
displays = {
    display("MAIN-UUID",
        { space(1, ""), space(7, "AAA"), space(8, "FFF", true) }, 1),
    display("EXT-UUID", { space(21, "CCC"), space(22, "DDD") }, 22),
}
local here = newWindow(31, "com.apple.Safari", "Docs", mainScreen,
    frame(10, 10, 500, 400), true, 1)
local away = newWindow(32, "md.obsidian", "Notes", mainScreen,
    frame(20, 20, 600, 500), true, 7)
local extHere = newWindow(33, "com.iterm2", "zsh", extScreen,
    frame(1500, 100, 800, 600), true, 22)
local extAway = newWindow(34, "com.iterm2", "logs", extScreen,
    frame(1600, 200, 800, 600), true, 21)
windows = { here, away, extHere, extAway }
files = {}
visited = {}

obj:_saveWindowPositions()
obj:_saveWindowPositions()
check("T6a second call during the walk is rejected",
    lastAlert, "SpaceName: busy, try again later")
flushTimers()
saved = files[obj.windowsFile]
check("T6b windows on all spaces are saved", #saved, 4)
check("T6c save shows a summary", lastAlert, "SpaceName: saved 4 windows")
check("T6d other user spaces are visited, fullscreen ones are not, "
    .. "and the active ones are restored",
    table.concat(visited, ","), "7,1,21,22")
check("T6e main screen is back on its space",
    displays[1]["Current Space"].ManagedSpaceID, 1)
check("T6f external screen is back on its space",
    displays[2]["Current Space"].ManagedSpaceID, 22)
local extCount = 0
for _, entry in ipairs(saved) do
    if entry.id == 33 then extCount = extCount + 1 end
end
check("T6g a window visible during several visits is saved once",
    extCount, 1)

visited = {}
restoreWindows()
check("T6h window on another space is restored", away.moved.x, 20)
check("T6i window on another space of the external screen is restored",
    extAway.moved.x, 1600)
check("T6j restore shows a summary",
    lastAlert, "SpaceName: restored 4 of 4 windows")
check("T6k restore visits the same spaces",
    table.concat(visited, ","), "7,1,21,22")

-- a window positioned during an earlier visit stays visible on its
-- screen and must not be taken by an app-only match later
files[obj.windowsFile] = {
    { id = 1, app = "com.iterm2", title = "zsh", screen = "EXT-UUID",
      frame = frame(60, 0, 10, 10) },
    { id = 2, app = "com.iterm2", title = "logs", screen = "MAIN-UUID",
      frame = frame(160, 0, 10, 10) },
}
local termX = newWindow(91, "com.iterm2", "zsh", extScreen,
    frame(0, 0, 10, 10), true, 22)
local termY = newWindow(92, "com.iterm2", "xyz", mainScreen,
    frame(0, 0, 10, 10), true, 7)
windows = { termX, termY }
restoreWindows()
check("T6l window matched on an earlier visit keeps its position",
    termX.moved.x, 1500)
check("T6m remaining entry goes to the remaining window", termY.moved.x, 160)

-- a space that cannot be switched to is skipped
windows = { here, away, extHere, extAway }
files[obj.windowsFile] = saved
visited = {}
failSpace = 21
extAway.moved = nil
restoreWindows()
failSpace = nil
check("T6n unreachable space is skipped",
    table.concat(visited, ","), "7,1")
check("T6o window on the unreachable space is not moved",
    extAway.moved, nil)
check("T6p restore reports the skipped window",
    lastAlert, "SpaceName: restored 3 of 4 windows")

-- Test 7: the walk waits for a space to really become active -------------

screens = { mainScreen }
displays = { display("MAIN-UUID", { space(1, ""), space(7, "AAA") }, 1) }
local away2 = newWindow(41, "com.apple.Safari", "Docs", mainScreen,
    frame(10, 10, 500, 400), true, 7)
windows = { away2 }
files = {}
visited = {}

-- a switch that needs several polls: a single fixed pause would visit
-- the space too early and save nothing
switchLag = 3
saveWindows()
switchLag = 0
check("T7a a slow switch is awaited", #files[obj.windowsFile], 1)
check("T7b the walk comes back to the space it started on",
    displays[1]["Current Space"].ManagedSpaceID, 1)

-- a switch that never takes effect must not hang the walk
switchLag = 1000
obj.spaceSwitchTimeout = 0.2
files = {}
saveWindows()
obj.spaceSwitchTimeout = 5
switchLag = 0
pendingSwitch = nil
check("T7c a stuck switch times out and the walk still finishes",
    lastAlert, "SpaceName: saved 0 windows")
check("T7d the busy flag is cleared after a timeout", obj.walking, false)

-- Summary -------------------------------------------------------------------

if failures > 0 then
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
print("ALL PASSED")
