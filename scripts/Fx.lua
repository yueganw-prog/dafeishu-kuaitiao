-- ============================================================================
-- Fx.lua - 果汁层：粒子 / 飘字 / 白闪 / 屏震 / 缩放脉冲 / hit-stop / 慢动作
--
-- 本项目是纯 NanoVG 即时绘制（无 Scene/Node），所以特效层也是纯 Lua table
-- + 矢量绘制，与 Renderer 同一套管线。Game 负责触发与驱动 Update，
-- Renderer 在合适层级调用 Draw*。
--
-- 时间体系：
--   Update 收"真实 dt"（hit-stop / 慢动作计时按真实时间走）
--   GetDt(dt) 返回"游戏 dt"（hit-stop 时为 0，慢动作时乘系数），供玩法用
-- ============================================================================

local Config = require("Config")
local Utils = require("Utils")

---@class Fx
---@field parts table[]        粒子池
---@field floaters table[]     飘字池
---@field shake number         屏震强度 0..1.5
---@field flash number         白闪强度 0..1
---@field flashColor number[]  白闪颜色 {r,g,b}
---@field zoomPulse number     镜头缩放脉冲
---@field hitstopTimer number  冻结剩余时长
---@field slowMoTimer number   慢动作剩余时长
---@field timeScale number     慢动作倍率
---@field time number          特效层累计时间（真实时间）
local Fx = {}
Fx.__index = Fx

---@return Fx
function Fx.New()
    local self = setmetatable({}, Fx)
    self:init()
    return self
end

function Fx:init()
    self.parts = {}
    self.floaters = {}
    self.shake = 0
    self.flash = 0
    self.flashColor = { 255, 255, 255 }
    self.zoomPulse = 0
    self.hitstopTimer = 0
    self.slowMoTimer = 0
    self.timeScale = 1
    self.time = 0
end

--- 开新局时清空所有瞬时特效
function Fx:Reset()
    self:init()
end

-- ---------------------------------------------------------------------------
-- 时间控制
-- ---------------------------------------------------------------------------

--- 冻结画面一小段时间（撞击瞬间），duration 取更长的那个
---@param dur number
function Fx:HitStop(dur)
    self.hitstopTimer = math.max(self.hitstopTimer, dur)
end

--- 进入慢动作
---@param scale number 时间倍率（如 0.35）
---@param dur number 持续时长（真实秒）
function Fx:SlowMo(scale, dur)
    self.timeScale = scale
    self.slowMoTimer = dur
end

--- 把外部 dt 换算成玩法层 dt
---@param dt number
---@return number
function Fx:GetDt(dt)
    if self.hitstopTimer > 0 then return 0 end
    if self.slowMoTimer > 0 then return dt * self.timeScale end
    return dt
end

-- ---------------------------------------------------------------------------
-- 反馈触发
-- ---------------------------------------------------------------------------

---@param v number 屏震强度（1 = 满级）
function Fx:AddShake(v)
    self.shake = math.min(1.5, math.max(self.shake, v))
end

---@param a number 白闪强度 0..1
---@param color number[]|nil {r,g,b}
function Fx:AddFlash(a, color)
    self.flash = math.max(self.flash, a)
    if color then self.flashColor = color end
end

---@param v number 缩放脉冲增量
function Fx:AddZoom(v)
    self.zoomPulse = math.min(0.08, self.zoomPulse + v)
end

--- 当前震屏变换量：位移 + 微旋转（度）
---@return number ox, number oy, number rotDeg
function Fx:GetTransform()
    local s = self.shake
    if s <= 0 then return 0, 0, 0 end
    local amp = Config.Fx.shakeAmp * s * s
    local rot = Utils.RandRange(-1, 1) * Config.Fx.shakeRotMax * s
    return Utils.RandRange(-amp, amp), Utils.RandRange(-amp, amp), rot
end

--- 当前镜头缩放（1 = 无缩放）
---@return number
function Fx:GetZoom()
    return 1 + self.zoomPulse
