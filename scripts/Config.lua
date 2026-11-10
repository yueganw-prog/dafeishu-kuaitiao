-- ============================================================================
-- Config.lua - 全局可调参数
-- 数值调优只改这里，不用碰逻辑代码
-- 单位：长度=逻辑像素（模式 B，1 逻辑像素 ≈ 1 CSS 像素），时间=秒
-- 速度：正=向下 / 向右，负=向上 / 向左
-- ============================================================================

local Config = {}

-- ---------------------------------------------------------------------------
-- 世界 / 滚动
-- ---------------------------------------------------------------------------
Config.World = {
    groundHeightRatio = 0.12,   -- 地面占屏幕高度比例
    scrollSpeedStart  = 200,    -- 初始滚动速度
    scrollSpeedMax    = 520,    -- 速度上限
    difficultyTime    = 75,     -- 难度从 0 到 1 的时长（smoothstep 曲线）
    breatherEvery     = 4,      -- 每生成多少组障碍安排一次"呼吸段"（空隙放宽）
    breatherGapBonus  = 1.18,   -- 呼吸段空隙放大倍率
    maxStepFactor     = 0.75,   -- 相邻空隙中心垂直位移的可达系数（×爬升/坠落速度×间隔）
}

-- ---------------------------------------------------------------------------
-- 玩家（大飞鼠）：混合操控 = 点按扇翅冲量 + 按住滑翔推力曲线
-- ---------------------------------------------------------------------------
Config.Player = {
    xRatio            = 0.26,   -- 水平固定位置（占屏宽比例）
    radius            = 17,     -- 碰撞半径
    gravity           = 1150,   -- 自然下落加速度
    holdAccel         = -2350,  -- 按住滑翔的全推力
    thrustRampTime    = 0.12,   -- 按住后推力从重力"咬合"到全推力的时间
    thrustReleaseTime = 0.06,   -- 松手后推力泄回重力的时间
    flapImpulse       = 430,    -- 点按扇翅冲量（瞬时抵消的下落速度）
    maxFallSpeed      = 720,    -- 最大下落速度
    maxRiseSpeed      = -380,   -- 最大上升速度
    tiltMaxDeg        = 30,     -- 最大俯仰角（纯视觉）
    tiltLerp          = 9,      -- 角度跟随速度
    ceilingRestitution = 0.25,  -- 顶到天花板的反弹系数（弹簧感，不死）
    squashPulseTime   = 0.18,   -- 扇翅压扁脉冲时长
    stretchAmp        = 0.16,   -- 高速下沿速度方向的拉伸幅度
    squashAmp         = 0.10,   -- 高速下垂直方向的压扁幅度
    trailInterval     = 0.035,  -- 残影采样间隔
    trailLife         = 0.30,   -- 残影存活时长
    imagePath         = "player.png", -- 玩家贴图（放 assets/ 下，透明底、面朝右）；缺失时回退内置矢量飞鼠
    imageSize         = 56,     -- 贴图显示宽度（逻辑像素，高度按图片比例自适应）
}

-- ---------------------------------------------------------------------------
-- 障碍（上下对开的树枝）
-- ---------------------------------------------------------------------------
Config.Obstacle = {
    width            = 62,
    gapMin           = 168,   -- 可通过空隙最小值（会随难度收紧）
    gapMax           = 210,
    gapShrink        = 26,    -- 难度提升后空隙最多收紧多少
    spawnIntervalMin = 0.92,
    spawnIntervalMax = 1.55,
    marginTop        = 40,    -- 空隙不能贴顶/贴地
    demonPath        = "obstacle_demon.png", -- 桩头恶魔贴图（放 assets/ 下）；缺失时保持纯树枝
    demonWidth       = 86,    -- 恶魔半身像显示宽度（逻辑像素，头贴住空隙侧的桩头）
}

-- ---------------------------------------------------------------------------
-- 收集物（松果）
-- ---------------------------------------------------------------------------
Config.Pickup = {
    radius           = 11,
    spawnIntervalMin = 0.55,
    spawnIntervalMax = 1.15,
    margin           = 30,    -- 距离可玩区域边界的最小距离
}

-- ---------------------------------------------------------------------------
-- 道具（参考"变身派蒙的飞行挑战"三件套）
-- ---------------------------------------------------------------------------
Config.Powerup = {
    radius               = 14,
    spawnIntervalMin     = 9,    -- 道具生成间隔（秒）
    spawnIntervalMax     = 14,
    margin               = 60,   -- 距离可玩区域边界的最小距离
    shieldInvincibleTime = 1.2,  -- 护盾抵挡后的无敌时长
    fireDuration         = 6,    -- 炫火轮光环持续时长
    fireScore            = 50,   -- 撞毁一组树枝的得分
    windDuration         = 3,    -- 风域托举持续时长
    windLiftSpeed        = -280, -- 风域托举的目标上升速度
    windDampSpeed        = 6,    -- 托举的趋近速度（越大越"拽"）
}

