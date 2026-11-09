-- ============================================================================
-- World.lua - 滚动世界
-- 职责：障碍 / 收集物 / 道具的生成、移动、回收、碰撞判定
-- 不画图、不改玩家状态，只返回事件结果给 Game 决策
--
-- 碰撞区域示意（飞鼠是圆，障碍是上下两段矩形）
--
--   y=ceiling ┌──────────┐
--             │  树枝上段  │  <- rectAbove
--   y=gapTop  └──────────┘
--                  ↑ 空隙（gap，可通过）
--   y=gapBottom┌──────────┐
--             │  树枝下段  │  <- rectBelow
--   y=groundY  └──────────┘
--
--   只检测 player.x ± radius 与障碍 x 区间是否重叠，再用圆-矩形精判
-- ============================================================================

local Config = require("Config")
local Utils = require("Utils")

---@class Obstacle
---@field x number
---@field gapTop number
---@field gapBottom number
---@field passed boolean       已从玩家身边滚过（结算擦身用）
---@field minClear number      经过期间圆心到空隙边缘的最小净距（半径已扣）

---@class Pickup
---@field x number
---@field y number
---@field r number

---@class Powerup
---@field x number
---@field y number
---@field r number
---@field type string          "shield" | "fire" | "wind"

---@class World
---@field logicalW number
---@field logicalH number
---@field groundY number
---@field ceilingY number
---@field speed number
---@field elapsed number
---@field obstacles Obstacle[]
---@field pickups Pickup[]
---@field powerups Powerup[]
---@field obstacleTimer number
---@field pickupTimer number
---@field nextPickupInterval number
---@field powerupTimer number
---@field nextPowerupInterval number
---@field obstacleCount integer
---@field scrollOffset number
local World = {}
World.__index = World

---@return World
function World.New()
    local self = setmetatable({}, World)
    self:init()
    return self
end

function World:init()
    self.logicalW = 0
    self.logicalH = 0
    self.groundY = 0
    self.ceilingY = 0
    self.speed = Config.World.scrollSpeedStart
    self.elapsed = 0
    self.obstacles = {}
    self.pickups = {}
    self.powerups = {}
    self.obstacleTimer = 0
    self.nextObstacleInterval = self:NextObstacleInterval()
    self.lastInterval = 1.2       -- 上一次生成间隔（纵向衔接约束用）
    self.prevGapCenter = nil      -- 上一组空隙中心 y（nil = 尚无，首组不约束）
    self.pickupTimer = 0
    self.nextPickupInterval = Utils.RandRange(
        Config.Pickup.spawnIntervalMin, Config.Pickup.spawnIntervalMax)
    self.powerupTimer = 0
    self.nextPowerupInterval = Utils.RandRange(
        Config.Powerup.spawnIntervalMin, Config.Powerup.spawnIntervalMax)
    self.obstacleCount = 0
    self.scrollOffset = 0
end

--- 绑定当前屏幕尺寸并清空场上物件
---@param logicalW number
---@param logicalH number
---@param groundY number
---@param ceilingY number
function World:Reset(logicalW, logicalH, groundY, ceilingY)
    self:init()
    self.logicalW = logicalW
    self.logicalH = logicalH
    self.groundY = groundY
    self.ceilingY = ceilingY
end

--- 屏幕尺寸变化时同步（不重置物件）
---@param logicalW number
---@param logicalH number
---@param groundY number
---@param ceilingY number
function World:SyncLayout(logicalW, logicalH, groundY, ceilingY)
    self.logicalW = logicalW
    self.logicalH = logicalH
    self.groundY = groundY
    self.ceilingY = ceilingY
end

--- 当前难度系数 0..1（smoothstep：起步柔、中段陡、后期缓）
---@return number
function World:GetDifficulty()
    return Utils.SmoothStep(Utils.InverseLerp(self.elapsed, 0, Config.World.difficultyTime))
end