end

-- ---------------------------------------------------------------------------
-- 粒子 / 飘字 生成
-- ---------------------------------------------------------------------------

---@param p table 粒子描述（type/x/y/vx/vy/life/size/...）
local function Spawn(self, p)
    if #self.parts >= Config.Fx.maxParticles then
        table.remove(self.parts, 1)   -- 池满：回收最老的
    end
    p.maxLife = p.life
    table.insert(self.parts, p)
end

--- 扇翅气团（按下时在飞鼠下方喷一小团空气）
---@param x number
---@param y number
function Fx:Puff(x, y)
    for _ = 1, 5 do
        Spawn(self, {
            type = "puff",
            x = x + Utils.RandRange(-5, 5),
            y = y + Utils.RandRange(2, 10),
            vx = Utils.RandRange(-50, 30),
            vy = Utils.RandRange(30, 90),
            life = Utils.RandRange(0.22, 0.40),
            size = Utils.RandRange(4, 8),
            grow = Utils.RandRange(26, 42),
            color = { 235, 240, 250 },
        })
    end
end

--- 收集星屑（吃松果 / 吃道具时向四周炸开）
---@param x number
---@param y number
---@param color number[]
---@param count number|nil
function Fx:Burst(x, y, color, count)
    count = count or 10
    for _ = 1, count do
        local ang = math.random() * math.pi * 2
        local sp = Utils.RandRange(60, 240)
        Spawn(self, {
            type = "shard",
            x = x, y = y,
            vx = math.cos(ang) * sp,
            vy = math.sin(ang) * sp - 40,
            gy = 340,
            life = Utils.RandRange(0.35, 0.60),
            size = Utils.RandRange(2.2, 4.2),
            color = color,
        })
    end
end

--- 碎块（树枝撞毁 / 飞鼠坠落），带重力与旋转
---@param x number
---@param y number
---@param color number[]
---@param count number|nil
function Fx:Debris(x, y, color, count)
    count = count or 14
    for _ = 1, count do
        local ang = Utils.RandRange(-math.pi, 0)   -- 朝上抛洒
        local sp = Utils.RandRange(120, 380)
        Spawn(self, {
            type = "debris",
            x = x + Utils.RandRange(-10, 10),
            y = y + Utils.RandRange(-10, 10),
            vx = math.cos(ang) * sp,
            vy = math.sin(ang) * sp,
            gy = 900,
            life = Utils.RandRange(0.45, 0.85),
            size = Utils.RandRange(3, 7),
            rot = Utils.RandRange(0, 360),
            vr = Utils.RandRange(-420, 420),
            color = color,
        })
    end
end

--- 擦身火花（贴着树枝缝隙飞过时的短促拉线）
---@param x number
---@param y number
function Fx:Spark(x, y)
    for _ = 1, 6 do
        local ang = Utils.RandRange(-math.pi, math.pi)
        local sp = Utils.RandRange(200, 420)
        Spawn(self, {
            type = "spark",
            x = x, y = y,
            vx = math.cos(ang) * sp,
            vy = math.sin(ang) * sp,
            life = Utils.RandRange(0.16, 0.30),
            size = Utils.RandRange(8, 16),
            color = Config.Theme.text,
        })
    end
end

--- 高速风线（速度感，按速度比例每帧概率生成）
---@param ratio number 速度比例 0..1
---@param worldSpeed number 世界滚动速度
---@param spawnX number 生成 x（屏幕右缘外）
---@param groundY number 地面线（风线只出现在地面上方）
function Fx:SpeedLines(ratio, worldSpeed, spawnX, groundY)
    local F = Config.Fx
    if ratio < F.speedLineStart then return end
    local chance = (ratio - F.speedLineStart) * 2.2
    local n = ratio > 0.82 and 2 or 1
    for _ = 1, n do
        if math.random() < chance then
            local len = Utils.RandRange(50, 130) * (0.6 + ratio * 0.7)
            local vx = -(worldSpeed * 2.4)
            Spawn(self, {
                type = "speedline",
                x = spawnX + 30, y = Utils.RandRange(20, groundY * 0.92),
                vx = vx, vy = 0,
                life = (spawnX + 60 + len) / (-vx),
                size = len,
                color = { 220, 235, 255 },
                alpha = 26 + 54 * ratio,
            })
        end
    end
