
local VOICE_HEIGHT = 80
local CAUTION_SOUND_HEIGHT = 99
local YELLOW_HEIGHT = 100
local BLINK_DELAY = 0.12
local REPEAT_DELAY = 0.20
local HYSTERESIS = 2

local volumeLevel = 2.5
local altitude = 0
local speed = 0
local hasSignal = false
local blinkVisible = true
local soundMode = "none"

local function findPeripheralType(wantedType)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, wantedType) then
            return peripheral.wrap(name), name
        end
    end
end

local monitor, monitorName = findPeripheralType("monitor")
local speaker = findPeripheralType("speaker")
local modem, modemName = findPeripheralType("modem")

if not monitor then error("Kein Advanced Monitor gefunden") end
if not speaker then error("Kein Speaker gefunden") end
if not modem then error("Kein Modem gefunden") end
if not fs.exists("warning.dfpwm") then error("warning.dfpwm fehlt") end
if not fs.exists("caution.dfpwm") then error("caution.dfpwm fehlt") end

rednet.open(modemName)

monitor.setBackgroundColor(colors.black)
monitor.setTextScale(1.5)
monitor.clear()

local dfpwm = require("cc.audio.dfpwm")

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function getSpeakerVolume()
    return (volumeLevel / 5) * 3
end

local function writeAt(x, y, text, color)
    monitor.setTextColor(color)
    monitor.setCursorPos(math.max(1, x), math.max(1, y))
    monitor.write(text)
end

local function drawVolume()
    local width, height = monitor.getSize()
    local percent = math.floor((volumeLevel / 5) * 100 + 0.5)
    local text = "[-] VOL " .. string.format("%.1f", volumeLevel)
        .. "/5  " .. percent .. "% [+]"
    local x = math.floor((width - #text) / 2) + 1

    writeAt(x, height, text, colors.lightGray)
end

local function drawDisplay()
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    if not hasSignal then
        local text = "--- m      --- m/s"
        local x = math.floor((width - #text) / 2) + 1
        writeAt(x, math.max(1, math.floor(height / 2)), text, colors.red)
        drawVolume()
        return
    end

    local altitudeText = altitude .. " m"
    local speedText = speed .. " m/s"
    local gap = "      "
    local fullText = altitudeText .. gap .. speedText
    local startX = math.floor((width - #fullText) / 2) + 1
    local lineY = math.max(1, math.floor(height / 2))

    local altitudeColor
    local speedColor

    if altitude < VOICE_HEIGHT then
        altitudeColor = blinkVisible and colors.red or colors.black
        speedColor = colors.red
    elseif altitude < YELLOW_HEIGHT then
        altitudeColor = colors.yellow
        speedColor = colors.yellow
    else
        altitudeColor = colors.lime
        speedColor = colors.lime
    end

    writeAt(startX, lineY, altitudeText, altitudeColor)
    writeAt(startX + #altitudeText + #gap, lineY, speedText, speedColor)

    drawVolume()
end

local function updateSoundMode()
    if not hasSignal or speed < 10 or volumeLevel <= 0 then
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
    local file = fs.open(filename, "rb")
    if not file then return end

    local decoder = dfpwm.make_decoder()

    while soundMode == requiredMode and volumeLevel > 0 do
        local chunk = file.read(8 * 1024)
        if not chunk then break end

        local buffer = decoder(chunk)

        while soundMode == requiredMode and volumeLevel > 0 do
            if speaker.playAudio(buffer, getSpeakerVolume()) then
                break
            end
            os.pullEvent("speaker_audio_empty")
        end
    end

    file.close()
end

local function networkLoop()
    while true do
        local senderId, data = rednet.receive("ef2000_flight_data", 3)

        if senderId and type(data) == "table" then
            altitude = math.floor(tonumber(data.altitude) or 0)
            speed = math.floor((tonumber(data.speed) or 0) + 0.5)
            hasSignal = true
        else
            hasSignal = false
        end

        updateSoundMode()
    end
end

local function displayLoop()
    while true do
        if hasSignal and altitude < VOICE_HEIGHT then
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
        local _, touchedMonitor, x, y = os.pullEvent("monitor_touch")

        if touchedMonitor == monitorName then
            local width, height = monitor.getSize()

            if y == height then
                if x <= math.floor(width / 2) then
                    volumeLevel = clamp(volumeLevel - 0.5, 0, 5)
                else
                    volumeLevel = clamp(volumeLevel + 0.5, 0, 5)
                end

                updateSoundMode()

                if volumeLevel <= 0 then
                    speaker.stop()
                end

                drawDisplay()
            end
        end
    end
end

local function soundLoop()
    local previousMode = "none"

    while true do
        updateSoundMode()

        if soundMode ~= previousMode then
            speaker.stop()
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

parallel.waitForAll(networkLoop, displayLoop, touchLoop, soundLoop)
