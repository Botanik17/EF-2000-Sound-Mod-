local velocitySensor = peripheral.wrap("left")
local altitudeSensor = peripheral.wrap("right")

rednet.open("top")

local function readSpeed()
    local a, b, c = velocitySensor.getVelocity()

    if type(a) == "table" then
        local x = a.x or a[1] or 0
        local y = a.y or a[2] or 0
        local z = a.z or a[3] or 0
        return math.sqrt(x * x + y * y + z * z)
    end

    if type(a) == "number" and type(b) == "number" and type(c) == "number" then
        return math.sqrt(a * a + b * b + c * c)
    end

    if type(a) == "number" then
        return math.abs(a)
    end

    return 0
end

while true do
    local altitude = altitudeSensor.getHeight()
    local speed = readSpeed()

    rednet.broadcast({
        altitude = altitude,
        speed = speed
    }, "ef2000_flight_data")

    sleep(0.1)
end
