-- ============================================================================
-- Renderer.lua - 全部 NanoVG 绘制
-- 本项目采用"整条渲染管线都是 raw NanoVG"的方案（见 AGENTS.md 规则 #8），
-- 因此不引入 urhox-libs/UI，避免同帧渲染层级冲突。
--
-- 分辨率模式：B（系统逻辑分辨率）
--   nvgBeginFrame(vg, logicalW, logicalH, dpr)
--   1 逻辑像素 = dpr 物理像素 → 高 DPI 屏清晰，布局按逻辑像素书写
--
-- 绘制顺序：
--   [缩放脉冲+震屏变换] 背景 → 地面 → 特效背层(风线/气流/气团) → 树枝
--   → 道具 → 松果 → 残影 → 玩家(+护盾/火环/风域光圈) → 特效前层 → 飘字
--   [恢复变换] 全屏闪光 → HUD → 菜单/结算遮罩
-- ============================================================================

local Config = require("Config")
local Utils = require("Utils")

---@class Renderer
---@field ctx NVGContextWrapper
---@field font string
local Renderer = {}
Renderer.__index = Renderer

---@param ctx NVGContextWrapper
---@return Renderer
function Renderer.New(ctx)
    local self = setmetatable({}, Renderer)
    self:init(ctx)
    return self
end

---@param ctx NVGContextWrapper
function Renderer:init(ctx)
    self.ctx = ctx
    self.font = "sans"
end

-- ---------------------------------------------------------------------------
-- 颜色小工具
-- ---------------------------------------------------------------------------

---@param c table  {r,g,b,a}
---@param a number|nil 覆盖 alpha
---@return NVGcolor
local function C(c, a)
    return nvgRGBA(c[1], c[2], c[3], a or c[4])
end

-- ---------------------------------------------------------------------------
-- 主绘制入口
-- ---------------------------------------------------------------------------

---@param game Game
---@param logicalW number
---@param logicalH number
---@param dpr number 设备像素比（模式 B 必须传给 nvgBeginFrame）
---@param time number 累计时间（秒），用于呼吸/飘动动画
function Renderer:Draw(game, logicalW, logicalH, dpr, time)
    local ctx = self.ctx
    local fx = game.fx

    nvgBeginFrame(ctx, logicalW, logicalH, dpr)

    -- 镜头缩放脉冲 + 震屏（HUD 不受影响）
    local zoom = fx:GetZoom()
    local ox, oy, rotDeg = fx:GetTransform()
    local transformed = zoom ~= 1 or rotDeg ~= 0 or ox ~= 0 or oy ~= 0
    if transformed then
        nvgSave(ctx)
        local cx = logicalW * 0.5
        local cy = logicalH * 0.5
        if zoom ~= 1 then
            nvgTranslate(ctx, cx, cy)
            nvgScale(ctx, zoom, zoom)
            nvgTranslate(ctx, -cx, -cy)
        end
        if rotDeg ~= 0 then
            nvgTranslate(ctx, cx, cy)
            nvgRotate(ctx, rotDeg * math.pi / 180)
            nvgTranslate(ctx, -cx, -cy)
        end
        if ox ~= 0 or oy ~= 0 then
            nvgTranslate(ctx, ox, oy)
        end
    end

    self:DrawBackground(game, logicalW, logicalH, time)
    self:DrawGround(game, logicalW, logicalH)
    fx:DrawBack(ctx)              -- 风线 / 风域气流 / 扇翅气团
    self:DrawObstacles(game)
    self:DrawPowerups(game, time)
    self:DrawPickups(game, time)
    self:DrawTrail(game)
    self:DrawPlayer(game, time)
    fx:DrawFront(ctx)             -- 星屑 / 碎块 / 火花 / 余烬

    nvgFontFace(ctx, self.font)
    fx:DrawFloaters(ctx)

    if transformed then
        nvgRestore(ctx)
    end

    -- 闪光 / HUD / 遮罩不受镜头变换影响
    fx:DrawFlash(ctx, logicalW, logicalH)
    self:DrawHud(game, logicalW, logicalH)
    self:DrawMenuOverlay(game, logicalW, logicalH, time)
    self:DrawGameOverOverlay(game, logicalW, logicalH)

    nvgEndFrame(ctx)