-- ---------------------------------------------------------------------------
-- 得分
-- ---------------------------------------------------------------------------
Config.Score = {
    distancePerPoint = 100,   -- 每滚动多少逻辑像素得 1 分
    pickupValue      = 10,    -- 单个松果得分
    nearMissDist     = 28,    -- 距离树枝边缘小于该值通过 = 擦身
    nearMissValue    = 5,     -- 擦身奖励分
    comboWindow      = 2.5,   -- 连续收集的判定窗口（秒）
    comboPitchStep   = 0.06,  -- 每级 combo 的音调步进
    comboMaxStep     = 5,     -- 音调封顶级数
}

-- ---------------------------------------------------------------------------
-- 果汁特效（粒子 / 屏震 / 白闪 / hit-stop）
-- ---------------------------------------------------------------------------
Config.Fx = {
    maxParticles    = 260,    -- 粒子池上限（超出回收最老的）
    shakeDecay      = 2.2,    -- 屏震强度衰减速度
    shakeAmp        = 11,     -- 屏震满级位移（逻辑像素）
    shakeRotMax     = 0.9,    -- 屏震附带旋转上限（度）
    zoomDecay       = 5.5,    -- 缩放脉冲回落速度
    zoomPulsePickup = 0.012,  -- 吃松果的镜头微胀
    zoomPulsePowerup = 0.03,  -- 吃道具的镜头胀
    flashDecay      = 3.2,    -- 白闪衰减速度
    hitStopTime     = 0.09,   -- 撞树瞬间的冻结时长
    slowMoScale     = 0.35,   -- 坠落慢动作时间倍率
    slowMoTime      = 0.55,   -- 慢动作持续时长
    crashShake      = 1.2,    -- 撞树屏震强度
    crashFlash      = 0.85,   -- 撞树白闪强度
    shieldShake     = 0.55,   -- 护盾抵挡屏震强度
    powerupFlash    = 0.30,   -- 吃道具闪光强度
    deathPanelDelay = 0.45,   -- 死亡到结算面板弹出的延迟
    restartGate     = 0.85,   -- 结算后多少秒才接受"再来一局"点击
    speedLineStart  = 0.55,   -- 速度比例超过该值出现风线（0..1）
}

-- ---------------------------------------------------------------------------
-- 音效（文件契约：把同名 WAV 放进 assets/Sounds/ 即自动生效；缺文件静默跳过）
-- 注意：sounds 表里只保留 assets/Sounds/ 下实际存在的文件——
-- 列了不存在的文件会让引擎 GetResource 在启动时打 ERROR（进平台错误报告）。
-- 补素材后把对应行加回来即可：flap/shield/nearmiss/fire 目前素材未到位。
-- ---------------------------------------------------------------------------
Config.Audio = {
    enabled = true,
    sounds = {
        pickup   = { path = "Sounds/pickup.wav",   gain = 0.55, pitchVar = 0.0  },
        powerup  = { path = "Sounds/powerup.wav",  gain = 0.60, pitchVar = 0.0  },
        crash    = { path = "Sounds/crash.wav",    gain = 0.75, pitchVar = 0.0  },
        -- flap     = { path = "Sounds/flap.wav",     gain = 0.50, pitchVar = 0.05 },
        -- shield   = { path = "Sounds/shield.wav",   gain = 0.60, pitchVar = 0.0  },
        -- nearmiss = { path = "Sounds/nearmiss.wav", gain = 0.45, pitchVar = 0.04 },
        -- fire     = { path = "Sounds/fire.wav",     gain = 0.60, pitchVar = 0.0  },
    },
}

-- ---------------------------------------------------------------------------
-- 结算页面
-- ---------------------------------------------------------------------------
Config.GameOver = {
    facePath       = "gameover_face.png", -- 结算头像贴图（放 assets/ 下）；缺失时隐藏头像、面板收紧
    faceSize       = 68,                  -- 结算头像直径（逻辑像素，圆形裁切）
    panelHWithFace = 252,                 -- 有头像时面板高度
    panelHPlain    = 200,                 -- 无头像时面板高度
    tier2Min       = 100,                 -- 分数档位：<100 第一档，100~300 第二档，>300 第三档
    tier2Max       = 300,
    slogan1        = "我会将你打回现实",
    slogan2        = "百万雄师随我出征",
    slogan3        = "春风若有怜花意",
}

