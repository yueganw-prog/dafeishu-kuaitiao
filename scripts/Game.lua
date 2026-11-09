-- ============================================================================
-- Game.lua - 游戏主控制器（状态机 + 计分 + 难度编排 + 反馈接线）
--
-- 状态流转：
--   menu --(点击)--> playing --(撞树/落地)--> gameover --(点击)--> playing
--
-- 调度顺序（每帧）：
--   Fx:Update(真实dt) -> Fx:GetDt 换算 -> Player:Update -> World:Update
--   -> 事件反馈(粒子/飘字/音效) -> CheckCrash -> 护盾/火轮/坠毁处理
--
-- 死亡序列（撞树）：hit-stop 冻结 -> 白闪 + 大屏震 + 碎屑 -> 慢动作翻滚坠落
--                   -> 世界滑停 -> 结算面板弹出
-- ============================================================================

local Config = require("Config")
local Utils = require("Utils")
local Player = require("Player")
local World = require("World")
local Fx = require("Fx")
local Audio = require("Audio")

---@class Game
---@field state string            "menu" | "playing" | "gameover"
---@field player Player
---@field world World
---@field fx Fx
---@field logicalW number
---@field logicalH number
---@field groundY number
---@field ceilingY number
---@field score number
---@field bestScore number
---@field pickupScore number
---@field distanceScore number
---@field bonusScore number       擦身/火轮撞毁等额外分
---@field traveled number        已滚动距离（逻辑像素）
---@field runTime number         本局时长
---@field overTime number        结算动画计时
---@field combo integer          连续收集计数
---@field comboTimer number      连收判定窗口剩余
---@field scorePopT number       得分弹跳 1->0
---@field fxAccum number         道具伴随粒子节流
local Game = {}
Game.__index = Game

---@return Game
function Game.New()
    local self = setmetatable({}, Game)
    self:init()
    return self
end

function Game:init()
    self.state = "menu"
    self.player = Player.New()
    self.world = World.New()
    self.fx = Fx.New()
    self.logicalW = 0
    self.logicalH = 0
    self.groundY = 0
    self.ceilingY = 0
    self.score = 0
    self.bestScore = 0
    self.pickupScore = 0
    self.distanceScore = 0
    self.bonusScore = 0
    self.traveled = 0
    self.runTime = 0
    self.overTime = 0
    self.combo = 0
    self.comboTimer = 0
    self.scorePopT = 0
    self.fxAccum = 0
    self.mode = "hard"
    self:ApplyDifficulty(self.mode)
end

--- 应用难度档位：把选中档位的数值覆盖进生效配置。
--- 说明：Config 是全项目唯一生效配置表（World/Player 都直读它），
--- 档位切换即整表覆盖对应键；选择保持到下次改选，重开不重置。
---@param mode string "easy" | "hard" | "hell"
function Game:ApplyDifficulty(mode)
    local D = Config.Difficulty[mode]
    if not D then return end
    self.mode = mode
    for k, v in pairs(D.world or {}) do Config.World[k] = v end
    for k, v in pairs(D.obstacle or {}) do Config.Obstacle[k] = v end
    for k, v in pairs(D.player or {}) do Config.Player[k] = v end
    for k, v in pairs(D.powerup or {}) do Config.Powerup[k] = v end
end

--- 菜单难度按钮的矩形（渲染与点击命中共用同一来源，保证对齐）
---@param logicalW number
---@param logicalH number
---@return table[] {mode,label,x,y,w,h}
function Game:GetModeButtonRects(logicalW, logicalH)
    local bw, bh, gapX = 128, 46, 14
    local total = bw * 3 + gapX * 2
    local x0 = (logicalW - total) * 0.5
    local y = logicalH * 0.5 + 108
    local rects = {}
    for i, mode in ipairs({ "easy", "hard", "hell" }) do
        rects[i] = {
            mode = mode,
            label = Config.Difficulty[mode].label,
            x = x0 + (i - 1) * (bw + gapX),
            y = y,
            w = bw,
            h = bh,
        }
    end
    return rects
