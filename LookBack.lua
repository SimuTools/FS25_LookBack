--
-- LookBack.lua
--
-- Hold the LOOKBACK_HOLD action -> camera rotates backwards (180 deg yaw).
-- Release the action          -> camera snaps back to its previous orientation.
--
-- Works with the active vehicle camera (3rd person and inside cameras).
-- The original rotY/rotX/headtracking state is restored exactly as it was
-- before the key was pressed.
--

LookBack = {}
LookBack.modName = g_currentModName
LookBack.modDir  = g_currentModDirectory

-- runtime state
LookBack.isLooking      = false   -- key currently held down?
LookBack.lockedCam      = nil     -- the cameraDef table we are currently manipulating
LookBack.lockedVehicle  = nil     -- the vehicle that owns lockedCam
LookBack.savedRotY      = nil
LookBack.savedRotX      = nil
LookBack.savedRotatable = nil
LookBack.savedHeadtrack = nil


-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function getActiveVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local v = g_localPlayer:getCurrentVehicle()
        if v ~= nil then
            return v.rootVehicle or v
        end
    end
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
        local v = g_currentMission.controlledVehicle
        return v.rootVehicle or v
    end
    return nil
end

-- find the active camera definition (the table inside spec_enterable.cameras)
-- so we can read/write rotY, rotX directly. We prefer this over the live
-- camera object because the cameraDef is what gets used to drive the live
-- camera each frame.
local function getActiveCameraDef(vehicle)
    if vehicle == nil then return nil end
    local spec = vehicle.spec_enterable
    if spec == nil or type(spec.cameras) ~= "table" or #spec.cameras < 1 then
        return nil
    end

    local activeIdx = spec.activeCamera or 1

    -- fall back to matching the player's current camera node
    if g_localPlayer ~= nil and g_localPlayer.getCurrentCameraNode ~= nil then
        local currNode = g_localPlayer:getCurrentCameraNode()
        if currNode ~= nil then
            for i, cam in ipairs(spec.cameras) do
                if (cam.cameraNode or cam.rootNode) == currNode then
                    activeIdx = i
                    break
                end
            end
        end
    end

    return spec.cameras[activeIdx]
end


-- ---------------------------------------------------------------------------
-- start / stop look-back
-- ---------------------------------------------------------------------------

function LookBack:startLookBack()
    if self.isLooking then return end

    local vehicle = getActiveVehicle()
    if vehicle == nil then return end

    local camDef = getActiveCameraDef(vehicle)
    if camDef == nil then return end

    -- save current state so we can restore it 1:1 on release
    self.savedRotY      = camDef.rotY or 0
    self.savedRotX      = camDef.rotX or 0
    self.savedRotatable = camDef.isRotatable

    -- save & disable headtracking so it doesn't fight our rotation
    if g_localPlayer ~= nil and g_localPlayer.isHeadTrackingEnabled ~= nil then
        self.savedHeadtrack = g_localPlayer:isHeadTrackingEnabled()
        if g_localPlayer.setHeadTrackingEnabled ~= nil then
            g_localPlayer:setHeadTrackingEnabled(false)
        end
    end

    -- rotate 180 deg around the saved yaw -> "look back"
    camDef.rotY = self.savedRotY + math.pi
    -- keep the pitch as it was (no need to change rotX)

    -- prevent the player from manually rotating while looking back
    camDef.isRotatable = false

    self.lockedCam     = camDef
    self.lockedVehicle = vehicle
    self.isLooking     = true
end

