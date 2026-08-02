-- EF-2000 Hauptsender fuer Computer 2
--
-- Aufbau:
--   Wireless Modem
--   Velocity Sensor
--   Altitude Sensor
--   Advanced Navigation Table
--
-- Die Peripherie wird automatisch gesucht.
-- Der Sender uebertraegt Hoehe, Geschwindigkeit und Navigation.

local EXPECTED_COMPUTER_ID = 2
local DATA_PROTOCOL = "ef2000_flight_data"
local CONTROL_PROTOCOL = "ef2000_nav_control"

local modem = nil
local modemName = nil
local velocitySensor = nil
local velocityName = nil
local altitudeSensor = nil
local altitudeName = nil
local navigationTable = nil
local navigationName = nil

local lastStatus = ""

local function hasMethod(name, wantedMethod)
    local methods = peripheral.getMethods(name) or {}

    for _, method in ipairs(methods) do
        if method == wantedMethod then
            return true
        end
    end

    return false
end

local function findByMethod(wantedMethod, preferredSide)
    if preferredSide
        and peripheral.isPresent(preferredSide)
        and hasMethod(preferredSide, wantedMethod) then

        return peripheral.wrap(preferredSide), preferredSide
    end

    for _, name in ipairs(peripheral.getNames()) do
        if hasMethod(name, wantedMethod) then
            return peripheral.wrap(name), name
        end
    end

    return nil, nil
end

local function isWirelessModem(name)
    if not peripheral.hasType(name, "modem") then
        return false
    end

    local wrapped = peripheral.wrap(name)

    if not wrapped or type(wrapped.isWireless) ~= "function" then
        return false
    end

    local ok, wireless = pcall(wrapped.isWireless)
    return ok and wireless == true
end

local function findWirelessModem(preferredSide)
    if preferredSide
        and peripheral.isPresent(preferredSide)
        and isWirelessModem(preferredSide) then

        return peripheral.wrap(preferredSide), preferredSide
    end

    for _, name in ipairs(peripheral.getNames()) do
        if isWirelessModem(name) then
            return peripheral.wrap(name), name
        end
    end

    return nil, nil
end

local function refreshPeripherals()
    local newModem, newModemName =
        findWirelessModem("top")

    if newModemName ~= modemName then
        if modemName and rednet.isOpen(modemName) then
            pcall(rednet.close, modemName)
        end

        modem = newModem
        modemName = newModemName

        if modemName and not rednet.isOpen(modemName) then
            rednet.open(modemName)
        end
    else
        modem = newModem
    end

    velocitySensor, velocityName =
        findByMethod("getVelocity", "left")

    altitudeSensor, altitudeName =
        findByMethod("getHeight", "right")

    navigationTable, navigationName =
        findByMethod("getTargetDistance", "front")
end

local function showStatus()
    local status =
        "MODEM=" .. (modemName or "-")
        .. "|VEL=" .. (velocityName or "-")
        .. "|ALT=" .. (altitudeName or "-")
        .. "|NAV=" .. (navigationName or "-")

    if status == lastStatus then
        return
    end

    lastStatus = status

    term.clear()
    term.setCursorPos(1, 1)

    print("EF-2000 Hauptsender")
    print("Computer-ID: " .. os.getComputerID())

    if os.getComputerID() ~= EXPECTED_COMPUTER_ID then
        print("WARNUNG: Erwartet wird ID 2")
    end

    print("")
    print("Wireless: " .. (modemName or "FEHLT"))
    print("Velocity: " .. (velocityName or "FEHLT"))
    print("Altitude: " .. (altitudeName or "FEHLT"))
    print("Navigation: " .. (navigationName or "FEHLT"))
    print("")
    print("Datenprotokoll: " .. DATA_PROTOCOL)
end

local function readSpeed()
    if not velocitySensor then
        return nil
    end

    local ok, a, b, c =
        pcall(velocitySensor.getVelocity)

    if not ok then
        return nil
    end

    if type(a) == "table" then
        local x = tonumber(a.x or a[1]) or 0
        local y = tonumber(a.y or a[2]) or 0
        local z = tonumber(a.z or a[3]) or 0

        return math.sqrt(x * x + y * y + z * z)
    end

    if type(a) == "number"
        and type(b) == "number"
        and type(c) == "number" then

        return math.sqrt(a * a + b * b + c * c)
    end

    if type(a) == "number" then
        return math.abs(a)
    end

    return nil
