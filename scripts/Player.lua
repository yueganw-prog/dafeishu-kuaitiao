-- ============================================================================
-- Player.lua - 大飞鼠（玩家实体）
-- 只负责"自己的物理与状态"，不知道世界、不知道渲染
--
-- 操控模型（混合式）：
--   PressDown() -> 扇翅冲量（瞬间抬升）+ 进入按住状态
--   按住期间    -> 推力沿缓动曲线从重力"咬合"到全推力（先柔后猛）
--   Release()   -> 推力快速泄回重力
--   风域道具    -> 托举：vy 阻尼到目标上升速度，无视重力与推力
--
-- 输入约定：外部调用 PressDown / Release，本模块不订阅事件
-- ============================================================================

local Config = require("Config")
local Utils = require("Utils")

---@class Player
---@field x number            屏幕坐标 x（固定）
---@field y number            屏幕坐标 y
---@field vy number           纵向速度（正=下落）
---@field radius number       碰撞半径
---@field tilt number         当前俯仰角（度，纯视觉）
---@field holding boolean     是否按住
---@field alive boolean       是否存活
---@field thrustT number      推力咬合进度 0..1
---@field squashPulse number  扇翅压扁脉冲 1->0
---@field trail table[]       残影轨迹点 {x,y,life}
---@field shield boolean      寒冰护盾（挡一次树枝）
---@field fireTimer number    炫火轮光环剩余时长
---@field windTimer number    风域托举剩余时长
---@field invTimer number     无敌剩余时长
---@field dying boolean       死亡翻滚中（撞树坠落）
---@field deathRot number     死亡翻滚角度
---@field offscreen boolean   尸体已落出屏幕
local Player = {}
Player.__index = Player

--- 工厂：字段统一在 :init 里初始化（避免 LSP undefined-field 误报）
---@return Player
function Player.New()
    local self = setmetatable({}, Player)
    self:init()
    return self
end

--- 初始化 / 复位字段
function Player:init()
    local P = Config.Player
    self.x = 0
    self.y = 0
    self.vy = 0
    self.radius = P.radius
    self.tilt = 0
    self.holding = false
    self.alive = true

    self.thrustT = 0
    self.squashPulse = 0
    self.trail = {}
    self.trailTimer = 0

    self.shield = false
    self.fireTimer = 0
    self.windTimer = 0
    self.invTimer = 0

    self.dying = false
    self.deathRot = 0
    self.offscreen = false
end

--- 按当前屏幕尺寸重新摆放并清空状态
---@param logicalW number
---@param logicalH number
---@param groundY number
function Player:Reset(logicalW, logicalH, groundY)
    local P = Config.Player
    self:init()
    self.x = logicalW * P.xRatio
    self.y = groundY * 0.5   -- 可玩区域（0 ~ groundY）垂直居中
end

--- 按下：扇翅冲量 + 开始按住（触屏/鼠标/空格统一入口）
function Player:PressDown()
    if not self.alive then return end
    local P = Config.Player
    self.holding = true
    self.thrustT = 0
    self.vy = math.max(self.vy - P.flapImpulse, P.maxRiseSpeed)
    self.squashPulse = 1
end

--- 抬起
function Player:Release()
    self.holding = false
end

--- 当前俯仰角（度）：上升时抬头，下落时低头
---@return number
function Player:GetTilt()
    return self.tilt
end

--- 挤压拉伸系数（供渲染）：高速拉伸 + 扇翅压扁脉冲
---@return number sx, number sy
function Player:GetStretch()
    local P = Config.Player
    local vn = math.min(1, math.abs(self.vy) / P.maxFallSpeed)
    local pulse = self.squashPulse
    local sy = 1 + P.stretchAmp * vn - 0.26 * pulse
    local sx = 1 - P.squashAmp * vn + 0.22 * pulse
    return Utils.Clamp(sx, 0.62, 1.4), Utils.Clamp(sy, 0.62, 1.4)
end

