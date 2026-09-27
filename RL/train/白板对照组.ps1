# 白板对照组.ps1 —— 【2026-09-26 新增·用户方案第一步】
#   用户口径：「挑白板肉盾、白板近战、白板远程作为对照组。对照组三个先模拟平衡一下，
#   然后用带某个英雄的随机组合去打这个对照组来判断强弱，出来数据后，找出偏离大的、微调属性，最终打到满意平衡」
#
# 本脚本做**第一步**：把对照组（伐木工/鼠队长/火枪手）当成一把"绝对尺"，看它相对 6 支基准队是不是落在中位。
#   · 对照组的数值可以用 `-Patch` 临时改（走 `RL/harness_patch` 的属性补丁入口），**游戏数据一个字不动**
#   · 每支基准队跑 2 格（角色对调）× N 种子 ⇒ 配对胜率 + Δpts
#   · 判据：对照组对 6 支基准队的总胜率应落在 **40%~60%**（= 它是一支"中位队"）；偏了就用 -Patch 微调再跑
#
# 用法：
#   & RL\train\白板对照组.ps1                       # 现役白板数值
#   & RL\train\白板对照组.ps1 -Patch "hero_09:hp+2" # 调过再跑（只影响跑批进程）
#
# ⚠️ 自带 runner：不走 Train.ps1（因为补丁 harness 必须放在 RL\harness 之外，
#    而 RlTrain.ps1 会检查那个目录里"唯一"的 .tscn）
[CmdletBinding()]
param(
    [int]$Seeds = 8,
    [int]$SeedStart = 40001,
    [int]$Workers = 8,
    [int]$Beam = 100,
    [string]$Tag = 'baiban1',
    [string]$Patch = '',
    [string]$Godot = 'C:\Users\79076\Documents\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe',
    [switch]$SkipRuns
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$res = Join-Path $root 'RL\train\results'
New-Item -ItemType Directory -Force -Path $res | Out-Null
$scene = 'res://RL/harness_patch/对局_属性补丁.tscn'
$control = 'hero_01,hero_04,hero_09'          # 白板肉盾 + 白板近战 + 白板远程
$refs = @(                                    # 6 支基准队（与换一法同一批）
    'hero_12,hero_15,hero_28', 'hero_11,hero_30,hero_42', 'hero_17,hero_20,hero_23',
    'hero_01,hero_03,hero_22', 'hero_09,hero_24,hero_45', 'hero_43,hero_06,hero_47'
)
$jobs = @()
foreach ($ri in 0..($refs.Count - 1)) {
    foreach ($cell in @('a', 'b')) {
        foreach ($s in 0..($Seeds - 1)) {
            # cell a: A(对照) = enemy, B(基准队) = player ；cell b: 对调
            $ed = if ($cell -eq 'a') { $control } else { $refs[$ri] }
            $pd = if ($cell -eq 'a') { $refs[$ri] } else { $control }
            $run = '{0}_r{1:d2}_{2}_s{3:d2}' -f $Tag, ($ri + 1), $cell, ($s + 1)
            $out = Join-Path $res ("_bb_{0}.txt" -f $run)
            $jobs += [pscustomobject]@{ run = $run; ref = $ri + 1; cell = $cell; seed = $SeedStart + $s; out = $out; ed = $ed; pd = $pd }
        }
    }
}
Write-Host ("[白板] 对照组 = {0}（{1}）· 基准队 {2} 支 · 计划 {3} 局" -f $control, (& { if ($Patch) { '补丁 ' + $Patch } else { '现役数值' } }), $refs.Count, $jobs.Count)

if (-not $SkipRuns) {
    $env:APPDATA = Join-Path $root '.godot_userdata'
    $queue = New-Object System.Collections.Queue
    foreach ($j in $jobs) { $queue.Enqueue($j) }
    $running = @()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Workers) {
            $j = $queue.Dequeue()
            # ⚠️ 必须拼成**带引号的一整串**：`--path` 的路径含空格，传数组时 PowerShell 不加引号
            #   ⇒ Godot 会把 "D:\Game creating\战旗" 拆成两段、进项目管理器**永久等待**（实测卡了 1.5 小时）
            $argline = '--headless --path "{0}" --scene {1} -- 1 {2} {3} {4} - - {5} {5} base p e {6}' -f `
                $root, $scene, $j.seed, $j.ed, $j.pd, $Beam, $(if ($Patch) { $Patch } else { '-' })
            $p = Start-Process -FilePath $Godot -ArgumentList $argline -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $j.out -RedirectStandardError ($j.out + '.err')
            $running += [pscustomobject]@{ j = $j; p = $p }
        }
        Start-Sleep -Seconds 3
        $still = @()
        foreach ($r in $running) { if ($r.p.HasExited) { } else { $still += $r } }
        $running = $still
    }
    Write-Host '[白板] 全部跑完，开始汇总'
}

# ---------- 汇总：对照组视角 ----------
$rows = @()
foreach ($j in $jobs) {
    if (-not (Test-Path $j.out)) { continue }
    $line = Get-Content $j.out -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern '^R\|m\|' | Select-Object -First 1
    if (-not $line) { continue }
    $kv = @{}
    foreach ($seg in ($line.Line -split '\|')) { $i = $seg.IndexOf('='); if ($i -gt 0) { $kv[$seg.Substring(0, $i)] = $seg.Substring($i + 1) } }
    $aIsEnemy = ([int]$kv['a_side'] -eq 1)
    # A 方永远是"对照组"（cell a: 对照=enemy；cell b: 对照=player）
    $rows += [pscustomobject]@{
        ref = $j.ref; cell = $j.cell; seed = $j.seed
        res = [string]$kv['res']; ptsA = [double]$kv['ptsA']
        rounds = [int]$kv['rounds']; dmgA = [int]$kv['dmgA']; dmgB = [int]$kv['dmgB']
    }
}
if ($rows.Count -eq 0) { Write-Host '[白板] 没有可汇总的对局（还没跑？）'; exit 0 }
Write-Host ''
Write-Host '=== 对照组 vs 每支基准队（A 方 = 对照组）==='
$tot = 0; $win = 0
foreach ($g in ($rows | Group-Object ref | Sort-Object Name)) {
    $n = $g.Count; $w = @($g.Group | Where-Object { $_.res -eq 'W' }).Count
    $d = [math]::Round((($g.Group | Measure-Object ptsA -Average).Average), 2)
    $tot += $n; $win += $w
    Write-Host ("  基准队 {0}：{1} 局 · 对照胜 {2} · 胜率 {3:n2} · Δpts {4,7:n2}" -f $g.Name, $n, $w, ($w / $n), $d)
}
Write-Host ''
Write-Host ("=== 合计：{0} 局 · 对照组胜率 {1:n3}（目标 0.40~0.60）· 平均 Δpts {2:n2} ===" -f `
    $tot, ($win / $tot), (($rows | Measure-Object ptsA -Average).Average))
$rows | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $res ('_baiban_' + $Tag + '.json')) -Encoding UTF8
Write-Host ("[白板] 明细已写 _baiban_{0}.json" -f $Tag)
