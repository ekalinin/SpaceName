--- === SpaceName ===
---
--- Shows current space id, adds ability to set a custom name for a screen.
---
--- Download: [https://github.com/ekalinin/SpaceName](https://github.com/ekalinin/SpaceName)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SpaceName"
obj.version = "0.6"
obj.author = "Eugene Kalinin <e.v.kalinin@gmail.com>"
obj.homepage = "https://github.com/ekalinin/SpaceName"
obj.license = "MIT - https://opensource.org/licenses/MIT"


-- Internals

obj.log = hs.logger.new('SpaceName', 'debug')
obj.settingName = "spacenames.state."
obj.settingNameMonitorMode = obj.settingName .. "MonitorMode"
obj.menu = nil
obj.watcher = nil


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

--- Get the custom name for a space by its ID, or return the ID if no name is set.
--- @param spaceId number The space ID to look up
--- @return string|number The custom name if set, otherwise the space ID
function obj:_getSpaceIdOrNameBySpaceId(spaceId)
    obj.log.df("getSpaceIdOrNameById: got space-id=%s", spaceId)
    local spaceName = hs.settings.get(obj.settingName .. tostring(spaceId))
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
        hs.settings.set(obj.settingName .. tostring(spaceId), newName)
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

--- Create and return a table of menu items for all spaces.
--- Builds menu items for switching between spaces, setting names, toggling monitor mode, and version info.
--- @return table Array of menu item tables with title, fn, checked, and disabled fields
function obj:_getMenuItems()
    obj.log.d("getMenuItems: starting ...")
    local res = {}
    local spaceId = obj:_getCurrentSpaceId()

    local screenID = 1
    local showID = 1
    for screenUuid, ids in pairs(hs.spaces.allSpaces()) do
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