end

-- ---------------------------------------------------------------------------
-- 背景：天空渐变 + 远山 + 近山（视差）
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawBackground(game, logicalW, logicalH, time)
    local ctx = self.ctx
    local T = Config.Theme
    local groundY = game.groundY
    local scroll = game.world.scrollOffset
    -- 天空
    local sky = nvgLinearGradient(ctx, 0, 0, 0, groundY, C(T.skyTop), C(T.skyBottom))
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, logicalW, groundY)
    nvgFillPaint(ctx, sky)
    nvgFill(ctx)

    -- 月亮
    local moonX = logicalW * 0.82
    local moonY = logicalH * 0.16
    local moonGlow = nvgRadialGradient(ctx, moonX, moonY, 8, 62,
        nvgRGBA(255, 248, 220, 90), nvgRGBA(255, 248, 220, 0))
    nvgBeginPath(ctx)
    nvgCircle(ctx, moonX, moonY, 62)
    nvgFillPaint(ctx, moonGlow)
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgCircle(ctx, moonX, moonY, 22)
    nvgFillColor(ctx, nvgRGBA(255, 250, 228, 235))
    nvgFill(ctx)

    -- 远山 / 近山：两层不同视差系数
    self:DrawHills(logicalW, groundY, scroll * 0.18, T.hillFar, 130, 340, 0.9)
    self:DrawHills(logicalW, groundY, scroll * 0.42, T.hillNear, 74, 220, 1.5)
end

--- 重复绘制一条起伏山脊
--- 起点固定在屏幕外一个波长处，靠 phase(offset) 让波形左移，形成视差滚动
local function DrawHillLayer(ctx, logicalW, baseY, offset, color, amp, wavelength, seed)
    local startX = -wavelength
    local step = wavelength * 0.25
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, startX, baseY)
    local x = startX
    while x <= logicalW + wavelength do
        local t = (x + offset) / wavelength
        local y = baseY - amp * (0.5 + 0.5 * math.sin(t * math.pi * 2 + seed))
        nvgLineTo(ctx, x, y)
        x = x + step
    end
    nvgLineTo(ctx, logicalW + wavelength, baseY)
    nvgClosePath(ctx)
    nvgFillColor(ctx, color)
    nvgFill(ctx)
end

---@param logicalW number
---@param groundY number
---@param offset number
---@param color table
---@param amp number
---@param wavelength number
---@param seed number
function Renderer:DrawHills(logicalW, groundY, offset, color, amp, wavelength, seed)
    DrawHillLayer(self.ctx, logicalW, groundY, offset, color, amp, wavelength, seed)
end

-- ---------------------------------------------------------------------------
-- 地面
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawGround(game, logicalW, logicalH)
    local ctx = self.ctx
    local T = Config.Theme
    local groundY = game.groundY
    local h = logicalH - groundY
    local scroll = game.world.scrollOffset

    -- 地面主体
    local grd = nvgLinearGradient(ctx, 0, groundY, 0, logicalH, C(T.groundTop), C(T.groundBody))
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, groundY, logicalW, h)
    nvgFillPaint(ctx, grd)
    nvgFill(ctx)

    -- 顶部高光线
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, groundY, logicalW, 2)
    nvgFillColor(ctx, nvgRGBA(120, 190, 130, 150))
    nvgFill(ctx)

    -- 滚动草纹（证明世界在动，提供速度感）
    local spacing = 34
    local startX = -(scroll % spacing)
    local x = startX
    nvgBeginPath(ctx)
    while x <= logicalW + spacing do
        nvgRect(ctx, x, groundY + 6, 3, 7)
        nvgRect(ctx, x + 9, groundY + 4, 3, 9)
        x = x + spacing
    end
    nvgFillColor(ctx, nvgRGBA(78, 132, 88, 200))
    nvgFill(ctx)
end

