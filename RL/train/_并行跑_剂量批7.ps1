# _并行跑_剂量批7.ps1 —— 【2026-09-25 夜】把 7 个"该量没量"的键一次性挂上（用户睡觉前点名）。
#
# 用户原话：「1. T40 ⑬b POSSESS_BATTERY_W 剂量（0 / 0.5 / 1 / 2）… 2. ㉒/㉓/㉕ 三项 +
#   SHIELD_BREAK_W / IDLE_HIT_PENALTY / OBSTACLE_DETOUR_WEIGHT —— 都是实现完没量过的键。这两个也挂上」
#
# 每个模式都是"固定其它一切、只动一个键"的 theta 剂量批（`难度体检.ps1` 的既有机制）：
#   · 底座 = `RL\weights\噩梦.json`（现役）· 对手 = 陪练副本（困难档口径）· 走查台 beam 200
#   · `-Seeds 4`（每臂每牌组 4 个种子）+ 双先后手 ⇒ 每臂 32 配对（项目标准协议）
#   · 汇总：`& RL\train\读数汇总.ps1 -Run <run> -Ctl <对照臂>`（跑完再手动跑，别在批里抢资源）
#
# 七个模式：
#   pb     = ⑬b 附体电池 `POSSESS_BATTERY_W`（pb0 / pb05 / pb1=现役 / pb2）⚠️ **必须带宿魂牌组**
#   idle   = `IDLE_HIT_PENALTY`（i0 / i1 / i2=现役 / i4）
#   detour = ① 障碍绕路 `OBSTACLE_DETOUR_WEIGHT`（d0 / d2 / d4=现役默认 / d8）
#   split  = ㉒隔断 `SPLIT_W`（现成臂表）
#   spread = ㉓离队距离 `FORM_SPREAD_CELL_W`（现成臂表）⚠️ **今天队形尺子换成了限步路网** ⇒ 本量的是新尺子
#   taunt  = ㉕嘲讽吸火 `TAUNT_SOAK_W`（现成臂表；上次 T21 已落地 1.5，这次是复核）
#   shield = ㉔破盾 `SHIELD_BREAK_W`（现成臂表；上次 T20 保留 4.0，这次是复核）
#
# ⚠️ 与正在跑的 `pool4`（8 链）+ `swap1`（4 分片）**并存** ⇒ 机器会有约 19 个进程争 12 核，
#   每一批都会变慢（实测瓶颈是"每格一次进程开销"而不是算力，所以多开会摊薄总时间）。
#
# 用法：& RL\train\_并行跑_剂量批7.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$res = Join-Path $root 'RL\train\results'
$tool = Join-Path $root 'RL\train\难度体检.ps1'

# 宿魂牌组（默认 4 组一个都没有 hero_46；全部 3 人、无召唤 ⇒ 不会拖爆时长）
$suDecks = '"hero_46,hero_11,hero_27","hero_46,hero_32,hero_21","hero_46,hero_12,hero_18","hero_46,hero_09,hero_20"'

$modes = @(
    @{ tag = 'd_pb'; mode = 'pb'; workers = 1; extra = ('-Decks ' + $suDecks) },
    @{ tag = 'd_idle'; mode = 'idle'; workers = 1; extra = '' },
    @{ tag = 'd_detour'; mode = 'detour'; workers = 1; extra = '' },
    @{ tag = 'd_split'; mode = 'split'; workers = 1; extra = '' },
    @{ tag = 'd_spread'; mode = 'spread'; workers = 1; extra = '' },
    @{ tag = 'd_taunt'; mode = 'taunt'; workers = 1; extra = '' },
    @{ tag = 'd_shield'; mode = 'shield'; workers = 1; extra = '' }
)
$procs = @()
foreach ($m in $modes) {
    $arg = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Tag {2} -Workers {3} -Seeds 4 {4}' -f `
        $tool, $m.mode, $m.tag, $m.workers, $m.extra)
    $out = Join-Path $res ('_log_{0}.txt' -f $m.tag)
    $err = Join-Path $res ('_log_{0}.err.txt' -f $m.tag)
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $arg
    Write-Host ('[剂量] {0} (-Mode {1}) 已起 pid={2}' -f $m.tag, $m.mode, $p.Id)
    $procs += $p
}
Write-Host ('[剂量] 共 {0} 个模式在跑；日志 {1}\_log_d_*.txt（GBK 编码，读用 -Encoding Default）' -f $procs.Count, $res)
while ($true) {
    $alive = @($procs | Where-Object { -not $_.HasExited })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 300
    Write-Host ('[剂量] {0}/{1} 仍在跑（{2}）' -f $alive.Count, $procs.Count, (Get-Date -Format 'HH:mm'))
}
Write-Host '[剂量] 七个模式全部结束'
