--- === SpaceName ===
---
--- Shows current space id, adds ability to set a custom name for a screen.
---
--- Download: [https://github.com/ekalinin/SpaceName](https://github.com/ekalinin/SpaceName)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SpaceName"
obj.version = "0.6.2"
obj.author = "Eugene Kalinin <e.v.kalinin@gmail.com>"
obj.homepage = "https://github.com/ekalinin/SpaceName"
obj.license = "MIT - https://opensource.org/licenses/MIT"


-- Internals

obj.log = hs.logger.new('SpaceName', 'debug')
obj.settingName = "spacenames.state."
obj.settingNameMonitorMode = obj.settingName .. "MonitorMode"
obj.windowsFile = hs.configdir .. "/SpaceName.windows.json"
obj.spacePollInterval = 0.05
obj.spaceSwitchTimeout = 5
obj.spaceSettleDelay = 0.2
obj.menu = nil
obj.watcher = nil
obj.walking = false
obj.walkTimer = nil


--
-- Private functions
--

--- Get the ID of the current space for the screen under the mouse cursor.
--- @return number spaceId The ID of the current space
function obj:_getCurrentSpaceId()
    local screen = hs.mouse.getCurrentScreen()
    local spaceId = hs.spaces.activeSpaceOnScreen(screen)
    obj.log.df("_getCurrentSpaceId: got spaceId=%s for screen=%s", spaceId, screen:name())
    return spaceId
end

--- Get the settings key for storing the custom name of a space.
--- macOS reassigns space IDs (for example after a reboot), so the key is
--- based on the space uuid when it is available. The primary space has an
--- empty uuid, so its ID is used instead.
--- @param spaceId number The space ID to look up
--- @return string The settings key for the space
function obj:_getSettingKeyBySpaceId(spaceId)
    local displays = hs.spaces.data_managedDisplaySpaces() or {}
    for _, display in ipairs(displays) do
        for _, space in ipairs(display.Spaces or {}) do
            if space.ManagedSpaceID == spaceId
                and space.uuid ~= nil and space.uuid ~= "" then
                return obj.settingName .. space.uuid
            end
        end
    end
    return obj.settingName .. tostring(spaceId)
end

--- Move a name saved by older versions under the space ID to the uuid key.
--- @param spaceId number The space ID the name was saved under
--- @param key string The settings key to move the name to
--- @return string|nil The migrated name, or nil if there was nothing to move
function obj:_migrateLegacySpaceName(spaceId, key)
    local legacyKey = obj.settingName .. tostring(spaceId)
    if legacyKey == key then
        return nil
    end
    local spaceName = hs.settings.get(legacyKey)
    if spaceName == nil then
        return nil
    end
    obj.log.df("migrateLegacySpaceName: %s -> %s", legacyKey, key)
    hs.settings.set(key, spaceName)
    hs.settings.clear(legacyKey)
    return spaceName
end

--- Get the custom name for a space by its ID, or return the ID if no name is set.
--- @param spaceId number The space ID to look up
--- @return string|number The custom name if set, otherwise the space ID
function obj:_getSpaceIdOrNameBySpaceId(spaceId)
    obj.log.df("getSpaceIdOrNameById: got space-id=%s", spaceId)
    local key = obj:_getSettingKeyBySpaceId(spaceId)
    local spaceName = hs.settings.get(key)
    if spaceName == nil then
        spaceName = obj:_migrateLegacySpaceName(spaceId, key)
    end
    obj.log.df("getSpaceIdOrNameById: find name in settings=%s", spaceName)
    if spaceName == nil then
        spaceName = spaceId
    end

    return spaceName
end

--- Get the custom name or ID for the current space.
--- @return string|number The custom name if set, otherwise the space ID
function obj:_getSpaceIdOrNameForCurrentSpace()
    local spaceId = obj:_getCurrentSpaceId()
    obj.log.df("getSpaceIdOrNameCurrent: got space-id=%s", spaceId)
    local spaceName = obj:_getSpaceIdOrNameBySpaceId(spaceId)
    obj.log.df("getSpaceIdOrNameCurrent: space-name=%s", spaceName)
    return spaceName
end

--- Get all active space names/IDs across all screens, joined by " | ".
--- @return string Concatenated space names separated by " | "
function obj:_getAllActiveSpaceNames()
    local names = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local spaceId = hs.spaces.activeSpaceOnScreen(screen)
        local spaceName = obj:_getSpaceIdOrNameBySpaceId(spaceId)
        table.insert(names, spaceName)
    end
    return table.concat(names, " | ")
end

--- Show dialog to enter custom screen name and save it in settings.
--- Displays a text prompt for the user to enter a readable name for the current space.
--- If a name is already set, it will be shown as the default value.
function obj:_setSpaceName()
    local currentName = obj:_getSpaceIdOrNameForCurrentSpace()
    if type(currentName) == "number" then
        currentName = ""
    end
    local button, newName = hs.dialog.textPrompt(
        "Screen name", "Please, enter a readable name",
        currentName,
        "Save", "Cancel"
    )
    obj.log.df("setSpaceName: new space name=%s, button=%s", newName, button)

    if button == "Save" and newName ~= '' then
        local spaceId = obj:_getCurrentSpaceId()
        hs.settings.set(obj:_getSettingKeyBySpaceId(spaceId), newName)
        obj.log.df("setSpaceName: set space name=%s for space-id=%d", newName, spaceId)

        obj:_updateMenu()
    end
end

--- Toggle between single monitor and multi-monitor mode.
--- In multi-monitor mode, all spaces across all screens are shown in the menu.
--- In single monitor mode, only spaces from the first screen are shown.
function obj:_toggleMonitorMode()
    local mode = hs.settings.get(obj.settingNameMonitorMode)
    if mode == nil or mode == "0" then
        mode = "1"
    else
        mode = "0"
    end
    hs.settings.set(obj.settingNameMonitorMode, mode)
end

--- Check if multi-monitor mode is enabled.
--- @return boolean True if multi-monitor mode is enabled, false otherwise
function obj:_isMultiMonitorMode()
    local mode = hs.settings.get(obj.settingNameMonitorMode)
    return mode == "1"
end

--- Get the key used to match a window with a saved entry.
--- @param app table hs.application object
--- @return string The app bundle id, or the app name if there is none
local function appKey(app)
    return app:bundleID() or app:name()
end

--- Describe a window for saving. The frame is stored relative to the
--- screen origin, so it can be restored when the screen arrangement
--- changes.
--- @param win table hs.window object
--- @return table|nil Entry table, or nil if the window should be skipped
function obj:_getWindowEntry(win)
    local screen = win:screen()
    local app = win:application()
    if not win:isStandard() or win:id() == nil
        or screen == nil or app == nil then
        return nil
    end
    local frame = win:frame()
    local origin = screen:fullFrame()
    return {
        id = win:id(),
        app = appKey(app),
        appName = app:name(),
        title = win:title(),
        screen = screen:getUUID(),
        frame = {
            x = frame.x - origin.x, y = frame.y - origin.y,
            w = frame.w, h = frame.h,
        },
    }
end

--- Wait until a screen really shows a space. `hs.spaces.gotoSpace()`
--- returns once the Mission Control button is pressed, but macOS reports
--- the new space only after the switch is over, so the space is polled
--- instead of pausing for a fixed time.
--- @param screen table hs.screen object
--- @param spaceId number The space that is being switched to
--- @param done function Called when the space is shown, or on timeout
function obj:_waitForSpace(screen, spaceId, done)
    local polls = 0
    local maxPolls = math.ceil(obj.spaceSwitchTimeout / obj.spacePollInterval)
    local poll
    poll = function()
        if hs.spaces.activeSpaceOnScreen(screen) == spaceId then
            -- give the window list a moment to catch up with the space
            obj.walkTimer = hs.timer.doAfter(obj.spaceSettleDelay, done)
            return
        end
        polls = polls + 1
        if polls >= maxPolls then
            obj.log.wf("waitForSpace: space %s is not active after %ss",
                spaceId, obj.spaceSwitchTimeout)
            return done()
        end
        obj.walkTimer = hs.timer.doAfter(obj.spacePollInterval, poll)
    end
    obj.walkTimer = hs.timer.doAfter(obj.spacePollInterval, poll)
end

--- Visit every user space on every screen. macOS only reports windows
--- on the spaces shown right now, so `visit()` is called while each
--- space is shown, and `done()` after the spaces that were active at
--- the start are shown again. Switching takes time, so the walk is
--- asynchronous and this function returns at once.
--- @param visit function Called once per user space
--- @param done function Called when the walk is over
function obj:_walkSpaces(visit, done)
    if obj.walking then
        hs.alert.show("SpaceName: busy, try again later")
        return
    end

    local steps = {}
    local allSpaces = hs.spaces.allSpaces() or {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        for _, id in ipairs(allSpaces[screen:getUUID()] or {}) do
            if hs.spaces.spaceType(id) == "user" then
                table.insert(steps, {
                    screen = screen, space = id, visit = true,
                })
            end
        end
        -- come back to the space that was active when the walk started
        table.insert(steps, {
            screen = screen, space = hs.spaces.activeSpaceOnScreen(screen),
        })
    end

    local i = 0
    local nextStep
    local function runStep(step)
        if step.visit then
            local ok, err = pcall(visit)
            if not ok then
                obj.log.ef("walkSpaces: %s", err)
            end
        end
        nextStep()
    end
    nextStep = function()
        i = i + 1
        local step = steps[i]
        if step == nil then
            obj.walking = false
            return done()
        end
        if hs.spaces.activeSpaceOnScreen(step.screen) == step.space then
            return runStep(step)
        end
        local ok, err = hs.spaces.gotoSpace(step.space)
        if not ok then
            obj.log.ef("walkSpaces: cannot switch to space %s: %s",
                step.space, err)
            return nextStep()
        end
        obj:_waitForSpace(step.screen, step.space,
            function() runStep(step) end)
    end

    obj.walking = true
    nextStep()
end

--- Save positions and screens of all windows on all spaces to
--- obj.windowsFile.
function obj:_saveWindowPositions()
    local entries, seen = {}, {}
    obj:_walkSpaces(function()
        for _, win in ipairs(hs.window.allWindows()) do
            local entry = obj:_getWindowEntry(win)
            if entry ~= nil and not seen[entry.id] then
                seen[entry.id] = true
                table.insert(entries, entry)
            end
        end
    end, function()
        if not hs.json.write(entries, obj.windowsFile, true, true) then
            obj.log.ef("saveWindowPositions: cannot write %s",
                obj.windowsFile)
            hs.alert.show("SpaceName: cannot save window positions")
            return
        end
        obj.log.df("saveWindowPositions: saved %d windows", #entries)
        hs.alert.show(string.format("SpaceName: saved %d windows", #entries))
    end)
end

--- Matchers ordered from strict to loose: by window id (same session),
--- by app and title (app restarted), by app only (reboot).
local windowMatchers = {
    function(candidate, entry)
        return candidate.app == entry.app and candidate.win:id() == entry.id
    end,
    function(candidate, entry)
        return candidate.app == entry.app
            and candidate.win:title() == entry.title
    end,
    function(candidate, entry)
        return candidate.app == entry.app
    end,
}

--- Remove and return the first candidate accepted by the matcher.
--- @param candidates table Array of { win = hs.window, app = string }
--- @param entry table Saved window entry
--- @param matches function Matcher from windowMatchers
--- @return table|nil hs.window object, or nil if nothing matched
local function takeMatchingWindow(candidates, entry, matches)
    for i, candidate in ipairs(candidates) do
        if matches(candidate, entry) then
            return table.remove(candidates, i).win
        end
    end
    return nil
end

--- Pair saved entries with open windows. Each matcher runs over all
--- entries before the next, looser one, so a window matched by id is
--- not taken by an app-only match of an earlier entry.
--- @param entries table Array of saved window entries
--- @param skip table Set of window ids to leave out
--- @return table Map from entry to hs.window object
function obj:_matchWindows(entries, skip)
    local candidates = {}
    for _, win in ipairs(hs.window.allWindows()) do
        local app = win:application()
        local id = win:id()
        if win:isStandard() and app ~= nil and id ~= nil and not skip[id] then
            table.insert(candidates, { win = win, app = appKey(app) })
        end
    end

    local matched = {}
    for _, matches in ipairs(windowMatchers) do
        for _, entry in ipairs(entries) do
            if matched[entry] == nil then
                matched[entry] = takeMatchingWindow(candidates, entry, matches)
            end
        end
    end
    return matched
end

--- Move a window to the frame saved relative to the screen.
--- @param win table hs.window object
--- @param entry table Saved window entry
--- @param screen table hs.screen object the entry was saved on
local function applyWindowEntry(win, entry, screen)
    local origin = screen:fullFrame()
    win:setFrame({
        x = origin.x + entry.frame.x, y = origin.y + entry.frame.y,
        w = entry.frame.w, h = entry.frame.h,
    })
end

--- Restore positions and screens of windows from obj.windowsFile on all
--- spaces. Windows stay on their current space. Entries whose screen is
--- not connected are skipped.
function obj:_restoreWindowPositions()
    local ok, entries = pcall(hs.json.read, obj.windowsFile)
    if not ok or type(entries) ~= "table" then
        obj.log.ef("restoreWindowPositions: cannot read %s", obj.windowsFile)
        hs.alert.show("SpaceName: no saved window positions")
        return
    end

    local screens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        screens[screen:getUUID()] = screen
    end
    local pending = {}
    for _, entry in ipairs(entries) do
        if screens[entry.screen] ~= nil then
            table.insert(pending, entry)
        end
    end

    local restored, handled = 0, {}
    obj:_walkSpaces(function()
        local matched = obj:_matchWindows(pending, handled)
        local rest = {}
        for _, entry in ipairs(pending) do
            local win = matched[entry]
            if win == nil then
                table.insert(rest, entry)
            else
                handled[win:id()] = true
                applyWindowEntry(win, entry, screens[entry.screen])
                restored = restored + 1
            end
        end
        pending = rest
    end, function()
        obj.log.df("restoreWindowPositions: restored %d of %d windows",
            restored, #entries)
        hs.alert.show(string.format(
            "SpaceName: restored %d of %d windows", restored, #entries))
    end)
end

--- Create and return a table of menu items for all spaces.
--- Builds menu items for switching between spaces, setting names,
--- toggling monitor mode, saving and restoring window positions, and
--- version info.
--- @return table Array of menu item tables with title, fn, checked, and disabled fields
function obj:_getMenuItems()
    obj.log.d("getMenuItems: starting ...")
    local res = {}
    local spaceId = obj:_getCurrentSpaceId()

    local screenID = 1
    local showID = 1
    -- hs.screen.allScreens() has a stable order, pairs() does not
    local allSpaces = hs.spaces.allSpaces() or {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local screenUuid = screen:getUUID()
        local ids = allSpaces[screenUuid] or {}
        for i, id in ipairs(ids) do
            obj.log.d("getMenuItems: screen=" .. screenUuid .. ", id=" .. id)
            local spaceName = obj:_getSpaceIdOrNameBySpaceId(id)
            if id ~= spaceName then
                if obj:_isMultiMonitorMode() then
                    spaceName = string.format("%d:%d - %s", screenID, showID, spaceName)
                else
                    spaceName = string.format("%d - %s", showID, spaceName)
                end
            end

            table.insert(res, {
                title = spaceName,
                fn = function() hs.spaces.gotoSpace(id) end,
                checked = id == spaceId,
                disabled = id == spaceId
            })
            showID = showID + 1
        end

        if not obj:_isMultiMonitorMode() then
            break
        end
        screenID = screenID + 1
        showID = 1
    end

    table.insert(res, { title = "-" })
    table.insert(res, { title = "Set name", fn = obj._setSpaceName })
    table.insert(res, {
        title = "Multi Monitor Mode",
        fn = function() obj:_toggleMonitorMode(); obj:_updateMenu() end,
        checked = obj:_isMultiMonitorMode()
    })
    table.insert(res, { title = "-" })
    table.insert(res, {
        title = "Save window positions", fn = obj._saveWindowPositions
    })
    table.insert(res, {
        title = "Restore window positions", fn = obj._restoreWindowPositions
    })
    table.insert(res, { title = "-" })
    table.insert(res, { title = "Version: " .. obj.version})

    obj.log.d("getMenuItems: done.")
    return res
end

--- Update the menubar title and menu items with current space information.
--- Refreshes the menubar display with the latest space names and menu structure.
function obj:_updateMenu()
    obj.log.d("updateMenu: starting ...")
    local menuText = obj:_getSpaceIdOrNameForCurrentSpace()
    if obj._isMultiMonitorMode() then
        menuText = obj:_getAllActiveSpaceNames()
    end;
    obj.log.df("updateMenu: menu text (id or name)=%s", menuText)
    obj.menu:setTitle(menuText)
    obj.menu:setMenu(obj:_getMenuItems())
    obj.log.d("updateMenu: done.")
end


--
-- Public functions
--

function obj:init()
end

function obj:start()
    obj.menu = hs.menubar.new(true, obj.settingName)

    obj:_updateMenu()

    obj.watcher = hs.spaces.watcher.new(obj._updateMenu)
    obj.watcher:start()

    return obj
end

function obj:stop()
    if obj.menu then self.menu:delete() end
    obj.menu = nil

    if obj.watcher then self.watcher:stop() end
    obj.watcher = nil

    return obj
end

function obj:bindHotkeys(mapping)
    local def = {
        set = hs.fnutils.partial(self._setSpaceName, self),
        show = function() obj.menu:popupMenu(hs.mouse.absolutePosition()) end,
     }

     hs.spoons.bindHotkeysToSpec(def, mapping)
     return self
end

return obj