end

--- 风域上升流（风域托举时在飞鼠脚下生成上飘的光痕）
---@param x number
---@param y number
function Fx:WindStream(x, y)
    Spawn(self, {
        type = "wind",
        x = x + Utils.RandRange(-14, 14),
        y = y + Utils.RandRange(6, 22),
        vx = Utils.RandRange(-20, 10),
        vy = -Utils.RandRange(150, 260),
        life = Utils.RandRange(0.35, 0.55),
        size = Utils.RandRange(8, 16),
        color = Config.Theme.wind,
    })
end

--- 火轮余烬（炫火轮光环的火星）
---@param x number
---@param y number
function Fx:Ember(x, y)
    Spawn(self, {
        type = "ember",
        x = x + Utils.RandRange(-16, 16),
        y = y + Utils.RandRange(-14, 14),
        vx = Utils.RandRange(-60, 20),
        vy = -Utils.RandRange(30, 100),
        life = Utils.RandRange(0.25, 0.45),
        size = Utils.RandRange(1.6, 3),
        color = Config.Theme.fire,
    })
end

--- 飘字（+10 / x3 / 擦身 …）
---@param x number
---@param y number
---@param text string
---@param color number[]
---@param size number|nil
function Fx:FloatText(x, y, text, color, size)
    if #self.floaters >= 24 then table.remove(self.floaters, 1) end
    table.insert(self.floaters, {
        text = text,
        x = x, y = y,
        life = 0.8,
        maxLife = 0.8,
        color = color,
        size = size or 15,
    })
end

-- ---------------------------------------------------------------------------
-- 推进（真实时间）
-- ---------------------------------------------------------------------------

