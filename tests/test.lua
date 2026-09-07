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

local spoonPath = arg[1] or "init.lua"

-- Mock state ----------------------------------------------------------------

local settings = {}
local displays = {}     -- hs.spaces.data_managedDisplaySpaces() result
local screens = {}      -- hs.screen.allScreens() result (ordered)
local mouseScreen = nil
local dialogAnswer = { "Cancel", "" }

local function noop() end

local function newScreen(uuid, name)
    return {
        getUUID = function() return uuid end,
        name = function() return name end,
    }
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
        gotoSpace = noop,
        watcher = {
            new = function() return { start = noop, stop = noop } end,
        },
    },
    screen = { allScreens = function() return screens end },
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

local function space(id, uuid)
    return { ManagedSpaceID = id, id64 = id, type = 0, uuid = uuid }
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

-- Summary -------------------------------------------------------------------

if failures > 0 then
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
print("ALL PASSED")