-- ---------------------------------------------------------------------------
-- 障碍：上下两段树枝
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawObstacles(game)
    local ctx = self.ctx
    local w = Config.Obstacle.width
    local groundY = game.groundY
    local ceilingY = game.ceilingY

    for i = 1, #game.world.obstacles do
        local ob = game.world.obstacles[i]

        -- 上段：[ceilingY, gapTop]
        local aboveH = ob.gapTop - ceilingY
        if aboveH > 0 then
            self:DrawBranch(ob.x, ceilingY, w, aboveH, false)
        end

        -- 下段：[gapBottom, groundY]
        local belowH = groundY - ob.gapBottom
        if belowH > 0 then
            self:DrawBranch(ob.x, ob.gapBottom, w, belowH, true)
        end
    end
end

--- 画一根树干（含树皮纹理与枝节）
---@param x number
---@param y number
---@param w number
---@param h number
---@param isBottom boolean 底部段的"顶端"朝向空隙
function Renderer:DrawBranch(x, y, w, h, isBottom)
    local ctx = self.ctx
    local T = Config.Theme

    local grd = nvgLinearGradient(ctx, x, y, x + w, y, C(T.obstacleTop), C(T.obstacle))
    nvgBeginPath(ctx)
    nvgRect(ctx, x, y, w, h)
    nvgFillPaint(ctx, grd)
    nvgFill(ctx)

    -- 树皮竖纹
    nvgBeginPath(ctx)
    nvgRect(ctx, x + w * 0.28, y, 3, h)
    nvgRect(ctx, x + w * 0.66, y, 2, h)
    nvgFillColor(ctx, nvgRGBA(48, 34, 24, 110))
    nvgFill(ctx)

    -- 朝向空隙的一侧加深色封口，交代"被锯断"的截面
    local capH = 10
    local capY = isBottom and y or (y + h - capH)
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, x - 3, capY, w + 6, capH, 3)
    nvgFillColor(ctx, nvgRGBA(132, 96, 62, 255))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, x - 3, capY, w + 6, capH, 3)
    nvgStrokeColor(ctx, nvgRGBA(40, 28, 20, 180))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)

    -- 几根小枝杈，增加剪影辨识度
    local stubY = isBottom and (y + h * 0.35) or (y + h * 0.6)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, x, stubY)
    nvgLineTo(ctx, x - 16, stubY - 10)
    nvgLineTo(ctx, x, stubY + 5)
    nvgMoveTo(ctx, x + w, stubY + 18)
    nvgLineTo(ctx, x + w + 15, stubY + 26)
    nvgLineTo(ctx, x + w, stubY + 30)
    nvgFillColor(ctx, C(T.obstacle))
    nvgFill(ctx)
end

-- ---------------------------------------------------------------------------
-- 道具：寒冰护盾（六边形）/ 炫火轮（火环）/ 风域（旋涡）
-- ---------------------------------------------------------------------------