---@param dt number
function Fx:Update(dt)
    local F = Config.Fx
    self.time = self.time + dt

    if self.hitstopTimer > 0 then
        self.hitstopTimer = self.hitstopTimer - dt
    end
    if self.slowMoTimer > 0 then
        self.slowMoTimer = self.slowMoTimer - dt
        if self.slowMoTimer <= 0 then self.timeScale = 1 end
    end
    if self.shake > 0 then
        self.shake = math.max(0, self.shake - dt * F.shakeDecay)
    end
    if self.flash > 0 then
        self.flash = math.max(0, self.flash - dt * F.flashDecay)
    end
    if self.zoomPulse > 0 then
        self.zoomPulse = self.zoomPulse * math.exp(-F.zoomDecay * dt)
        if self.zoomPulse < 0.0005 then self.zoomPulse = 0 end
    end

    for i = #self.parts, 1, -1 do
        local p = self.parts[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(self.parts, i)
        else
            p.x = p.x + (p.vx or 0) * dt
            p.y = p.y + (p.vy or 0) * dt
            if p.gy then p.vy = p.vy + p.gy * dt end
            if p.rot then p.rot = p.rot + (p.vr or 0) * dt end
        end
    end

    for i = #self.floaters, 1, -1 do
        local f = self.floaters[i]
        f.life = f.life - dt
        if f.life <= 0 then
            table.remove(self.floaters, i)
        else
            f.y = f.y - 46 * dt
        end
    end
end

-- ---------------------------------------------------------------------------
-- 绘制（Renderer 在对应层级调用）
-- ---------------------------------------------------------------------------

---@param c number[] 颜色 {r,g,b} 或 {r,g,b,a}
---@param a number 覆盖 alpha 0..255
local function Col(c, a)
    local alpha = math.floor((c[4] or 255) * (a / 255))
    return nvgRGBA(c[1], c[2], c[3], alpha)
end

--- 世界层特效（画在障碍之后、玩家之前）
---@param ctx NVGContextWrapper
function Fx:DrawBack(ctx)
    for i = 1, #self.parts do
        local p = self.parts[i]
        local k = p.life / p.maxLife
        if p.type == "speedline" then
            nvgBeginPath(ctx)
            nvgRect(ctx, p.x - p.size, p.y, p.size, 2)
            nvgFillColor(ctx, nvgRGBA(p.color[1], p.color[2], p.color[3], math.floor((p.alpha or 40) * k)))
            nvgFill(ctx)
        elseif p.type == "wind" then
            nvgBeginPath(ctx)
            nvgRect(ctx, p.x - 1, p.y - p.size, 2, p.size)
            nvgFillColor(ctx, Col(p.color, 150 * k))
            nvgFill(ctx)
        elseif p.type == "puff" then
            local r = p.size + p.grow * (1 - k)
            nvgBeginPath(ctx)
            nvgCircle(ctx, p.x, p.y, r)
            nvgFillColor(ctx, Col(p.color, 70 * k))
            nvgFill(ctx)
        end
    end
end

--- 前景特效（画在玩家之后：星屑 / 碎块 / 火花 / 余烬）
---@param ctx NVGContextWrapper
function Fx:DrawFront(ctx)
    for i = 1, #self.parts do
        local p = self.parts[i]
        local k = p.life / p.maxLife
        if p.type == "shard" then
            nvgBeginPath(ctx)
            nvgCircle(ctx, p.x, p.y, p.size * (0.5 + 0.5 * k))
            nvgFillColor(ctx, Col(p.color, 230 * k))
            nvgFill(ctx)
        elseif p.type == "ember" then
            nvgBeginPath(ctx)
            nvgCircle(ctx, p.x, p.y, p.size)
            nvgFillColor(ctx, Col(p.color, 220 * k))
            nvgFill(ctx)
        elseif p.type == "spark" then
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, p.x, p.y)
            nvgLineTo(ctx, p.x - p.vx * 0.03, p.y - p.vy * 0.03)
            nvgStrokeColor(ctx, Col(p.color, 200 * k))
            nvgStrokeWidth(ctx, 1.6)
            nvgStroke(ctx)
        elseif p.type == "debris" then
            nvgSave(ctx)
            nvgTranslate(ctx, p.x, p.y)
            nvgRotate(ctx, p.rot * math.pi / 180)
            nvgBeginPath(ctx)
            nvgRect(ctx, -p.size * 0.5, -p.size * 0.35, p.size, p.size * 0.7)
            nvgFillColor(ctx, Col(p.color, 235 * k))
            nvgFill(ctx)
            nvgRestore(ctx)
        end
    end
end

--- 飘字（需先设置好字体）
---@param ctx NVGContextWrapper
function Fx:DrawFloaters(ctx)
    if #self.floaters == 0 then return end
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    for i = 1, #self.floaters do
        local f = self.floaters[i]
        local k = f.life / f.maxLife
        -- 出现瞬间 EaseOutBack 弹入，之后淡出
        local pop = Utils.EaseOutBack(Utils.Clamp((1 - k) * 4, 0, 1))
        nvgFontSize(ctx, f.size * (0.6 + 0.4 * pop))
        nvgFillColor(ctx, Col(f.color, 255 * math.min(1, k * 2)))
        nvgText(ctx, f.x, f.y, f.text, nil)
    end
end

--- 全屏闪光覆盖层
---@param ctx NVGContextWrapper
---@param logicalW number
---@param logicalH number
function Fx:DrawFlash(ctx, logicalW, logicalH)
    if self.flash <= 0 then return end
    local c = self.flashColor
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, logicalW, logicalH)
    nvgFillColor(ctx, nvgRGBA(c[1], c[2], c[3], math.floor(255 * math.min(1, self.flash))))
    nvgFill(ctx)
end

return Fx