--- 每帧推进世界
---@param dt number
---@param player Player
---@return table events {collected={{x,y}...}, powerups={{x,y,type}...}, nearMiss=integer}
function World:Update(dt, player)
    self.elapsed = self.elapsed + dt
    local events = { collected = {}, powerups = {}, nearMiss = 0 }

    -- 1) 速度随难度提升
    local targetSpeed = Utils.Lerp(
        Config.World.scrollSpeedStart,
        Config.World.scrollSpeedMax,
        self:GetDifficulty()
    )
    self.speed = Utils.Lerp(self.speed, targetSpeed, math.min(1, dt * 2))
    self.scrollOffset = self.scrollOffset + self.speed * dt

    -- 2) 障碍移动 + 回收 + 过缝结算（擦身判定）
    for i = #self.obstacles, 1, -1 do
        local ob = self.obstacles[i]
        ob.x = ob.x - self.speed * dt
        if ob.x + Config.Obstacle.width < -20 then
            table.remove(self.obstacles, i)
        elseif not ob.passed and ob.x + Config.Obstacle.width < player.x - player.radius then
            -- 整组树枝滚过玩家：结算擦身
            ob.passed = true
            if ob.minClear < Config.Score.nearMissDist then
                events.nearMiss = events.nearMiss + 1
            end
        end
    end

    -- 3) 收集物 / 道具移动 + 回收
    for i = #self.pickups, 1, -1 do
        local pk = self.pickups[i]
        pk.x = pk.x - self.speed * dt
        if pk.x + pk.r < -20 then
            table.remove(self.pickups, i)
        end
    end
    for i = #self.powerups, 1, -1 do
        local pw = self.powerups[i]
        pw.x = pw.x - self.speed * dt
        if pw.x + pw.r < -20 then
            table.remove(self.powerups, i)
        end
    end

    -- 4) 生成
    self.obstacleTimer = self.obstacleTimer + dt
    if self.obstacleTimer >= self.nextObstacleInterval then
        self.obstacleTimer = 0
        self.lastInterval = self.nextObstacleInterval
        self.nextObstacleInterval = self:NextObstacleInterval()
        self:SpawnObstacle()
    end

    self.pickupTimer = self.pickupTimer + dt
    if self.pickupTimer >= self.nextPickupInterval then
        self.pickupTimer = 0
        self.nextPickupInterval = Utils.RandRange(
            Config.Pickup.spawnIntervalMin, Config.Pickup.spawnIntervalMax)
        self:SpawnPickup()
    end

    self.powerupTimer = self.powerupTimer + dt
    if self.powerupTimer >= self.nextPowerupInterval then
        self.powerupTimer = 0
        self.nextPowerupInterval = Utils.RandRange(
            Config.Powerup.spawnIntervalMin, Config.Powerup.spawnIntervalMax)
        self:SpawnPowerup()
    end

    -- 5) 收集判定：松果
    for i = #self.pickups, 1, -1 do
        local pk = self.pickups[i]
        if Utils.CircleOverlap(player.x, player.y, player.radius, pk.x, pk.y, pk.r) then
            table.remove(self.pickups, i)
            table.insert(events.collected, { x = pk.x, y = pk.y })
        end
    end

    -- 6) 收集判定：道具
    for i = #self.powerups, 1, -1 do
        local pw = self.powerups[i]
        if Utils.CircleOverlap(player.x, player.y, player.radius, pw.x, pw.y, pw.r) then
            table.remove(self.powerups, i)
            table.insert(events.powerups, { x = pw.x, y = pw.y, type = pw.type })
        end
    end

    return events
end

--- 死亡时世界滑停：速度阻尼到 0，物件继续随惯性滚一点
---@param dt number
function World:FreezeToStop(dt)
    self.speed = Utils.Damp(self.speed, 0, 3, dt)
    local move = self.speed * dt
    self.scrollOffset = self.scrollOffset + move
    for i = 1, #self.obstacles do
        self.obstacles[i].x = self.obstacles[i].x - move
    end
    for i = 1, #self.pickups do
        self.pickups[i].x = self.pickups[i].x - move
    end
    for i = 1, #self.powerups do
        self.powerups[i].x = self.powerups[i].x - move
    end
end

--- 下一次障碍的生成间隔（难度越高越密）
---@return number
function World:NextObstacleInterval()
    local O = Config.Obstacle
    local d = self:GetDifficulty()
    local lo = Utils.Lerp(O.spawnIntervalMax, O.spawnIntervalMin, d)
    local hi = Utils.Lerp(O.spawnIntervalMax + 0.3, O.spawnIntervalMin + 0.15, d)
    return Utils.RandRange(lo, hi)
end