end

--- 屏幕尺寸变化：重算地面线、顶部边界，并同步玩家/世界
---@param logicalW number
---@param logicalH number
function Game:OnLayout(logicalW, logicalH)
    self.logicalW = logicalW
    self.logicalH = logicalH
    self.groundY = logicalH * (1 - Config.World.groundHeightRatio)
    self.ceilingY = 0

    if self.state == "playing" or self.state == "gameover" then
        -- 对局中改变窗口尺寸：只同步布局，不重置进度
        self.world:SyncLayout(logicalW, logicalH, self.groundY, self.ceilingY)
        self.player.x = logicalW * Config.Player.xRatio
    else
        self.player:Reset(logicalW, logicalH, self.groundY)
        self.world:SyncLayout(logicalW, logicalH, self.groundY, self.ceilingY)
    end
end

--- 开新一局
function Game:StartRun()
    self.state = "playing"
    self.score = 0
    self.pickupScore = 0
    self.distanceScore = 0
    self.bonusScore = 0
    self.traveled = 0
    self.runTime = 0
    self.overTime = 0
    self.combo = 0
    self.comboTimer = 0
    self.scorePopT = 0
    self.fxAccum = 0

    self.fx:Reset()
    Audio.StopAll()

    self.player:Reset(self.logicalW, self.logicalH, self.groundY)
    self.world:Reset(self.logicalW, self.logicalH, self.groundY, self.ceilingY)

    print("[Game] Start run")
end

--- 按下（触屏/鼠标按下、空格按下）
---@param px number|nil 按点 x（逻辑像素；键盘/无坐标为 nil）
---@param py number|nil 按点 y
function Game:PressDown(px, py)
    if self.state == "menu" then
        -- 菜单态：先判难度按钮命中，命中只切档不开局
        if px ~= nil and py ~= nil then
            for _, r in ipairs(self:GetModeButtonRects(self.logicalW, self.logicalH)) do
                if px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h then
                    if self.mode ~= r.mode then
                        self:ApplyDifficulty(r.mode)
                        print("[Game] difficulty -> " .. r.mode)
                    end
                    return
                end
            end
        end
        self:StartRun()
        self.player:PressDown()
        self:FlapFeedback()
    elseif self.state == "gameover" then
        -- 结算面板完全出来后才接受"再来一局"，避免手滑跳过
        if self.overTime >= Config.Fx.restartGate then
            self:StartRun()
            self.player:PressDown()
            self:FlapFeedback()
        end
    else
        self.player:PressDown()
        self:FlapFeedback()
    end
end

--- 抬起
function Game:PressUp()
    self.player:Release()
end

--- 扇翅反馈：气团 + 音效
function Game:FlapFeedback()
    local p = self.player
    self.fx:Puff(p.x - p.radius * 0.5, p.y + p.radius * 0.8)
    Audio.Play("flap")
end

