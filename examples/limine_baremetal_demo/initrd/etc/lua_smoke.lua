local values = {1.25, 2.5, 4.75}
local sum = 0
for _, value in ipairs(values) do
    sum = sum + value
end

local function factorial(n)
    if n == 0 then return 1 end
    return n * factorial(n - 1)
end

assert(sum == 8.5)
assert(factorial(8) == 40320)
assert(string.upper("dimension") == "DIMENSION")
assert(table.concat({"Lua", "5.4", "works"}, " ") == "Lua 5.4 works")

local ok, message = pcall(function() error("protected") end)
assert(not ok and message:match("protected"))

local file = assert(io.open("/var/lua-output.bin", "w+"))
assert(file:write("A\0B", string.char(1, 2, 3)))
assert(file:seek("set", 0) == 0)
assert(file:read("a") == "A\0B" .. string.char(1, 2, 3))
file:close()

print("Lua 5.4.9 self-test: PASS", sum, factorial(8))