---@param game Game
---@param time number
function Renderer:DrawPowerups(game, time)
    local ctx = self.ctx
    local T = Config.Theme

    for i = 1, #game.world.powerups do
        local pw = game.world.powerups[i]
        local pulse = 0.9 + 0.1 * math.sin(time * 3 + pw.x * 0.04)
        local r = pw.r * pulse
        local col

        if pw.type == "shield" then
            col = T.shield
        elseif pw.type == "fire" then
            col = T.fire
        else
            col = T.wind
        end

        -- 光晕
        local glow = nvgRadialGradient(ctx, pw.x, pw.y, r * 0.4, r * 2.8,
            C(col, 70), C(col, 0))
        nvgBeginPath(ctx)
        nvgCircle(ctx, pw.x, pw.y, r * 2.8)
        nvgFillPaint(ctx, glow)
        nvgFill(ctx)

        if pw.type == "shield" then
            -- 六边形冰晶
            nvgBeginPath(ctx)
            for k = 0, 5 do
                local ang = time * 0.8 + k * math.pi / 3
                local px = pw.x + math.cos(ang) * r
                local py = pw.y + math.sin(ang) * r
                if k == 0 then
                    nvgMoveTo(ctx, px, py)
                else
                    nvgLineTo(ctx, px, py)
                end
            end
            nvgClosePath(ctx)
            nvgFillColor(ctx, C(col, 200))
            nvgFill(ctx)
            nvgBeginPath(ctx)
            nvgCircle(ctx, pw.x, pw.y, r * 0.38)
            nvgFillColor(ctx, nvgRGBA(235, 250, 255, 220))
            nvgFill(ctx)
        elseif pw.type == "fire" then
            -- 火环：外环 + 内芯 + 三簇旋转火苗
            nvgBeginPath(ctx)
            nvgCircle(ctx, pw.x, pw.y, r)
            nvgStrokeColor(ctx, C(col))
            nvgStrokeWidth(ctx, 4)
            nvgStroke(ctx)
            nvgBeginPath(ctx)
            nvgCircle(ctx, pw.x, pw.y, r * 0.3)
            nvgFillColor(ctx, nvgRGBA(255, 232, 190, 235))
            nvgFill(ctx)
            for k = 0, 2 do
                local ang = time * 2.4 + k * math.pi * 2 / 3
                local tx = pw.x + math.cos(ang) * r
                local ty = pw.y + math.sin(ang) * r
                nvgBeginPath(ctx)
                nvgCircle(ctx, tx, ty, 3.2)
                nvgFillColor(ctx, nvgRGBA(255, 210, 150, 235))
                nvgFill(ctx)
            end
        else
            -- 风旋：三条弧线绕圈
            for k = 0, 2 do
                local a0 = time * 2 + k * math.pi * 2 / 3
                nvgBeginPath(ctx)
                nvgArc(ctx, pw.x, pw.y, r * (0.5 + 0.25 * k), a0, a0 + 1.6, NVG_CW)
                nvgStrokeColor(ctx, C(col, 220))
                nvgStrokeWidth(ctx, 2.4)
                nvgStroke(ctx)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 收集物：松果
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawPickups(game, time)
    local ctx = self.ctx
    local T = Config.Theme

    for i = 1, #game.world.pickups do
        local pk = game.world.pickups[i]
        local pulse = 0.85 + 0.15 * math.sin(time * 4 + pk.x * 0.05)
        local r = pk.r * pulse

        -- 光晕
        local glow = nvgRadialGradient(ctx, pk.x, pk.y, r * 0.4, r * 2.6,
            C(T.pickupGlow), nvgRGBA(255, 226, 140, 0))
        nvgBeginPath(ctx)
        nvgCircle(ctx, pk.x, pk.y, r * 2.6)
        nvgFillPaint(ctx, glow)
        nvgFill(ctx)

        -- 果身
        local body = nvgRadialGradient(ctx, pk.x - r * 0.3, pk.y - r * 0.3, r * 0.2, r,
            nvgRGBA(255, 232, 158, 255), C(T.pickup))
        nvgBeginPath(ctx)
        nvgCircle(ctx, pk.x, pk.y, r)
        nvgFillPaint(ctx, body)
        nvgFill(ctx)

        -- 松果鳞片（两条弧线示意）
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, pk.x - r * 0.55, pk.y - r * 0.15)
        nvgLineTo(ctx, pk.x, pk.y + r * 0.1)
        nvgLineTo(ctx, pk.x + r * 0.55, pk.y - r * 0.15)
        nvgMoveTo(ctx, pk.x - r * 0.4, pk.y + r * 0.42)
        nvgLineTo(ctx, pk.x, pk.y + r * 0.62)
        nvgLineTo(ctx, pk.x + r * 0.4, pk.y + r * 0.42)
        nvgStrokeColor(ctx, nvgRGBA(186, 128, 44, 210))
        nvgStrokeWidth(ctx, 1.6)
        nvgStroke(ctx)
    end
end