--- 每帧更新
---@param dt number 真实 dt（特效层按它走）
function Game:Update(dt)
    local F = Config.Fx

    -- 1) 特效层永远按真实时间推进
    self.fx:Update(dt)
    local sdt = self.fx:GetDt(dt)   -- 玩法层 dt（hit-stop=0 / 慢动作=缩放）

    if self.scorePopT > 0 then
        self.scorePopT = math.max(0, self.scorePopT - dt * 3)
    end
    if self.comboTimer > 0 then
        self.comboTimer = self.comboTimer - sdt
        if self.comboTimer <= 0 then self.combo = 0 end
    end

    if self.state == "menu" then
        return
    end

    if self.state == "gameover" then
        self.overTime = self.overTime + dt
        -- 尸体翻滚 + 世界滑停（跟随慢动作节奏）
        self.player:UpdateDeath(sdt, self.groundY)
        self.world:FreezeToStop(sdt)
        return
    end

    -- ---- playing ----
    self.runTime = self.runTime + sdt
    if sdt <= 0 then return end   -- hit-stop 冻结帧：画面保持，物理暂停

    -- 2) 玩家物理
    self.player:Update(sdt, self.groundY, self.ceilingY, self.world.speed)

    -- 3) 世界推进（返回事件：收集/道具/擦身）
    local ev = self.world:Update(sdt, self.player)
    self:HandleWorldEvents(ev)

    -- 4) 道具伴随粒子（节流 0.05s 一批）+ 高速风线
    self.fxAccum = self.fxAccum + sdt
    if self.fxAccum >= 0.05 then
        self.fxAccum = 0
        local p = self.player
        if p.fireTimer > 0 then
            self.fx:Ember(p.x - p.radius, p.y + Utils.RandRange(-p.radius, p.radius))
        end
        if p.windTimer > 0 then
            self.fx:WindStream(p.x, p.y)
        end
    end
    self.fx:SpeedLines(
        Utils.InverseLerp(self.world.speed, Config.World.scrollSpeedStart, Config.World.scrollSpeedMax),
        self.world.speed, self.logicalW, self.groundY)

    -- 5) 计分
    self.traveled = self.world.scrollOffset
    self.distanceScore = math.floor(self.traveled / Config.Score.distancePerPoint)
    self.score = self.distanceScore + self.pickupScore + self.bonusScore

    -- 6) 碰撞判定（无敌期间直接穿过）
    if self.player.invTimer <= 0 then
        local hitOb = self.world:CheckCrash(self.player)
        if hitOb then
            self:HandleHit(hitOb)
            if self.state ~= "playing" then return end
        end
    end

    -- 7) 落地失败（护盾救不了地面）
    if not self.player.alive then
        self:GroundDeath()
    end
end

--- 处理世界事件：收集 / 道具 / 擦身
---@param ev table
function Game:HandleWorldEvents(ev)
    local T = Config.Theme
    local S = Config.Score

    -- 松果：星屑 + 飘字 + combo 音调递升
    for _, pk in ipairs(ev.collected) do
        self.combo = self.combo + 1
        self.comboTimer = S.comboWindow
        self.pickupScore = self.pickupScore + S.pickupValue

        self.fx:Burst(pk.x, pk.y, T.pickup, 10)
        self.fx:AddZoom(Config.Fx.zoomPulsePickup)
        self.fx:FloatText(pk.x, pk.y - 14, "+" .. S.pickupValue, T.pickup, 15)
        if self.combo > 1 then
            self.fx:FloatText(pk.x, pk.y - 36, "x" .. self.combo, T.text, 13)
        end

        local step = math.min(self.combo - 1, S.comboMaxStep)
        Audio.Play("pickup", { pitch = 1 + step * S.comboPitchStep })
        self.scorePopT = 1
    end

    -- 道具
    for _, pw in ipairs(ev.powerups) do
        self:ApplyPowerup(pw.type, pw.x, pw.y)
    end

    -- 擦身
    if ev.nearMiss > 0 then
        local gain = ev.nearMiss * S.nearMissValue
        self.bonusScore = self.bonusScore + gain
        local p = self.player
        self.fx:Spark(p.x, p.y)
        self.fx:FloatText(p.x, p.y - 30, Config.Text.nearMissText .. " +" .. gain, T.textDim, 14)
        Audio.Play("nearmiss")
        self.scorePopT = 1
    end
end

--- 应用道具效果
---@param kind string "shield" | "fire" | "wind"
---@param x number
---@param y number
function Game:ApplyPowerup(kind, x, y)
    local PU = Config.Powerup
    local T = Config.Theme
    local Text = Config.Text

    if kind == "shield" then
        self.player.shield = true
        self.fx:Burst(x, y, T.shield, 16)
        self.fx:FloatText(x, y - 20, Text.powerupShield, T.shield, 16)
        Audio.Play("powerup")
    elseif kind == "fire" then
        self.player.fireTimer = PU.fireDuration
        self.fx:Burst(x, y, T.fire, 16)
        self.fx:FloatText(x, y - 20, Text.powerupFire, T.fire, 16)
        Audio.Play("powerup")
    else
        self.player.windTimer = PU.windDuration
        self.fx:Burst(x, y, T.wind, 16)
        self.fx:FloatText(x, y - 20, Text.powerupWind, T.wind, 16)
        Audio.Play("powerup")
    end

    self.fx:AddZoom(Config.Fx.zoomPulsePowerup)
    self.fx:AddFlash(Config.Fx.powerupFlash, T.text)
    self.scorePopT = 1
