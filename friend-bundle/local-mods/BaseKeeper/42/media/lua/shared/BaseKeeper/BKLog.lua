-- Base Keeper: console logging. Every line is prefixed "[BaseKeeper]" so console.txt can be grepped.
BKLog = BKLog or {}

BKLog.debug = false -- set true in-game via BKLog.debug = true for verbose planner output

local function fmt(...)
    local parts = {}
    local n = select("#", ...)
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    return table.concat(parts, " ")
end

function BKLog.info(...)
    print("[BaseKeeper] " .. fmt(...))
end

function BKLog.warn(...)
    print("[BaseKeeper] WARN " .. fmt(...))
end

function BKLog.dbg(...)
    if BKLog.debug then print("[BaseKeeper] dbg " .. fmt(...)) end
end

-- pcall wrapper that logs instead of swallowing. Returns ok, result.
function BKLog.try(label, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then BKLog.warn(label .. " failed: " .. tostring(res)) end
    return ok, res
end

return BKLog