end

local function readAltitude()
    if not altitudeSensor then
        return nil
    end

    local ok, value =
        pcall(altitudeSensor.getHeight)

    if ok and type(value) == "number" then
        return value
    end

    return nil
end

local function ensureNavigationRunning()
    if not navigationTable then
        return
    end

    if type(navigationTable.isRunning) == "function" then
        local ok, running =
            pcall(navigationTable.isRunning)

        if ok and running then
            return
        end
    end

    if type(navigationTable.start) == "function" then
        pcall(navigationTable.start)
    end
end

local function readNavigation(speed)
    local data = {
        present = navigationTable ~= nil,
        available = false,
        distance = -1,
        eta = -1,
        vector = {
            forward = 0,
            backward = 0,
            left = 0,
            right = 0,
            magnitude = 0
        },
        label = nil,
        mapName = nil,
        selectedSlot = 1,
        slotCount = 15
    }

    if not navigationTable then
        return data
    end

    local okSlot, selectedSlot =
        pcall(navigationTable.getSelectedSlot)

    if okSlot and type(selectedSlot) == "number" then
        data.selectedSlot = selectedSlot
    end

    if type(navigationTable.getSlotCount) == "function" then
        local okCount, slotCount =
            pcall(navigationTable.getSlotCount)

        if okCount and type(slotCount) == "number" then
            data.slotCount = slotCount
        end
    end

    local okDistance, distance =
        pcall(navigationTable.getTargetDistance)

    if okDistance
        and type(distance) == "number"
        and distance >= 0 then

        data.available = true
        data.distance = distance

        if type(speed) == "number" and speed >= 1 then
            data.eta = distance / speed
        end

        ensureNavigationRunning()

        if type(navigationTable.getVector) == "function" then
            local okVector, vector =
                pcall(navigationTable.getVector)

            if okVector and type(vector) == "table" then
                data.vector = {
                    forward = tonumber(vector.forward) or 0,
                    backward = tonumber(vector.backward) or 0,
                    left = tonumber(vector.left) or 0,
                    right = tonumber(vector.right) or 0,
                    magnitude = tonumber(vector.magnitude) or 0
                }
            end
        end
    end

    if type(navigationTable.getTargetLabelInSlot) == "function" then
        local okLabel, label = pcall(
            navigationTable.getTargetLabelInSlot,
            data.selectedSlot
        )

        if okLabel
            and type(label) == "string"
            and label ~= "" then

            data.label = label
        end
    end

    if not data.label
        and type(navigationTable.getTargetLabel) == "function" then

        local okLabel, label =
            pcall(navigationTable.getTargetLabel)

        if okLabel
            and type(label) == "string"
            and label ~= "" then

            data.label = label
        end
    end

    if type(navigationTable.getMapName) == "function" then
        local okMap, mapName = pcall(
            navigationTable.getMapName,
            data.selectedSlot
        )

        if okMap
            and type(mapName) == "string"
            and mapName ~= "" then

            data.mapName = mapName
        end
    end

    return data
end

local function sendLoop()
    while true do
        refreshPeripherals()
        showStatus()

        if modemName and rednet.isOpen(modemName) then
            local altitude = readAltitude()
            local speed = readSpeed()

            rednet.broadcast({
                sourceId = os.getComputerID(),
                altitude = altitude or 0,
                speed = speed or 0,
                altitudeAvailable = altitude ~= nil,
                speedAvailable = speed ~= nil,
                navigation = readNavigation(speed)
            }, DATA_PROTOCOL)
        end

        sleep(0.1)
    end
end

local function controlLoop()
    while true do
        refreshPeripherals()

        if not modemName or not rednet.isOpen(modemName) then
            sleep(0.5)
        else
            local _, message =
                rednet.receive(CONTROL_PROTOCOL, 1)

            if navigationTable then
                if message == "next"
                    and type(navigationTable.nextSlot) == "function" then

                    pcall(navigationTable.nextSlot)
                    sleep(0.05)
                    ensureNavigationRunning()

                elseif message == "previous"
                    and type(navigationTable.previousSlot) == "function" then

                    pcall(navigationTable.previousSlot)
                    sleep(0.05)
                    ensureNavigationRunning()
                end
            end
        end
    end
end

refreshPeripherals()
showStatus()
ensureNavigationRunning()

parallel.waitForAll(
    sendLoop,
    controlLoop
)