--- 生成一组上下树枝（周期性安排"呼吸段"：空隙放宽，给玩家喘息）
function World:SpawnObstacle()
    local O = Config.Obstacle
    local d = self:GetDifficulty()

    -- 空隙随难度收紧
    local gapShrink = O.gapShrink * d
    local gap = Utils.RandRange(O.gapMin - gapShrink, O.gapMax - gapShrink)

    -- 呼吸段：难度起来之后，每几组放宽一次
    self.obstacleCount = self.obstacleCount + 1
    local isBreather = d > 0.35
        and self.obstacleCount % Config.World.breatherEvery == 0
    if isBreather then
        gap = gap * Config.World.breatherGapBonus
    end

    -- 空隙中心在可玩区域内随机
    local playTop = self.ceilingY + O.marginTop
    local playBottom = self.groundY - O.marginTop
    local gapTopMin = playTop
    local gapTopMax = playBottom - gap
    if gapTopMax < gapTopMin then gapTopMax = gapTopMin end

    local gapTop = Utils.RandRange(gapTopMin, gapTopMax)

    -- 纵向衔接约束：新空隙中心相对上一组空隙中心的位移，不得超过玩家在该
    -- 生成间隔内可达的爬升/坠落距离——修复"上一组很低、下一组很高根本爬不上去"
    local center = gapTop + gap * 0.5
    if self.prevGapCenter then
        local W = Config.World
        local climb = math.abs(Config.Player.maxRiseSpeed) * self.lastInterval * W.maxStepFactor
        local drop = Config.Player.maxFallSpeed * self.lastInterval * W.maxStepFactor
        local delta = center - self.prevGapCenter
        if delta > drop then
            center = self.prevGapCenter + drop
        elseif delta < -climb then
            center = self.prevGapCenter - climb
        end
        gapTop = Utils.Clamp(center - gap * 0.5, gapTopMin, gapTopMax)
    end

    table.insert(self.obstacles, {
        x = self.logicalW + O.width,
        gapTop = gapTop,
        gapBottom = gapTop + gap,
        passed = false,
        minClear = math.huge,
    })
    self.prevGapCenter = gapTop + gap * 0.5
end

--- 生成一个松果（优先落在当前空隙附近，保证可吃到）
function World:SpawnPickup()
    local P = Config.Pickup
    local y

    -- 尽量放在最近一组障碍的空隙里，形成"穿缝吃果"的正反馈
    local latest = self.obstacles[#self.obstacles]
    if latest then
        y = Utils.RandRange(latest.gapTop + P.margin, latest.gapBottom - P.margin)
    else
        y = Utils.RandRange(self.ceilingY + P.margin, self.groundY - P.margin)
    end

    table.insert(self.pickups, {
        x = self.logicalW + P.radius * 2,
        y = y,
        r = P.radius,
    })
end

--- 生成一个道具（随机三选一；位置尽量不埋进树枝里）
function World:SpawnPowerup()
    local PU = Config.Powerup
    local types = { "shield", "fire", "wind" }
    local kind = types[Utils.RandInt(1, #types)]

    local x = self.logicalW + PU.radius * 2
    local y = Utils.RandRange(self.ceilingY + PU.margin, self.groundY - PU.margin)

    -- 与已生成障碍的 x 区间重叠时，把 y 夹进该障碍的空隙内
    for i = 1, #self.obstacles do
        local ob = self.obstacles[i]
        if x + PU.radius > ob.x and x - PU.radius < ob.x + Config.Obstacle.width then
            y = Utils.Clamp(y, ob.gapTop + PU.margin * 0.5, ob.gapBottom - PU.margin * 0.5)
            break
        end
    end

    table.insert(self.powerups, {
        x = x,
        y = y,
        r = PU.radius,
        type = kind,
    })
end

--- 障碍碰撞判定（飞鼠圆 vs 上下两段矩形），返回命中的障碍（供护盾/火轮处理）
---@param player Player
---@return Obstacle|nil hitOb
function World:CheckCrash(player)
    local w = Config.Obstacle.width
    local r = player.radius
    local cx = player.x
    local cy = player.y

    for i = 1, #self.obstacles do
        local ob = self.obstacles[i]

        -- 粗筛：x 方向不重叠直接跳过，省掉精判
        if cx + r > ob.x and cx - r < ob.x + w then
            -- 记录经过期间的最小净距（擦身判定用，负数=已撞入）
            local clear = math.min(cy - ob.gapTop, ob.gapBottom - cy) - r
            if clear < ob.minClear then ob.minClear = clear end

            -- 上段：[ceilingY, gapTop]
            local aboveH = ob.gapTop - self.ceilingY
            if aboveH > 0 and Utils.CircleRectOverlap(cx, cy, r, ob.x, self.ceilingY, w, aboveH) then
                return ob
            end
            -- 下段：[gapBottom, groundY]
            local belowH = self.groundY - ob.gapBottom
            if belowH > 0 and Utils.CircleRectOverlap(cx, cy, r, ob.x, ob.gapBottom, w, belowH) then
                return ob
            end
        end
    end

    return nil
end

--- 撞毁一组障碍（护盾抵挡 / 炫火轮），返回碎裂点供特效使用
---@param ob Obstacle
---@return table {x, y}
function World:ShatterObstacle(ob)
    local pos = {
        x = ob.x + Config.Obstacle.width * 0.5,
        y = (ob.gapTop + ob.gapBottom) * 0.5,
    }
    for i = 1, #self.obstacles do
        if self.obstacles[i] == ob then
            table.remove(self.obstacles, i)
            break
        end
    end
    return pos
end

return World