--- 每帧推进物理
---@param dt number
---@param groundY number 地面线 y
---@param ceilingY number 顶部边界 y
---@param worldSpeed number|nil 世界滚动速度（残影随世界左移）
function Player:Update(dt, groundY, ceilingY, worldSpeed)
    if not self.alive then return end

    local P = Config.Player
    local PU = Config.Powerup

    -- 0) 道具/状态计时
    if self.fireTimer > 0 then self.fireTimer = math.max(0, self.fireTimer - dt) end
    if self.windTimer > 0 then self.windTimer = math.max(0, self.windTimer - dt) end
    if self.invTimer > 0 then self.invTimer = math.max(0, self.invTimer - dt) end

    -- 1) 加速度：风域托举 > 滑翔推力曲线 > 重力
    if self.windTimer > 0 then
        -- 风域：直接把 vy 阻尼到托举速度，无视重力（点按仍可叠加冲量）
        self.vy = Utils.Damp(self.vy, PU.windLiftSpeed, PU.windDampSpeed, dt)
    else
        if self.holding then
            self.thrustT = math.min(1, self.thrustT + dt / P.thrustRampTime)
        else
            self.thrustT = math.max(0, self.thrustT - dt / P.thrustReleaseTime)
        end
        -- 推力曲线：thrustT=0 时等于重力（自由落体），=1 时全推力
        local accel = Utils.Lerp(P.gravity, P.holdAccel, Utils.EaseOutQuad(self.thrustT))
        self.vy = Utils.Clamp(self.vy + accel * dt, P.maxRiseSpeed, P.maxFallSpeed)
    end

    -- 2) 位移
    self.y = self.y + self.vy * dt

    -- 3) 边界：顶部弹簧缓冲（撞天花板不死，轻微反弹）
    local topLimit = ceilingY + self.radius
    if self.y < topLimit then
        self.y = topLimit
        if self.vy < 0 then
            self.vy = -self.vy * P.ceilingRestitution
        end
    end

    -- 4) 边界：落地即失败
    local bottomLimit = groundY - self.radius
    if self.y >= bottomLimit then
        self.y = bottomLimit
        self.alive = false
        self.holding = false
    end

    -- 5) 视觉俯仰角跟随速度
    local targetTilt = (self.vy / P.maxFallSpeed) * P.tiltMaxDeg
    self.tilt = Utils.Damp(self.tilt, targetTilt, P.tiltLerp, dt)

    -- 6) 扇翅脉冲衰减
    if self.squashPulse > 0 then
        self.squashPulse = math.max(0, self.squashPulse - dt / P.squashPulseTime)
    end

    -- 7) 残影轨迹：周期采样，随世界左移并淡出
    self.trailTimer = self.trailTimer + dt
    if self.trailTimer >= P.trailInterval then
        self.trailTimer = 0
        table.insert(self.trail, { x = self.x, y = self.y, life = P.trailLife })
        if #self.trail > 14 then table.remove(self.trail, 1) end
    end
    for i = #self.trail, 1, -1 do
        local t = self.trail[i]
        t.x = t.x - (worldSpeed or 0) * dt
        t.life = t.life - dt
        if t.life <= 0 then table.remove(self.trail, i) end
    end
end

--- 死亡翻滚（撞树后由 Game 驱动；落地死不需要）
---@param dt number
---@param groundY number
function Player:UpdateDeath(dt, groundY)
    if not self.dying then return end
    self.vy = math.min(self.vy + 2400 * dt, 900)
    self.y = self.y + self.vy * dt
    self.deathRot = self.deathRot + 380 * dt
    if self.y > groundY + self.radius * 4 then
        self.dying = false
        self.offscreen = true
    end
end

--- 立即死亡（由 Game 调用）
---@param tumble boolean true=撞树（翻滚坠落）；false=落地
function Player:Kill(tumble)
    self.alive = false
    self.holding = false
    self.dying = tumble and true or false
    self.deathRot = 0
end

return Player
