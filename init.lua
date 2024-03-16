--- === SpaceName ===
---
--- Shows current space id, adds ability to set a custom name for a screen.
---
--- Download: [https://github.com/ekalinin/SpaceName](https://github.com/ekalinin/SpaceName)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SpaceName"
obj.version = "0.5"
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

function obj:_getCurrentSpaceId()
    space = hs.spaces.activeSpaces()
    spaceId = -1
    for key, val in pairs(space) do
        obj.log.df("_getCurrentSpaceId: got space key=%s, val=%d", key, val)
        spaceId = val
        break
    end

    return spaceId
end

function obj:_getSpaceIdOrNameBySpaceId(spaceId)
    obj.log.df("getSpaceIdOrNameById: got space-id=%s", spaceId)
    spaceName = hs.settings.get(obj.settingName .. tostring(spaceId))
    obj.log.df("getSpaceIdOrNameById: find name in settings=%s", spaceName)
    if spaceName == nil then
        spaceName = spaceId
    end

    return spaceName
end

function obj:_getSpaceIdOrNameForCurrentSpace()
    spaceId = obj:_getCurrentSpaceId()
    obj.log.df("getSpaceIdOrNameCurrent: got space-id=%s", spaceId)
    spaceName = obj:_getSpaceIdOrNameBySpaceId(spaceId)
    obj.log.df("getSpaceIdOrNameCurrent: space-name=%s", spaceName)
    return spaceName
end

-- Show dialog to enter custom screen name (and save it in settings).
function obj:_setSpaceName()
    currentName = obj:_getSpaceIdOrNameForCurrentSpace()
    if type(currentName) == "number" then
        currentName = ""
    end
    button, newName = hs.dialog.textPrompt(
        "Screen name", "Please, enter a readable name",
        currentName,
        "Save", "Cancel"
    )
    obj.log.df("setSpaceName: new space name=%s, button=%s", newName, button)

    if button == "Save" and newName ~= '' then
        spaceId = obj:_getCurrentSpaceId()
        hs.settings.set(obj.settingName .. tostring(spaceId), newName)
        obj.log.df("setSpaceName: set space name=%s for space-id=%d", newName, spaceId)

        obj:_updateMenu()
    end
end

function obj:_toogleMonitorMode()
    mode = hs.settings.get(obj.settingNameMonitorMode)
    if mode == nil or mode == "0" then
        mode = "1"
    else
        mode = "0"
    end
    hs.settings.set(obj.settingNameMonitorMode, mode)
end

function obj:_isMultiMonitorMode()
    mode = hs.settings.get(obj.settingNameMonitorMode)
    return mode == "1"
end

-- Creates and return a table of screens for menu.
function obj:_getMenuItems()
    obj.log.d("getMenuItems: starting ...")
    res = {}
    spaceId = obj:_getCurrentSpaceId()

    screenID = 1
    showID = 1
    for screenUuid, ids in pairs(hs.spaces.allSpaces()) do
        for i, id in ipairs(ids) do
            obj.log.d("getMenuItems: screen=" .. screenUuid .. ", id=" .. id)
            local spaceName = obj:_getSpaceIdOrNameBySpaceId(id)
            if id ~= spaceName then
                if obj._isMultiMonitorMode() then
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

        if not obj._isMultiMonitorMode() then
            break
        end
        screenID = screenID + 1
        showID = 1
    end

    table.insert(res, { title = "-" })
    table.insert(res, { title = "Set name", fn = obj._setSpaceName })
    table.insert(res, {
        title = "Multi Monitor Mode",
        fn = function() obj._toogleMonitorMode(); obj:_updateMenu() end,
        checked = obj._isMultiMonitorMode()
    })
    table.insert(res, { title = "-" })
    table.insert(res, { title = "Version: " .. obj.version})

    obj.log.d("getMenuItems: done.")
    return res
end

-- Updates main menu with actual spaces.
function obj:_updateMenu()
    obj.log.d("updateMenu: starting ...")
    menuText = obj:_getSpaceIdOrNameForCurrentSpace()
    obj.log.df("updateMenu: menu text (id or name)=%s", menuText)
    obj.menu:setTitle(menuText)
    obj.menu:setMenu(obj._getMenuItems())
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
