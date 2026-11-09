-- ============================================================================
-- Skin.lua - 皮肤系统（选择 / 解锁 / 持久化 / 贴图句柄缓存）
--
-- 皮肤条目见 Config.Skins（加新形象 = 加一个条目 + 图放 assets/）。
-- 存档为引擎沙箱内的 player_save.json（项目 + 用户双重隔离，见
-- engine-docs/recipes/file-storage.md：原生平台持久；WASM 刷新丢失）。
-- 全部读写走 pcall：存档失败只影响"记住选择"，游戏行为不受影响。
-- ============================================================================

local Config = require("Config")

---@class Skin
local Skin = {}

local SAVE_FILE = "player_save.json"
local DEFAULT_SKIN = "classic"

local selectedId = DEFAULT_SKIN
local bestScore = 0
local handles = {}              -- image 路径 -> nvg 句柄（false = 已确认加载失败）
local loaded = false

--- 按 id 找皮肤条目
---@param id string
---@return table|nil
function Skin.ById(id)
    for _, s in ipairs(Config.Skins) do
        if s.id == id then return s end
    end
    return nil
end

--- 是否解锁（历史最佳分数达到条目门槛）
---@param entry table
---@return boolean
function Skin.IsUnlocked(entry)
    return bestScore >= (entry.unlockScore or 0)
end

--- 写存档
local function WriteSave()
    pcall(function()
        local f = File(SAVE_FILE, FILE_WRITE)
        if f == nil then return end
        f:WriteString(cjson.encode({ skin = selectedId, best = math.floor(bestScore) }))
        f:Close()
    end)
end

--- 读存档；缺失/损坏返回 nil
---@return table|nil
local function ReadSave()
    local out = nil
    pcall(function()
        if fileSystem == nil or not fileSystem:FileExists(SAVE_FILE) then return end
        local f = File(SAVE_FILE, FILE_READ)
        if f == nil then return end
        local s = f:ReadString()
        f:Close()
        if s == nil or s == "" then return end
        local t = cjson.decode(s)
        if type(t) == "table" then out = t end
    end)
    return out
end

--- 启动时加载存档（只执行一次）
function Skin.Load()
    if loaded then return end
    loaded = true

    local t = ReadSave()
    if t then
        if type(t.best) == "number" and t.best > 0 then
            bestScore = math.floor(t.best)
        end
        if type(t.skin) == "string" and Skin.ById(t.skin) then
            selectedId = t.skin
        end
    end
end

--- 当前选中皮肤条目（异常时逐级回退，恒非空）
---@return table
function Skin.GetSelected()
    local entry = Skin.ById(selectedId)
    if entry ~= nil then
        return entry
    end
    local fallback = Skin.ById(DEFAULT_SKIN)
    if fallback ~= nil then
        return fallback
    end
    return Config.Skins[1]
end

--- 选择皮肤（未解锁/不存在则忽略），并立即写档
---@param id string
function Skin.Select(id)
    local entry = Skin.ById(id)
    if entry == nil then return end
    if not Skin.IsUnlocked(entry) then return end
    if selectedId == id then return end
    selectedId = id
    WriteSave()
end

--- 历史最佳分数（可能来自存档）
---@return number
function Skin.GetBest()
    return bestScore
end

--- 更新历史最佳分数（只在提高时写档）
---@param n number
function Skin.SaveBest(n)
    n = math.floor(n or 0)
    if n <= bestScore then return end
    bestScore = n
    WriteSave()
end

--- 取皮肤贴图的 nvg 句柄（按路径懒加载；加载失败标记 false 不再重试）
---@param entry table
---@param ctx NVGContextWrapper
---@return integer|nil
function Skin.GetHandle(entry, ctx)
    local path = entry.image
    if path == nil or path == "" then return nil end

    local cached = handles[path]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local ok, img = pcall(function()
        return nvgCreateImage(ctx, path, 0)
    end)
    if ok and img ~= nil and img ~= 0 then
        handles[path] = img
        return img
    end
    handles[path] = false
    print("[Skin] image missing/unloadable: " .. tostring(path))
    return nil
end

return Skin