-- ---------------------------------------------------------------------------
-- 难度档位（菜单可选：简单 / 困难 / 地狱）
-- 每档在开局选择时覆盖进生效配置（Config.World/Obstacle/Player/Powerup 的对应键）
-- maxStepFactor：相邻空隙中心垂直位移 = 爬升|下坠速度 × 障碍间隔 × 该系数
-- ---------------------------------------------------------------------------
Config.Difficulty = {
    easy = {
        label    = "简单",
        world    = { scrollSpeedStart = 170, scrollSpeedMax = 420, difficultyTime = 90,
                     breatherEvery = 3, breatherGapBonus = 1.25, maxStepFactor = 0.6 },
        obstacle = { gapMin = 190, gapMax = 235, gapShrink = 18,
                     spawnIntervalMin = 1.05, spawnIntervalMax = 1.7 },
        player   = { flapImpulse = 530, holdAccel = -2850, maxRiseSpeed = -430 },
        powerup  = { spawnIntervalMin = 7, spawnIntervalMax = 11 },
    },
    hard = {
        label    = "困难",
        world    = { scrollSpeedStart = 200, scrollSpeedMax = 520, difficultyTime = 75,
                     breatherEvery = 4, breatherGapBonus = 1.18, maxStepFactor = 0.75 },
        obstacle = { gapMin = 168, gapMax = 210, gapShrink = 26,
                     spawnIntervalMin = 0.92, spawnIntervalMax = 1.55 },
        player   = { flapImpulse = 430, holdAccel = -2350, maxRiseSpeed = -380 },
        powerup  = { spawnIntervalMin = 9, spawnIntervalMax = 14 },
    },
    hell = {
        label    = "地狱",
        world    = { scrollSpeedStart = 260, scrollSpeedMax = 700, difficultyTime = 45,
                     breatherEvery = 6, breatherGapBonus = 1.08, maxStepFactor = 1.15 },
        obstacle = { gapMin = 148, gapMax = 185, gapShrink = 34,
                     spawnIntervalMin = 0.75, spawnIntervalMax = 1.3 },
        player   = { flapImpulse = 400, holdAccel = -2200, maxRiseSpeed = -360 },
        powerup  = { spawnIntervalMin = 12, spawnIntervalMax = 18 },
    },
}

-- ---------------------------------------------------------------------------
-- 皮肤（形象库：加新形象 = 加一个条目 + 把图放进 assets/）
-- image 指向 assets/ 下的 PNG；tint 为可选乘法叠色（省略=按原图显示）
-- unlockScore = 解锁所需历史最佳分数
-- ---------------------------------------------------------------------------
Config.Skins = {
    { id = "classic", name = "原色", image = "player.png",        unlockScore = 0 },
    { id = "sunset",  name = "绯红", image = "skins/sunset.png",  unlockScore = 0 },
    { id = "jade",    name = "翡翠", image = "skins/jade.png",    unlockScore = 100 },
    { id = "gold",    name = "鎏金", image = "skins/gold.png",    unlockScore = 300 },
    { id = "violet",  name = "幻紫", image = "skins/violet.png",  unlockScore = 1000 },
}

-- ---------------------------------------------------------------------------
-- 配色（深色森林风）
-- ---------------------------------------------------------------------------
Config.Theme = {
    skyTop      = { 24, 32, 58, 255 },
    skyBottom   = { 62, 96, 132, 255 },
    hillFar     = { 38, 58, 84, 255 },
    hillNear    = { 30, 46, 68, 255 },
    groundTop   = { 46, 68, 52, 255 },
    groundBody  = { 30, 44, 34, 255 },
    obstacle    = { 74, 52, 38, 255 },
    obstacleTop = { 96, 70, 48, 255 },
    furBody     = { 148, 148, 154, 255 },
    furMembrane = { 202, 202, 208, 255 },
    furDark     = { 94, 94, 100, 255 },
    pickup      = { 250, 198, 82, 255 },
    pickupGlow  = { 255, 226, 140, 120 },
    shield      = { 150, 225, 255, 255 },
    fire        = { 255, 150, 80, 255 },
    wind        = { 170, 240, 205, 255 },
    text        = { 255, 255, 255, 255 },
    textDim     = { 210, 222, 240, 190 },
    danger      = { 255, 118, 108, 255 },
}

-- ---------------------------------------------------------------------------
-- 交互 / 提示文案
-- ---------------------------------------------------------------------------
Config.Text = {
    title          = "大飞鼠快跑",
    subtitle       = "点按扇翅 · 按住滑翔 — 收集松果与道具，躲开树枝",
    startHint      = "点击任意位置开始",
    overHint       = "点击空白区域再来一局",
    scoreLabel     = "得分",
    bestLabel      = "最佳",
    powerupShield  = "寒冰护盾",
    powerupFire    = "炫火轮",
    powerupWind    = "风域",
    nearMissText   = "擦身",
    shieldBlockText = "护盾抵挡！",
}

return Config