-- ---------------------------------------------------------------------------
-- 玩家：大飞鼠（纯几何拼装 + 挤压拉伸 + 状态光环）
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawTrail(game)
    local ctx = self.ctx
    local T = Config.Theme
    local tl = Config.Player.trailLife

    for i = 1, #game.player.trail do
        local t = game.player.trail[i]
        local k = t.life / tl
        nvgBeginPath(ctx)
        nvgCircle(ctx, t.x, t.y, 1.5 + 4.5 * k)
        nvgFillColor(ctx, C(T.furMembrane, math.floor(80 * k)))
        nvgFill(ctx)
    end
end

---@param game Game
---@param time number
function Renderer:DrawPlayer(game, time)
    local ctx = self.ctx
    local T = Config.Theme
    local p = game.player
    if p.offscreen then return end
    local r = p.radius

    -- 旋转：死亡翻滚 > 速度俯仰 > 静止
    local tilt
    if p.dying then
        tilt = p.deathRot
    elseif game.state == "playing" then
        tilt = p.tilt
    else
        tilt = 0
    end

    -- 无敌期间 12Hz 闪烁（本体隐现，气泡常驻）
    local blinkHide = p.invTimer > 0 and math.floor(p.invTimer * 12) % 2 == 0

    if not blinkHide then
        -- 挤压拉伸：沿身体朝向（已随 tilt 旋转，近似沿速度方向）
        local sx, sy = 1, 1
        if p.alive then
            sx, sy = p:GetStretch()
        end

        nvgSave(ctx)
        nvgTranslate(ctx, p.x, p.y)
        nvgRotate(ctx, tilt * math.pi / 180)
        nvgScale(ctx, sx, sy)

        -- 1) 皮膜（滑翔翼）——先画，压在身体后面
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, -r * 0.2, -r * 0.5)
        nvgLineTo(ctx, -r * 1.9, r * 0.35)
        nvgLineTo(ctx, -r * 0.15, r * 0.75)
        nvgClosePath(ctx)
        nvgFillColor(ctx, C(T.furMembrane, 215))
        nvgFill(ctx)
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, -r * 0.2, -r * 0.5)
        nvgLineTo(ctx, -r * 1.9, r * 0.35)
        nvgLineTo(ctx, -r * 0.15, r * 0.75)
        nvgClosePath(ctx)
        nvgStrokeColor(ctx, C(T.furDark, 200))
        nvgStrokeWidth(ctx, 1.5)
        nvgStroke(ctx)

        -- 2) 尾巴
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, -r * 0.75, -r * 0.1)
        nvgBezierTo(ctx, -r * 1.55, -r * 0.5, -r * 1.7, r * 0.15, -r * 1.15, r * 0.5)
        nvgStrokeColor(ctx, C(T.furDark))
        nvgStrokeWidth(ctx, r * 0.42)
        nvgStroke(ctx)

        -- 3) 身体
        local bodyGrd = nvgRadialGradient(ctx, -r * 0.2, -r * 0.3, r * 0.2, r * 1.25,
            nvgRGBA(214, 180, 138, 255), C(T.furBody))
        nvgBeginPath(ctx)
        nvgEllipse(ctx, 0, 0, r * 1.05, r * 0.86)
        nvgFillPaint(ctx, bodyGrd)
        nvgFill(ctx)

        -- 4) 头部
        nvgBeginPath(ctx)
        nvgCircle(ctx, r * 0.62, -r * 0.42, r * 0.55)
        nvgFillColor(ctx, C(T.furMembrane))
        nvgFill(ctx)

        -- 5) 耳朵
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, r * 0.4, -r * 0.85)
        nvgLineTo(ctx, r * 0.52, -r * 1.35)
        nvgLineTo(ctx, r * 0.82, -r * 0.9)
        nvgClosePath(ctx)
        nvgFillColor(ctx, C(T.furDark))
        nvgFill(ctx)

        -- 6) 眼睛
        nvgBeginPath(ctx)
        nvgCircle(ctx, r * 0.85, -r * 0.5, r * 0.19)
        nvgFillColor(ctx, nvgRGBA(28, 26, 32, 255))
        nvgFill(ctx)
        nvgBeginPath(ctx)
        nvgCircle(ctx, r * 0.9, -r * 0.57, r * 0.06)
        nvgFillColor(ctx, nvgRGBA(255, 255, 255, 230))
        nvgFill(ctx)

        -- 7) 口鼻
        nvgBeginPath(ctx)
        nvgCircle(ctx, r * 1.1, -r * 0.28, r * 0.11)
        nvgFillColor(ctx, nvgRGBA(232, 148, 142, 255))
        nvgFill(ctx)

        nvgRestore(ctx)
    end

    -- 风域托举光圈
    if p.windTimer > 0 then
        local glow = nvgRadialGradient(ctx, p.x, p.y, r * 0.6, r * 2.4,
            C(T.wind, 46), C(T.wind, 0))
        nvgBeginPath(ctx)
        nvgCircle(ctx, p.x, p.y, r * 2.4)
        nvgFillPaint(ctx, glow)
        nvgFill(ctx)
    end

    -- 炫火轮光环：三段旋转弧 + 剩余时间整圈
    if p.fireTimer > 0 then
        local frac = Utils.Clamp(p.fireTimer / Config.Powerup.fireDuration, 0, 1)
        for k = 0, 2 do
            local a0 = time * 3.2 + k * math.pi * 2 / 3
            nvgBeginPath(ctx)
            nvgArc(ctx, p.x, p.y, r * 1.75, a0, a0 + 1.1, NVG_CW)
            nvgStrokeColor(ctx, C(T.fire, 200))
            nvgStrokeWidth(ctx, 2.6)
            nvgStroke(ctx)
        end
        nvgBeginPath(ctx)
        nvgArc(ctx, p.x, p.y, r * 2.05, -math.pi / 2, -math.pi / 2 + frac * math.pi * 2, NVG_CW)
        nvgStrokeColor(ctx, C(T.fire, 90))
        nvgStrokeWidth(ctx, 1.6)
        nvgStroke(ctx)
    end

    -- 寒冰护盾气泡
    if p.shield then
        local br = r * 1.62
        local glow = nvgRadialGradient(ctx, p.x, p.y, br * 0.55, br,
            C(T.shield, 38), C(T.shield, 0))
        nvgBeginPath(ctx)
        nvgCircle(ctx, p.x, p.y, br)
        nvgFillPaint(ctx, glow)
        nvgFill(ctx)
        nvgBeginPath(ctx)
        nvgCircle(ctx, p.x, p.y, br)
        nvgStrokeColor(ctx, C(T.shield, 185))
        nvgStrokeWidth(ctx, 2)
        nvgStroke(ctx)
        -- 高光弧
        nvgBeginPath(ctx)
        nvgArc(ctx, p.x, p.y, br * 0.82, -2.4, -1.4, NVG_CW)
        nvgStrokeColor(ctx, nvgRGBA(255, 255, 255, 120))
        nvgStrokeWidth(ctx, 2)
        nvgStroke(ctx)
    end
