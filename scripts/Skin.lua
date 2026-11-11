-- ============================================================================
-- Skin.lua - 皮肤系统（选择 / 解锁 / 持久化 / 贴图句柄缓存）
--
-- 皮肤条目见 Config.Skins（加新形象 = 加一个条目 + 图放 assets/）。
--
-- 存档分两层：
--   1) 本地：引擎沙箱 player_save.json（项目+用户隔离，见 file-storage.md；
--      原生平台持久，WASM 刷新丢失，测试版本更新后不保证保留）
--   2) 云端：clientCloud 键值（按 TapTap 账号隔离，跨设备跨版本）——
--      best_score 走 SetInt（顺带具备排行榜能力），skin_data 走 Set
-- 合并策略：最佳分取双方最大值；皮肤选择取云端（须在合并后最佳分下已解锁）。
-- 全部读写走 pcall + 错误回调：云端不可用（未登录/预览环境）时静默降级为纯本地。
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

local cloudReady = false        -- 云端数据已拉取（成功或确认失败，避免无谓重试）
local cloudBestSeen = 0         -- 云端已确认的最佳分（推送去重用）

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

--- 写本地存档
local function WriteSave()
    pcall(function()
        local f = File(SAVE_FILE, FILE_WRITE)
        if f == nil then return end
        f:WriteString(cjson.encode({ skin = selectedId, best = math.floor(bestScore) }))
        f:Close()
    end)
end

--- 读本地存档；缺失/损坏返回 nil
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

-- ---------------------------------------------------------------------------
-- 云端同步（clientCloud；未登录/预览环境自动降级为纯本地）
-- ---------------------------------------------------------------------------

--- 拉取云端存档并合并（最佳分取大；皮肤按云端选择、须已解锁）
local function CloudPull()
    if clientCloud == nil then return end
    pcall(function()
        clientCloud:BatchGet()
            :Key("best_score")
            :Key("skin_data")
            :Fetch({
                ok = function(values, iscores)
                    cloudReady = true

                    -- 1) 最佳分合并（取双方最大值）
                    local cloudBest = (iscores and iscores.best_score) or 0
                    cloudBestSeen = cloudBest
                    if cloudBest > bestScore then
                        bestScore = math.floor(cloudBest)
                        WriteSave()
                    end

                    -- 2) 皮肤选择合并（云端的选择须在合并后最佳分下已解锁）
                    local d = values and values.skin_data
                    if type(d) == "table" and type(d.skin) == "string" then
                        Skin.Select(d.skin)
                    end

                    -- 3) 自定义配色恢复（预留）
                    if type(d) == "table" and type(d.custom) == "table" and type(d.custom.r) == "number" then
                        Skin.SetCustom({ r = d.custom.r, g = d.custom.g, b = d.custom.b })
                    end

                    print(string.format("[Skin] cloud merged: best=%d skin=%s", bestScore, selectedId))
                    if Skin.OnCloudMerge then Skin.OnCloudMerge() end
                end,
                error = function(code, reason)
                    cloudReady = true
                    print("[Skin] cloud pull failed:", tostring(code), tostring(reason))
                end,
            })
    end)
end

--- 推送最佳分到云端（只在超过云端已知值时推送）
local function CloudPushBest(n)
    if not cloudReady or clientCloud == nil then return end
    if n <= cloudBestSeen then return end
    pcall(function()
        clientCloud:SetInt("best_score", n, {
            ok = function() cloudBestSeen = n end,
            error = function(code, reason)
                print("[Skin] cloud push best failed:", tostring(code), tostring(reason))
            end,
        })
    end)
end

--- 推送皮肤选择到云端
local function CloudPushSkin()
    if not cloudReady or clientCloud == nil then return end
    pcall(function()
        clientCloud:Set("skin_data", { skin = selectedId }, {
            ok = function() end,
            error = function(code, reason)
                print("[Skin] cloud push skin failed:", tostring(code), tostring(reason))
            end,
        })
    end)
end

--- 启动时加载：本地立即生效，云端异步合并（只执行一次）
function Skin.Load()
    if loaded then return end
    loaded = true

    local t = ReadSave()
    if t then
        if type(t.best) == "number" and t.best > 0 then
            bestScore = math.floor(t.best)
            cloudBestSeen = bestScore   -- 本地分先顶上，云端合并取大
        end
        if type(t.skin) == "string" and Skin.ById(t.skin) then
            selectedId = t.skin
        end
    end
    print(string.format("[Skin] local loaded: best=%d skin=%s", bestScore, selectedId))

    CloudPull()
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

--- 选择皮肤（未解锁/不存在则忽略），并立即写档 + 推云端
---@param id string
function Skin.Select(id)
    local entry = Skin.ById(id)
    if entry == nil then return end
    if not Skin.IsUnlocked(entry) then return end
    if selectedId == id then return end
    selectedId = id
    WriteSave()
    CloudPushSkin()
end

--- 历史最佳分数
---@return number
function Skin.GetBest()
    return bestScore
end

--- 更新历史最佳分数（只在提高时写本地 + 推云端）
---@param n number
function Skin.SaveBest(n)
    n = math.floor(n or 0)
    if n <= bestScore then return end
    bestScore = n
    WriteSave()
    CloudPushBest(n)
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
