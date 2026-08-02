-- Uhr mittig zwischen Hoehe und Geschwindigkeit hinzugefuegt.
-- Anzeige im 24-Stunden-Format HH:MM.

local EXPECTED_SENDER_ID = 2
local DATA_PROTOCOL = "ef2000_flight_data"
local CONTROL_PROTOCOL = "ef2000_nav_control"

local VOICE_HEIGHT = 80
local CAUTION_SOUND_HEIGHT = 99
local YELLOW_HEIGHT = 100
local BLINK_DELAY = 0.12
local REPEAT_DELAY = 0.20
local HYSTERESIS = 2
local DIRECTION_SMOOTHING = 0.22

local INVERT_LEFT_RIGHT = false
local INVERT_FORWARD_BACK = false

local volumeLevel = 2.5
local altitude = 0
local speed = 0
local altitudeAvailable = false
local speedAvailable = false

local navigation = {
    present = false,
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

local smoothX = 0
local smoothY = 0
local hasSignal = false
local blinkVisible = true
local soundMode = "none"

local monitor = nil
local monitorName = nil
local modem = nil
local modemName = nil
local speaker = nil

local warningFileAvailable =
    fs.exists("warning.dfpwm")

local cautionFileAvailable =
    fs.exists("caution.dfpwm")

local audioAvailable = false
local dfpwm = nil

local function findPeripheralType(wantedType)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, wantedType) then
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

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if isWirelessModem(name) then
            return peripheral.wrap(name), name
        end
    end

    return nil, nil
end

local function setupPeripherals()
    monitor, monitorName =
        findPeripheralType("monitor")

    modem, modemName =
        findWirelessModem()

    speaker =
        select(1, findPeripheralType("speaker"))

    if not monitor then
        error("Kein Advanced Monitor gefunden")
    end

    if not modem then
        error("Kein Wireless Modem gefunden")
    end

    if not rednet.isOpen(modemName) then
        rednet.open(modemName)
    end

    monitor.setBackgroundColor(colors.black)

    -- Fuer eine zusammenhaengende Wand aus 6 Monitorbloecken.
    -- 0.5 ist die kleinste gueltige Textskalierung und verteilt
    -- die Anzeige deutlich besser ueber die gesamte Flaeche.
    monitor.setTextScale(1)

    monitor.clear()

    audioAvailable =
        speaker ~= nil
        and warningFileAvailable
        and cautionFileAvailable

    if audioAvailable then
        dfpwm = require("cc.audio.dfpwm")
    end
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function writeAt(x, y, text, color)
    local width, height = monitor.getSize()

    if y < 1 or y > height then
        return
    end

    text = tostring(text)

    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end

    if x > width or text == "" then
        return
    end

    if x + #text - 1 > width then
        text = text:sub(1, width - x + 1)
    end

    monitor.setTextColor(color)
    monitor.setCursorPos(x, y)
    monitor.write(text)
end