end

--- 撞上树枝：按 炫火轮 > 护盾 > 坠毁 的顺序处理
---@param ob Obstacle
function Game:HandleHit(ob)
    local PU = Config.Powerup
    local F = Config.Fx
    local T = Config.Theme
    local p = self.player

    -- 炫火轮光环：撞毁树枝拿分
    if p.fireTimer > 0 then
        local pos = self.world:ShatterObstacle(ob)
        self.bonusScore = self.bonusScore + PU.fireScore
        self.fx:Debris(pos.x, pos.y, T.obstacle, 16)
        self.fx:AddShake(0.45)
        self.fx:FloatText(pos.x, pos.y - 22, "+" .. PU.fireScore, T.fire, 18)
        Audio.Play("fire")
        self.scorePopT = 1
        return
    end

    -- 寒冰护盾：消耗掉，碎枝 + 短暂无敌穿过
    if p.shield then
        p.shield = false
        p.invTimer = PU.shieldInvincibleTime
        local pos = self.world:ShatterObstacle(ob)
        self.fx:Debris(pos.x, pos.y, T.obstacle, 14)
        self.fx:AddFlash(0.5, T.shield)
        self.fx:AddShake(F.shieldShake)
        self.fx:FloatText(p.x, p.y - 34, Config.Text.shieldBlockText, T.shield, 16)
        Audio.Play("shield")
        self.scorePopT = 1
        return
    end

    -- 真坠毁：hit-stop -> 白闪 + 大震 + 碎屑 -> 慢动作翻滚坠落
    self.fx:HitStop(F.hitStopTime)
    self.fx:AddFlash(F.crashFlash, { 255, 255, 255 })
    self.fx:AddShake(F.crashShake)
    self.fx:Debris(p.x, p.y, T.furMembrane, 18)
    self.fx:SlowMo(F.slowMoScale, F.slowMoTime)
    Audio.Play("crash")
    p:Kill(true)
    self:EndRun(true)
end

--- 落地失败（不做翻滚，已在地上）
function Game:GroundDeath()
    local F = Config.Fx
    self.fx:AddFlash(0.4, { 255, 255, 255 })
    self.fx:AddShake(0.6)
    Audio.Play("crash")
    self.player:Kill(false)
    self:EndRun(false)
end

--- 结束本局
---@param crashed boolean
function Game:EndRun(crashed)
    if self.state ~= "playing" then return end

    self.state = "gameover"
    self.overTime = 0

    if self.score > self.bestScore then
        self.bestScore = self.score
    end

    print(string.format("[Game] Run over - score=%d (distance=%d, pickup=%d, bonus=%d) time=%.1fs",
        self.score, self.distanceScore, self.pickupScore, self.bonusScore, self.runTime))
end

--- 结算标语：按分数分档（<100 / 100~300 / >300）
---@return string
function Game:GetOverSlogan()
    local G = Config.GameOver
    if self.score < G.tier2Min then return G.slogan1 end
    if self.score <= G.tier2Max then return G.slogan2 end
    return G.slogan3
end

--- 供渲染层读取的 HUD 数据快照
---@return table
function Game:GetHudData()
    return {
        state = self.state,
        score = self.score,
        best = self.bestScore,
        speed = self.world.speed,
        runTime = self.runTime,
        overTime = self.overTime,
        shake = self.fx.shake,
        combo = self.combo,
        scorePopT = self.scorePopT,
    }
end

return Game