end

-- ---------------------------------------------------------------------------
-- HUD
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawHud(game, logicalW, logicalH)
    if game.state == "menu" then return end

    local ctx = self.ctx
    local T = Config.Theme

    nvgFontFace(ctx, self.font)

    -- 左上：得分（吃到东西时弹跳）
    local pop = game.scorePopT or 0
    nvgTextAlign(ctx, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFontSize(ctx, 13)
    nvgFillColor(ctx, C(T.textDim))
    nvgText(ctx, 22, 18, Config.Text.scoreLabel, nil)

    nvgFontSize(ctx, 40 * (1 + 0.18 * pop))
    nvgFillColor(ctx, C(T.text))
    nvgText(ctx, 22, 34, tostring(game.score), nil)

    -- combo 提示（连收 ≥2 时挂在得分下方）
    if game.combo and game.combo > 1 and game.comboTimer > 0 then
        nvgFontSize(ctx, 14)
        nvgFillColor(ctx, C(T.pickup, 220))
        nvgText(ctx, 22, 80, "连收 x" .. game.combo, nil)
    end

    -- 右上：最佳
    nvgTextAlign(ctx, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFontSize(ctx, 13)
    nvgFillColor(ctx, C(T.textDim))
    nvgText(ctx, logicalW - 22, 18, Config.Text.bestLabel, nil)

    nvgFontSize(ctx, 26)
    nvgFillColor(ctx, nvgRGBA(255, 226, 140, 235))
    nvgText(ctx, logicalW - 22, 34, tostring(game.bestScore), nil)

    -- 底部居中：速度条（难度可视化）
    local barW = math.min(180, logicalW * 0.28)
    local barH = 5
    local barX = (logicalW - barW) * 0.5
    local barY = logicalH - 22
    local t = Utils.InverseLerp(game.world.speed,
        Config.World.scrollSpeedStart, Config.World.scrollSpeedMax)

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, barH * 0.5)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 40))
    nvgFill(ctx)

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, math.max(barH, barW * t), barH, barH * 0.5)
    nvgFillColor(ctx, nvgRGBA(255, 178, 92, 200))
    nvgFill(ctx)

    -- 左下：道具状态图标
    self:DrawPowerupHud(game, logicalH)
