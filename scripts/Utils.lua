-- ============================================================================
-- Utils.lua - 数学与碰撞小工具
-- 纯函数，无状态，方便单测与复用
-- ============================================================================

local Utils = {}

--- 把 v 夹在 [lo, hi]
---@param v number
---@param lo number
---@param hi number
---@return number
function Utils.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- 线性插值
---@param a number
---@param b number
---@param t number
---@return number
function Utils.Lerp(a, b, t)
    return a + (b - a) * t
end

--- 帧率无关的指数逼近（用于角度、相机等平滑跟随）
---@param current number
---@param target number
---@param speed number  越大越快
---@param dt number
---@return number
function Utils.Damp(current, target, speed, dt)
    local t = 1 - math.exp(-speed * dt)
    return current + (target - current) * t
end

--- [lo, hi) 区间随机浮点
---@param lo number
---@param hi number
---@return number
function Utils.RandRange(lo, hi)
    return lo + math.random() * (hi - lo)
end

--- [lo, hi] 区间随机整数
---@param lo integer
---@param hi integer
---@return integer
function Utils.RandInt(lo, hi)
    return math.random(lo, hi)
end

--- 0..1 进度映射
---@param v number
---@param lo number
---@param hi number
---@return number
function Utils.InverseLerp(v, lo, hi)
    if hi == lo then return 0 end
    return Utils.Clamp((v - lo) / (hi - lo), 0, 1)
end

--- 圆 vs 轴对齐矩形 相交检测
--- 用于：飞鼠（圆）撞树枝（矩形）
---@param cx number 圆心 x
---@param cy number 圆心 y
---@param r number 半径
---@param rx number 矩形左上 x
---@param ry number 矩形左上 y
---@param rw number 矩形宽
---@param rh number 矩形高
---@return boolean
function Utils.CircleRectOverlap(cx, cy, r, rx, ry, rw, rh)
    -- 取矩形上离圆心最近的点
    local nearestX = Utils.Clamp(cx, rx, rx + rw)
    local nearestY = Utils.Clamp(cy, ry, ry + rh)
    local dx = cx - nearestX
    local dy = cy - nearestY
    return (dx * dx + dy * dy) <= (r * r)
end

--- 圆 vs 圆 相交检测
--- 用于：飞鼠（圆）吃松果（圆）
---@param ax number
---@param ay number
---@param ar number
---@param bx number
---@param by number
---@param br number
---@return boolean
function Utils.CircleOverlap(ax, ay, ar, bx, by, br)
    local dx = ax - bx
    local dy = ay - by
    local rr = ar + br
    return (dx * dx + dy * dy) <= (rr * rr)
end

--- 缓出三次方，用于结算面板弹入
---@param t number 0..1
---@return number
function Utils.EaseOutCubic(t)
    local p = 1 - Utils.Clamp(t, 0, 1)
    return 1 - p * p * p
end

--- 缓出二次方，用于滑翔推力的"咬合"曲线
---@param t number 0..1
---@return number
function Utils.EaseOutQuad(t)
    local p = 1 - Utils.Clamp(t, 0, 1)
    return 1 - p * p
end

--- smoothstep：比线性更柔和的难度/进度映射（两端减速）
---@param t number 0..1
---@return number
function Utils.SmoothStep(t)
    local x = Utils.Clamp(t, 0, 1)
    return x * x * (3 - 2 * x)
end

--- 缓出回弹，用于收集物飞散的轻微过冲
---@param t number 0..1
---@return number
function Utils.EaseOutBack(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    local p = Utils.Clamp(t, 0, 1) - 1
    return 1 + c3 * p * p * p + c1 * p * p
end

return Utils
