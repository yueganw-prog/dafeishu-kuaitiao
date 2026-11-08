-- ============================================================================
-- Audio.lua - 音效系统（隐藏场景 + SoundSource 轮询池）
--
-- 本项目渲染层没有 Scene，但 SoundSource 是场景组件，所以这里私建一个
-- "只挂声音"的隐藏场景。场景必须被模块级引用持有，否则几秒后随机崩溃
-- （见 engine-docs/gotchas：Scene GC 陷阱）。
--
-- 文件契约（Config.Audio.sounds）：把同名 WAV 放进 assets/Sounds/ 即生效；
-- 缺文件时启动时打印一条提示，Play 静默跳过，游戏完全不受影响。
-- 引擎坑：SoundSource:Play(freq) 的 freq 是"绝对 Hz"，变调必须传
-- sound:GetFrequency() * pitch，不能直接传 0.95。
-- ============================================================================

local Config = require("Config")

-- 注意：本模块是纯静态工具模块（像 Utils），不要标 @class——
-- 类注解会让 LSP 把 Audio.Play(...) 的首参当成 self 检查。
local Audio = {}

---@type Scene|nil
local scene_ = nil      -- 模块级持有，防 GC
---@type SoundSource[]
local pool_ = {}        -- SoundSource 池（3 个轮询，允许少量叠音）
local poolIdx_ = 1
---@type table<string, Sound>
local sounds_ = {}      -- name -> Sound 资源
local ready_ = false

--- 对称随机抖动：[-v, v]
---@param v number
---@return number
local function RandSym(v)
    if v <= 0 then return 0 end
    return (math.random() * 2 - 1) * v
end

--- 初始化：永远不抛错，音频失败 = 静音游戏
function Audio.Init()
    if not Config.Audio.enabled then return end

    -- 第一步：建隐藏场景 + 声源池
    local ok, err = pcall(function()
        scene_ = Scene()
        local root = scene_:CreateChild("AudioRoot")
        for i = 1, 3 do
            pool_[i] = root:CreateChild("Src" .. i):CreateComponent("SoundSource")
        end
        ready_ = true
    end)
    if not ok then
        print("[Audio] init failed, sound disabled: " .. tostring(err))
        ready_ = false
        return
    end

    -- 第二步：逐个加载契约音效，单个缺文件不影响其余
    for name, def in pairs(Config.Audio.sounds) do
        local okS, s = pcall(function()
            return cache:GetResource("Sound", def.path)
        end)
        if okS and s ~= nil then
            sounds_[name] = s
        else
            print("[Audio] missing sound file: " .. def.path .. " (key: " .. name .. ")")
        end
    end
end

--- 播放一个音效
---@param name string Config.Audio.sounds 的键
---@param opts table|nil { pitch = number, pitchVar = number, gain = number }
function Audio.Play(name, opts)
    if not ready_ then return end
    local s = sounds_[name]
    if s == nil then return end

    local def = Config.Audio.sounds[name]
    opts = opts or {}
    local pitchVar = opts.pitchVar or def.pitchVar or 0
    local pitch = (opts.pitch or 1) * (1 + RandSym(pitchVar))
    local gain = opts.gain or def.gain or 0.6

    local src = pool_[poolIdx_]
    poolIdx_ = poolIdx_ % #pool_ + 1
    pcall(function()
        src:Play(s, s:GetFrequency() * pitch, gain)
    end)
end

--- 全部停掉（重开局时调用，防止坠毁音跨局回响）
function Audio.StopAll()
    if not ready_ then return end
    pcall(function()
        for _, src in ipairs(pool_) do
            src:Stop()
        end
    end)
end

function Audio.Shutdown()
    ready_ = false
    pool_ = {}
    sounds_ = {}
    scene_ = nil
end

return Audio