end

--- 道具状态图标（左下角，带剩余时长弧）
---@param game Game
---@param logicalH number
function Renderer:DrawPowerupHud(game, logicalH)
    if game.state ~= "playing" then return end

    local ctx = self.ctx
    local T = Config.Theme
    local p = game.player
    local x = 26
    local y = logicalH - 30
    local slot = 36

    if p.shield then
        -- 六边形小盾
        nvgBeginPath(ctx)
        for k = 0, 5 do
            local ang = -math.pi / 2 + k * math.pi / 3
            local px = x + math.cos(ang) * 9
            local py = y + math.sin(ang) * 9
            if k == 0 then
                nvgMoveTo(ctx, px, py)
            else
                nvgLineTo(ctx, px, py)
            end
        end
        nvgClosePath(ctx)
        nvgFillColor(ctx, C(T.shield, 220))
        nvgFill(ctx)
        x = x + slot
    end

    if p.fireTimer > 0 then
        -- 火环 + 剩余弧
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, 8)
        nvgStrokeColor(ctx, C(T.fire, 130))
        nvgStrokeWidth(ctx, 3)
        nvgStroke(ctx)
        local frac = Utils.Clamp(p.fireTimer / Config.Powerup.fireDuration, 0, 1)
        nvgBeginPath(ctx)
        nvgArc(ctx, x, y, 8, -math.pi / 2, -math.pi / 2 + frac * math.pi * 2, NVG_CW)
        nvgStrokeColor(ctx, C(T.fire))
        nvgStrokeWidth(ctx, 3)
        nvgStroke(ctx)
        x = x + slot
    end

    if p.windTimer > 0 then
        -- 风旋 + 剩余弧
        for k = 0, 1 do
            local a0 = k * math.pi
            nvgBeginPath(ctx)
            nvgArc(ctx, x, y, 4 + 4 * k, a0, a0 + 2.2, NVG_CW)
            nvgStrokeColor(ctx, C(T.wind, 210))
            nvgStrokeWidth(ctx, 2)
            nvgStroke(ctx)
        end
        local frac = Utils.Clamp(p.windTimer / Config.Powerup.windDuration, 0, 1)
        nvgBeginPath(ctx)
        nvgArc(ctx, x, y, 11, -math.pi / 2, -math.pi / 2 + frac * math.pi * 2, NVG_CW)
        nvgStrokeColor(ctx, C(T.wind, 150))
        nvgStrokeWidth(ctx, 1.6)
        nvgStroke(ctx)
    end
end