function LookBack:stopLookBack()
    if not self.isLooking then return end

    local camDef = self.lockedCam
    if camDef ~= nil then
        if self.savedRotY ~= nil then camDef.rotY = self.savedRotY end
        if self.savedRotX ~= nil then camDef.rotX = self.savedRotX end
        if self.savedRotatable ~= nil then
            camDef.isRotatable = self.savedRotatable
        end
    end

    -- restore headtracking
    if g_localPlayer ~= nil and self.savedHeadtrack ~= nil
       and g_localPlayer.setHeadTrackingEnabled ~= nil then
        g_localPlayer:setHeadTrackingEnabled(self.savedHeadtrack)
    end

    self.isLooking      = false
    self.lockedCam      = nil
    self.lockedVehicle  = nil
    self.savedRotY      = nil
    self.savedRotX      = nil
    self.savedRotatable = nil
    self.savedHeadtrack = nil
end


-- ---------------------------------------------------------------------------
-- input handling
-- ---------------------------------------------------------------------------
--
-- We register the action on every vehicle via Enterable.onRegisterActionEvents
-- so the binding is active whenever the player sits in a vehicle. The action
-- is registered with triggerKindsMask covering DOWN (key pressed) and UP
-- (key released) so we can detect both edges and react accordingly.
--

function LookBack:onActionLookBack(actionName, inputValue, callbackState, isAnalog)
    -- inputValue > 0 means the key/button is currently pressed
    if inputValue ~= nil and inputValue > 0.5 then
        -- mark "still held" every frame -> safety updater uses this
        LookBack.lastHeldTime = g_time or 0
        if not LookBack.isLooking then
            LookBack:startLookBack()
        end
    else
        if LookBack.isLooking then
            LookBack:stopLookBack()
        end
    end
end

local function onRegisterActionEvents(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    if not vehicle.isClient then return end
    if vehicle ~= vehicle.rootVehicle then return end
    if not isActiveForInputIgnoreSelection then return end

    local spec = vehicle.spec_enterable
    if spec == nil or spec.actionEvents == nil then return end

    local _, eventId = g_inputBinding:registerActionEvent(
        InputAction.LOOKBACK_HOLD,
        LookBack,
        LookBack.onActionLookBack,
        true,   -- triggerUp:    fire on key RELEASE  (this was the bug!)
        true,   -- triggerDown:  fire on key PRESS
        true,   -- triggerAlways: keep firing while held -> safety net
        true    -- startActive
    )

    if eventId ~= nil then
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(eventId, false) -- hide help text
    end
end

Enterable.onRegisterActionEvents = Utils.appendedFunction(
    Enterable.onRegisterActionEvents, onRegisterActionEvents
)


-- ---------------------------------------------------------------------------
-- safety: if the player leaves the vehicle while holding the key, release.
-- ---------------------------------------------------------------------------

local function onLeaveVehicle(vehicle, ...)
    if LookBack.isLooking then
        LookBack:stopLookBack()
    end
end

Enterable.onLeaveVehicle = Utils.appendedFunction(
    Enterable.onLeaveVehicle, onLeaveVehicle
)


-- ---------------------------------------------------------------------------
-- Safety updater: if for any reason the release event is not delivered
-- (window lost focus, Alt+Tab, action got overridden, etc.) we force-release
-- after ~250ms of no "still pressed" callbacks. With triggerAlways=true the
-- callback fires every frame while the key is held, so a 250ms gap is a
-- very reliable signal that the key was released without our event firing.
-- ---------------------------------------------------------------------------

LookBack._safetyUpdater = LookBack._safetyUpdater or {}
function LookBack._safetyUpdater:update(dt)
    if LookBack.isLooking then
        local now = g_time or 0
        if LookBack.lastHeldTime == nil
           or (now - LookBack.lastHeldTime) > 250 then
            LookBack:stopLookBack()
        end
    end
end

local function installSafetyUpdater()
    if g_currentMission ~= nil and g_currentMission.addUpdateable ~= nil
       and not LookBack._safetyInstalled then
        g_currentMission:addUpdateable(LookBack._safetyUpdater)
        LookBack._safetyInstalled = true
    end
end

FSBaseMission.onStartMission = Utils.appendedFunction(
    FSBaseMission.onStartMission,
    function(self)
        installSafetyUpdater()
    end
)
