
local WARNING_HEIGHT = 70

local monitor = peripheral.wrap("top")

if not monitor then
    error("Kein Monitor ueber der Turtle gefunden!")
end
rednet.open("right")

monitor.setBackgroundColor(colors.black)
monitor.setTextScale(1.5)

local function drawSpeed(text, color)
    local width, height = monitor.getSize()
    local x = math.floor((width - #text) / 2) + 1
    local y = math.min(height, math.floor(height / 2) + 1)

    monitor.clear()
    monitor.setTextColor(color)
    monitor.setCursorPos(math.max(1, x), math.max(1, y))
    monitor.write(text)
end

while true do
    local id, data = rednet.receive("ef2000_flight_data", 2)

    if id and type(data) == "table" then
        local speed = math.floor((tonumber(data.speed) or 0) + 0.5)
        local altitude = tonumber(data.altitude) or 0

        if altitude < WARNING_HEIGHT then
            drawSpeed(speed .. " m/s", colors.red)
        else
            drawSpeed(speed .. " m/s", colors.lime)
        end
    else
        drawSpeed("--- m/s", colors.red)
    end
end