-- ---------------------------------------------------------------------------
-- 菜单遮罩
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawMenuOverlay(game, logicalW, logicalH, time)
    if game.state ~= "menu" then return end

    local ctx = self.ctx
    local T = Config.Theme

    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, logicalW, logicalH)
    nvgFillColor(ctx, nvgRGBA(12, 16, 28, 120))
    nvgFill(ctx)

    local cx = logicalW * 0.5
    local cy = logicalH * 0.5

    nvgFontFace(ctx, self.font)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 标题
    nvgFontSize(ctx, 52)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 120))
    nvgText(ctx, cx + 3, cy - 47, Config.Text.title, nil)
    nvgFillColor(ctx, C(T.text))
    nvgText(ctx, cx, cy - 50, Config.Text.title, nil)

    -- 副标题
    nvgFontSize(ctx, 17)
    nvgFillColor(ctx, C(T.textDim))
    nvgText(ctx, cx, cy + 6, Config.Text.subtitle, nil)

    -- 开始提示（呼吸闪烁）
    local blink = 0.55 + 0.45 * math.sin(time * 4)
    nvgFontSize(ctx, 20)
    nvgFillColor(ctx, nvgRGBA(255, 226, 140, 255 * blink))
    nvgText(ctx, cx, cy + 68, Config.Text.startHint, nil)
end

-- ---------------------------------------------------------------------------
-- 结算遮罩（延迟弹出 + 分数滚动）
-- ---------------------------------------------------------------------------

---@param game Game
function Renderer:DrawGameOverOverlay(game, logicalW, logicalH)
    if game.state ~= "gameover" then return end

    local ctx = self.ctx
    local T = Config.Theme
    local F = Config.Fx

    -- 死亡演出期间不弹面板
    local t = Utils.Clamp((game.overTime - F.deathPanelDelay) / 0.32, 0, 1)
    if t <= 0 then return end
    local ease = Utils.EaseOutBack(t)

    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, logicalW, logicalH)
    nvgFillColor(ctx, nvgRGBA(10, 14, 24, 150 * t))
    nvgFill(ctx)

    local panelW = math.min(360, logicalW * 0.62)
    local panelH = 200
    local cx = logicalW * 0.5
    local cy = logicalH * 0.5
    local px = cx - panelW * 0.5
    local py = cy - panelH * 0.5 + (1 - ease) * 40

    -- 阴影
    local shadow = nvgBoxGradient(ctx, px, py + 6, panelW, panelH, 16, 18,
        nvgRGBA(0, 0, 0, 140), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, px - 6, py - 6, panelW + 12, panelH + 18, 20)
    nvgFillPaint(ctx, shadow)
    nvgFill(ctx)

    -- 面板
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, px, py, panelW, panelH, 16)
    nvgFillColor(ctx, nvgRGBA(28, 36, 54, 244))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, px, py, panelW, panelH, 16)
    nvgStrokeColor(ctx, nvgRGBA(255, 178, 92, 130))
    nvgStrokeWidth(ctx, 2)
    nvgStroke(ctx)

    nvgFontFace(ctx, self.font)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 标题
    nvgFontSize(ctx, 28)
    nvgFillColor(ctx, C(T.danger))
    nvgText(ctx, cx, py + 40, Config.Text.overTitle, nil)

    -- 得分（滚动上涨）
    local reveal = Utils.Clamp((game.overTime - F.deathPanelDelay) / 0.6, 0, 1)
    local shown = math.floor(game.score * Utils.EaseOutCubic(reveal))
    nvgFontSize(ctx, 46)
    nvgFillColor(ctx, C(T.text))
    nvgText(ctx, cx, py + 92, tostring(shown), nil)

    -- 明细
    nvgFontSize(ctx, 14)
    nvgFillColor(ctx, C(T.textDim))
    nvgText(ctx, cx, py + 128, string.format("距离 %d  ·  松果 %d  ·  额外 %d  ·  用时 %.1fs",
        game.distanceScore, game.pickupScore, game.bonusScore, game.runTime), nil)

    -- 最佳
    nvgFontSize(ctx, 15)
    nvgFillColor(ctx, nvgRGBA(255, 226, 140, 235))
    nvgText(ctx, cx, py + 152, Config.Text.bestLabel .. " " .. game.bestScore, nil)

    -- 重开提示
    if game.overTime >= F.restartGate then
        local blink = 0.6 + 0.4 * math.sin(game.overTime * 5)
        nvgFontSize(ctx, 16)
        nvgFillColor(ctx, nvgRGBA(210, 222, 240, 255 * blink))
        nvgText(ctx, cx, py + 180, Config.Text.overHint, nil)
    end
end

return Renderer
