-- ============================================================================
-- main.lua - 项目入口（大飞鼠快跑 / Flying Squirrel Run）
--
-- 职责边界（保持这个文件"薄"）：
--   这里只做 引擎对接 + 事件分发 + 分辨率模式管理，
--   玩法逻辑在 Game.lua，世界在 World.lua，绘制在 Renderer.lua，参数在 Config.lua
--
-- 渲染方案：整条管线 raw NanoVG（无 urhox-libs/UI，无 Scene/Viewport）
-- 分辨率模式：B - 系统逻辑分辨率 + DPR 修正
--   物理分辨率 = graphics:GetWidth()/GetHeight()
--   逻辑分辨率 = 物理 / DPR
--   nvgBeginFrame(ctx, logicalW, logicalH, dpr)
--
-- 输入：触屏 / 鼠标 / 空格，统一收敛为 Game:PressDown / PressUp
-- 方向：竖屏（portrait），项目声明见 .project/project.json
-- ============================================================================

local Config = require("Config")
local Game = require("Game")
local Renderer = require("Renderer")
local Audio = require("Audio")

local FONT_PATH = "Fonts/MiSans-Regular.ttf"

-- ---------------------------------------------------------------------------
-- 模块级状态（必须模块级持有，避免被 GC 回收）
-- ---------------------------------------------------------------------------
---@type NVGContextWrapper
local vg_ = nil
---@type Game
local game_ = nil
---@type Renderer
local renderer_ = nil

local physW_, physH_, dpr_ = 0, 0, 1
local logicalW_, logicalH_ = 0, 0
local time_ = 0

-- ---------------------------------------------------------------------------
-- 分辨率
-- ---------------------------------------------------------------------------

--- 重新读取屏幕尺寸（模式 B：逻辑分辨率 = 物理 / DPR）
function RefreshMetrics()
    physW_ = graphics:GetWidth()
    physH_ = graphics:GetHeight()
    dpr_ = graphics:GetDPR()
    if dpr_ == nil or dpr_ <= 0 then dpr_ = 1 end
    logicalW_ = physW_ / dpr_
    logicalH_ = physH_ / dpr_
end

-- ---------------------------------------------------------------------------
-- 生命周期
-- ---------------------------------------------------------------------------

function Start()
    graphics.windowTitle = Config.Text.title

    -- 1) 分辨率
    RefreshMetrics()
    print(string.format("[main] phys=%dx%d dpr=%.2f logical=%.1fx%.1f",
        physW_, physH_, dpr_, logicalW_, logicalH_))

    -- 2) 创建 NanoVG 上下文 + 字体（字体只创建一次，句柄全程复用）
    vg_ = nvgCreate(1)
    if vg_ == nil then
        print("[main] ERROR: nvgCreate failed")
        return
    end
    if nvgCreateFont(vg_, "sans", FONT_PATH) == -1 then
        print("[main] ERROR: font not found: " .. FONT_PATH)
        print("[main] 提示：NanoVG 文本依赖此字体，缺字体时文字不显示")
    end

    -- 3) 游戏与渲染器
    game_ = Game.New()
    game_:OnLayout(logicalW_, logicalH_)
    renderer_ = Renderer.New(vg_)

    -- 3.5) 音效（缺素材文件时静默降级，永不阻塞游戏）
    Audio.Init()

    -- 4) 输入设备：隐藏系统光标（游戏内所有交互都是"点击任意位置"）
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = false

    -- 5) 事件
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent(vg_, "NanoVGRender", "HandleRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode")

    -- 输入：桌面
    SubscribeToEvent("MouseButtonDown", "HandleMouseButtonDown")
    SubscribeToEvent("MouseButtonUp", "HandleMouseButtonUp")
    -- 输入：移动端
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("TouchEnd", "HandleTouchEnd")
    -- 输入：键盘（调试用）
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("KeyUp", "HandleKeyUp")

    -- 6) 请求竖屏（仅 Android / iOS 生效；桌面、WASM 走 onError，不影响游戏运行）
    --    真正的方向锁定还需在项目配置里同步，见项目说明
    common.setDeviceOrientation({
        value = "portrait",
        onSuccess = function()
            print("[main] orientation -> portrait accepted")
        end,
        onError = function(err)
            local msg = "unknown"
            if err ~= nil and err.errMsg ~= nil then msg = err.errMsg end
            print("[main] orientation request ignored: " .. tostring(msg))
        end,
    })

    print("=== 大飞鼠快跑 已启动 ===")
    print("[main] 点击/按住屏幕起飞滑翔；空格键等效")
end

function Stop()
    Audio.Shutdown()
    if vg_ ~= nil then
        nvgDelete(vg_)
        vg_ = nil
    end
    game_ = nil
    renderer_ = nil
    print("[main] stopped")
end

-- ---------------------------------------------------------------------------
-- 主循环
-- ---------------------------------------------------------------------------

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 夹住异常大的时间步（切后台回来会出现几秒的 dt，会把物理打飞）
    if dt > 0.1 then dt = 0.1 end
    time_ = time_ + dt

    if game_ == nil then return end
    game_:Update(dt)
end

---@param eventType string
---@param eventData table
function HandleRender(eventType, eventData)
    if vg_ == nil or game_ == nil or renderer_ == nil then return end
    renderer_:Draw(game_, logicalW_, logicalH_, dpr_, time_)
end

---@param eventType string
---@param eventData table
function HandleScreenMode(eventType, eventData)
    local oldW = logicalW_
    RefreshMetrics()
    print(string.format("[main] screen mode changed: %.1fx%.1f -> %.1fx%.1f",
        oldW, logicalH_, logicalW_, logicalH_))
    if game_ then
        game_:OnLayout(logicalW_, logicalH_)
    end
end

-- ---------------------------------------------------------------------------
-- 输入
-- ---------------------------------------------------------------------------

--- 事件坐标 → 逻辑坐标（模式 B：逻辑 = 物理 / DPR）
local function ToLogical(x, y)
    if dpr_ == nil or dpr_ <= 0 then dpr_ = 1 end
    return x / dpr_, y / dpr_
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleMouseButtonDown(eventType, eventData)
    if eventData["Button"]:GetInt() ~= MOUSEB_LEFT then return end
    if game_ then
        local lx, ly = ToLogical(eventData["X"]:GetInt(), eventData["Y"]:GetInt())
        game_:PressDown(lx, ly)
    end
end

---@param eventType string
---@param eventData MouseButtonUpEventData
function HandleMouseButtonUp(eventType, eventData)
    if eventData["Button"]:GetInt() ~= MOUSEB_LEFT then return end
    if game_ then game_:PressUp() end
end

---@param eventType string
---@param eventData TouchBeginEventData
function HandleTouchBegin(eventType, eventData)
    if game_ then
        local lx, ly = ToLogical(eventData["X"]:GetInt(), eventData["Y"]:GetInt())
        game_:PressDown(lx, ly)
    end
end

---@param eventType string
---@param eventData TouchEndEventData
function HandleTouchEnd(eventType, eventData)
    if game_ then game_:PressUp() end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()
    if key == KEY_SPACE then
        if game_ then game_:PressDown() end
    elseif key == KEY_ESCAPE then
        -- 桌面端退出（移动端无此键）
        engine:Exit()
    end
end

---@param eventType string
---@param eventData KeyUpEventData
function HandleKeyUp(eventType, eventData)
    local key = eventData["Key"]:GetInt()
    if key == KEY_SPACE then
        if game_ then game_:PressUp() end
    end
end