local function centerAt(y, text, color)
    local width = monitor.getSize()
    text = tostring(text)

    local x =
        math.floor((width - #text) / 2) + 1

    writeAt(x, y, text, color)
end

local function formatDistance(distance)
    if not distance or distance < 0 then
        return "---"
    elseif distance >= 1000 then
        return string.format("%.2f km", distance / 1000)
    else
        return string.format("%.0f m", distance)
    end
end

local function formatEta(seconds)
    if not seconds or seconds < 0 then
        return "--:--"
    end

    local total = math.floor(seconds + 0.5)

    if total >= 3600 then
        local hours = math.floor(total / 3600)
        local minutes = math.floor((total % 3600) / 60)
        local secs = total % 60

        return string.format(
            "%d:%02d:%02d",
            hours,
            minutes,
            secs
        )
    end

    return string.format(
        "%02d:%02d",
        math.floor(total / 60),
        total % 60
    )
end

local function updateSmoothedDirection()
    local vector = navigation.vector or {}

    local left = tonumber(vector.left) or 0
    local right = tonumber(vector.right) or 0
    local forward = tonumber(vector.forward) or 0
    local backward = tonumber(vector.backward) or 0

    local targetX = right - left
    local targetForward = forward - backward

    if INVERT_LEFT_RIGHT then
        targetX = -targetX
    end

    if INVERT_FORWARD_BACK then
        targetForward = -targetForward
    end

    smoothX =
        smoothX
        + (targetX - smoothX)
        * DIRECTION_SMOOTHING

    smoothY =
        smoothY
        + (targetForward - smoothY)
        * DIRECTION_SMOOTHING
end

local function atan2(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then
        return math.pi / 2
    elseif x == 0 and y < 0 then
        return -math.pi / 2
    end

    return 0
end

local function drawDirection(scaleY, arrowY)
    local width = monitor.getSize()

    if not navigation.available then
        centerAt(scaleY, "---", colors.gray)
        return
    end

    -- Auf der 6er-Monitorwand darf die Navigationsskala
    -- deutlich breiter sein.
    local wantedWidth =
        math.floor(width * 0.60)

    local scaleWidth =
        math.min(
            width - 8,
            math.max(31, wantedWidth)
        )

    if scaleWidth < 5 then
        return
    end

    if scaleWidth % 2 == 0 then
        scaleWidth = scaleWidth - 1
    end

    local leftEdge =
        math.floor((width - scaleWidth) / 2) + 1

    local centerX =
        leftEdge + math.floor(scaleWidth / 2)

    writeAt(
        leftEdge,
        scaleY,
        "<" .. string.rep("-", scaleWidth - 2) .. ">",
        colors.gray
    )

    writeAt(
        centerX,
        scaleY,
        "+",
        colors.lightGray
    )

    local angle = atan2(smoothX, smoothY)
    local normalized =
        clamp(angle / math.pi, -1, 1)

    local maxOffset =
        math.floor(scaleWidth / 2) - 1

    local markerOffset

    if normalized >= 0 then
        markerOffset =
            math.floor(normalized * maxOffset + 0.5)
    else
        markerOffset =
            math.ceil(normalized * maxOffset - 0.5)
    end

    writeAt(
        centerX + markerOffset,
        scaleY,
        "|",
        colors.orange
    )

    writeAt(
        centerX,
        arrowY,
        "^",
        colors.lime
    )
end

local function getFlightColors()
    local altitudeColor = colors.gray
    local speedColor = colors.gray

    if altitudeAvailable then
        if altitude < VOICE_HEIGHT then
            altitudeColor =
                blinkVisible
                and colors.red
                or colors.black
        elseif altitude < YELLOW_HEIGHT then
            altitudeColor = colors.yellow
        else
            altitudeColor = colors.lime
        end
    end

    if speedAvailable then
        if altitudeAvailable and altitude < VOICE_HEIGHT then
            speedColor = colors.red
        elseif altitudeAvailable and altitude < YELLOW_HEIGHT then
            speedColor = colors.yellow
        else
            speedColor = colors.lime
        end
    end

    return altitudeColor, speedColor
end

local function getClockText()
    -- Reale lokale Uhrzeit im 24-Stunden-Format.
    -- Beispiel: 18:50
    local ok, result = pcall(function()
        return os.date(
            "%H:%M",
            os.epoch("local") / 1000
        )
    end)

    if ok and type(result) == "string" then
        return result
    end

    -- Ersatz, falls os.epoch("local") nicht verfuegbar ist.
    return textutils.formatTime(os.time(), true)
end

local function drawFlightRow(y)
    local width = monitor.getSize()

    local altitudeText =
        altitudeAvailable
        and (altitude .. " m")
        or "--- m"

    local speedText =
        speedAvailable
        and (speed .. " m/s")
        or "--- m/s"

    local clockText = getClockText()

    local altitudeColor, speedColor =
        getFlightColors()

    -- Hoehe links, Uhr exakt mittig, Geschwindigkeit rechts.
    local altitudeCenter =
        math.floor(width * 0.22)

    local screenCenter =
        math.floor(width / 2) + 1

    local speedCenter =
        math.floor(width * 0.78)

    writeAt(
        altitudeCenter
            - math.floor(#altitudeText / 2),
        y,
        altitudeText,
        altitudeColor
    )

    writeAt(
        screenCenter
            - math.floor(#clockText / 2),
        y,
        clockText,
        colors.white
    )

    writeAt(
        speedCenter
            - math.floor(#speedText / 2),
        y,
        speedText,
        speedColor
    )
end

local function drawDisplay()
    local width, height = monitor.getSize()

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    if not hasSignal then
        centerAt(
            math.max(1, math.floor(height / 2)),
            "NO SIGNAL",
            colors.red
        )
        return
    end

    updateSmoothedDirection()

    -- Die Zeilen werden proportional ueber die gesamte
    -- 6-Monitor-Wand verteilt, statt oben zusammenzuquetschen.
    local function rowAt(fraction, minimum)
        return math.max(
            minimum or 1,
            math.min(
                height - 1,
                math.floor(height * fraction + 0.5)
            )
        )
    end

    local flightY = rowAt(0.12, 2)
    local slotY = rowAt(0.27, flightY + 2)
    local targetY = rowAt(0.40, slotY + 2)
    local distanceY = rowAt(0.53, targetY + 2)
    local scaleY = rowAt(0.68, distanceY + 2)
    local arrowY = math.min(height - 2, scaleY + 2)
    local bottomY = height

    drawFlightRow(flightY)

    local slot = navigation.selectedSlot or 1
    local slotCount = navigation.slotCount or 15

    if navigation.present then
        centerAt(
            slotY,
            "NAV " .. slot .. "/" .. slotCount,
            colors.cyan
        )
    else
        centerAt(
            slotY,
            "NO NAV SYSTEM",
            colors.red
        )
    end

    local targetName =
        navigation.label
        or navigation.mapName
        or "NO TARGET"

    centerAt(
        targetY,
        targetName,
        colors.white
    )

    centerAt(
        distanceY,
        "DIST "
            .. formatDistance(navigation.distance)
            .. "   ETA "
            .. formatEta(navigation.eta),
        navigation.available and colors.lime or colors.gray
    )

    drawDirection(scaleY, arrowY)

    writeAt(
        2,
        bottomY,
        "[PREV]",
        colors.lightBlue
    )

    writeAt(
        width - 7,
        bottomY,
        "[NEXT]",
        colors.lightBlue
    )

    if audioAvailable then
        local percent =
            math.floor((volumeLevel / 5) * 100 + 0.5)

        centerAt(
            bottomY,
            "VOL "
                .. string.format("%.1f", volumeLevel)
                .. "/5 "
                .. percent
                .. "%",
            colors.lightGray
        )
    else
        centerAt(
            bottomY,
            "AUDIO OFF",
            colors.gray
        )
    end
end

local function getSpeakerVolume()
    return (volumeLevel / 5) * 3
end

local function updateSoundMode()
    if not audioAvailable
        or not hasSignal
        or not altitudeAvailable
        or not speedAvailable
        or speed < 10
        or volumeLevel <= 0 then

        soundMode = "none"
        return
    end

    if soundMode == "warning" then
        if altitude >= VOICE_HEIGHT + HYSTERESIS then
            if altitude < CAUTION_SOUND_HEIGHT then
                soundMode = "caution"
            else
                soundMode = "none"
            end
        end

        return
    end

    if soundMode == "caution" then
        if altitude < VOICE_HEIGHT then
            soundMode = "warning"
        elseif altitude >= CAUTION_SOUND_HEIGHT + HYSTERESIS then
            soundMode = "none"
        end

        return
    end

    if altitude < VOICE_HEIGHT then
        soundMode = "warning"
    elseif altitude < CAUTION_SOUND_HEIGHT then
        soundMode = "caution"
    else
        soundMode = "none"
    end
end

local function playFile(filename, requiredMode)
    if not audioAvailable
        or not speaker
        or not dfpwm then

        return
    end

    local file = fs.open(filename, "rb")

    if not file then
        return
    end

    local decoder = dfpwm.make_decoder()

    while soundMode == requiredMode
        and volumeLevel > 0 do

        local chunk = file.read(8 * 1024)

        if not chunk then
            break
        end

        local buffer = decoder(chunk)

        while soundMode == requiredMode
            and volumeLevel > 0 do

            if speaker.playAudio(
                buffer,
                getSpeakerVolume()
            ) then
                break
            end

            os.pullEvent("speaker_audio_empty")
        end
    end

    file.close()
end

local function networkLoop()
    while true do
        local senderId, data =
            rednet.receive(DATA_PROTOCOL, 3)

        if senderId == EXPECTED_SENDER_ID
            and type(data) == "table" then

            altitudeAvailable =
                data.altitudeAvailable == true

            speedAvailable =
                data.speedAvailable == true

            altitude =
                math.floor(tonumber(data.altitude) or 0)

            speed =
                math.floor((tonumber(data.speed) or 0) + 0.5)

            if type(data.navigation) == "table" then
                navigation = data.navigation
            end

            hasSignal = true
        else
            hasSignal = false
        end

        updateSoundMode()
    end
end

local function displayLoop()
    while true do
        if hasSignal
            and altitudeAvailable
            and altitude < VOICE_HEIGHT then

            blinkVisible = not blinkVisible
            drawDisplay()
            sleep(BLINK_DELAY)
        else
            blinkVisible = true
            drawDisplay()
            sleep(0.1)
        end
    end
end

local function touchLoop()
    while true do
        local _, touchedMonitor, x, y =
            os.pullEvent("monitor_touch")

        local width, height = monitor.getSize()

        if touchedMonitor == monitorName
            and y == height then

            if x <= 8 then
                rednet.send(
                    EXPECTED_SENDER_ID,
                    "previous",
                    CONTROL_PROTOCOL
                )

            elseif x >= width - 8 then
                rednet.send(
                    EXPECTED_SENDER_ID,
                    "next",
                    CONTROL_PROTOCOL
                )

            elseif audioAvailable then
                if x <= math.floor(width / 2) then
                    volumeLevel =
                        clamp(volumeLevel - 0.5, 0, 5)
                else
                    volumeLevel =
                        clamp(volumeLevel + 0.5, 0, 5)
                end

                updateSoundMode()

                if volumeLevel <= 0 and speaker then
                    speaker.stop()
                end
            end

            drawDisplay()
        end
    end
end

local function soundLoop()
    local previousMode = "none"

    while true do
        if not audioAvailable then
            soundMode = "none"
            sleep(1)
        else
            updateSoundMode()

            if soundMode ~= previousMode then
                if speaker then
                    speaker.stop()
                end

                previousMode = soundMode
            end

            if soundMode == "warning" then
                playFile("warning.dfpwm", "warning")

                if soundMode == "warning" then
                    sleep(REPEAT_DELAY)
                end

            elseif soundMode == "caution" then
                playFile("caution.dfpwm", "caution")

                if soundMode == "caution" then
                    sleep(REPEAT_DELAY)
                end
            else
                sleep(0.1)
            end
        end
    end
end

setupPeripherals()

term.clear()
term.setCursorPos(1, 1)
print("EF-2000 Cockpit aktiv")
print("Erwarteter Sender: Computer 2")
print("Monitor: " .. monitorName)
print("Wireless: " .. modemName)
print("Audio: " .. (audioAvailable and "AN" or "AUS"))

parallel.waitForAll(
    networkLoop,
    displayLoop,
    touchLoop,
    soundLoop
)
