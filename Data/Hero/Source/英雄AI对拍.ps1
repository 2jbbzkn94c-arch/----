# 英雄AI对拍.ps1 —— 一键回答「AI 预测的结算」和「实际打出来的结算」有没有出入。
#
# 什么时候用：**新加了一个英雄**，或者**改了某个英雄的技能效果** => 用这个跑一遍，
#   看 AI 的模拟（它自己脑子里算的）和真实引擎跑出来的结果是否一致。
#
# 它本身不做判定，判定在**同目录**的 `verify_heroes.ps1`（三道检查），本脚本只是它的中文外壳：
#   [L1 静态]  英雄脚本在不在 / HeroRegistry 注册没注册 / 角色表里有没有 / 矩阵场景有没有它的专用臂 / HERO_VALUE 配了没
#   [L2 技能对拍]  `RL\harness\技能对拍.tscn`：同一技能逐案例比 "AI 预测的结算 vs 真实战斗的结算"（MATCH / DIFF / SKIP / SNAP）
#   [L3 实战抽查]  `RL\harness\自由部署_模拟检视.tscn --selftest`：真打一局，逐次行动比对模拟与实际
#                （判定：MATCH / DIFF / TIMING / PROCESS / SPAN / NOPRED）
#
# 本脚本额外做的事：英雄选择菜单（编号/名字/范围/all）· 跑法三档 · 自动找 Godot ·
#   开跑前检查有没有别的 Godot 在跑（两个实例抢同一个 user 目录会 signal 11 崩）·
#   跑完把 `RESULT|hero|verdict|diffs=N` 收成一张汇总表并告诉你看哪个日志。
#
# 用法（一般直接双击 `Data\Hero\Bat\英雄AI对拍.bat`）：
#   位置（2026-09-23 用户把两个文件挪来这里）：本脚本在 `Data\Hero\Source\`，启动器 bat 在 `Data\Hero\Bat\`；
#     bat 依次找 `%~dp0..\Source\` → `%~dp0` → `..\..\..\RL\train\`（旧位置）=> 三处都能双击。
#   本脚本自己上溯找 project.godot（Source → Hero → Data → 项目根，3 层）=> 再挪目录也不用改代码。
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1                      # 交互菜单
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -Heroes hero_30      # 只测一个
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -Heroes 26,22 -Mode quick
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -All -Mode quick     # 全部英雄（只跑矩阵）
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -List                # 只列英雄表
#   powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -All -Mode quick -Force   # 全自动：不问确认
[CmdletBinding()]
param(
    [string[]]$Heroes = @(),
    [switch]$All,
    [switch]$List,
    [ValidateSet('quick', 'std', 'full')][string]$Mode = 'std',
    [int]$Acts = 16,
    [int]$Beam = 50,
    [int]$Seed = 7,
    [string]$Godot = '',
    # L3 抽查用哪份权重（2026-09-23 新增透传）：留空 = verify 的默认（噩梦.json = 生产档）；
    # 想看"老口径"（困难档基线 base.json）就显式传 -Weights res://RL/weights/base.json。
    [string]$Weights = '',
    [switch]$NoMenu,
    # 跳过确认提示（冲突检查 / 全部英雄耗时提醒）；非交互跑批请加它
    [switch]$Force,
    # 只解析并打印"选中了哪些英雄 + 将要执行的命令行"，不真跑（自查输入写法用）
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

function Show([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# ---------- 项目根 ----------
$root = $null
$probe = $PSScriptRoot
for ($i = 0; $i -lt 8 -and $probe; $i++) {
    if (Test-Path (Join-Path $probe 'project.godot')) { $root = $probe; break }
    $probe = Split-Path -Parent $probe
}
if (-not $root -and (Test-Path (Join-Path (Get-Location).Path 'project.godot'))) { $root = (Get-Location).Path }
if (-not $root) { Show '[错误] 找不到 project.godot（项目根）' 'Red'; exit 2 }

# 判定器：2026-09-23 用户把 verify_heroes.ps1 也搬到了本目录（Data\Hero\Source\）⇒ 同目录优先，旧的 RL\ 位置兜底。
$verify = Join-Path $PSScriptRoot 'verify_heroes.ps1'
if (-not (Test-Path -LiteralPath $verify)) { $verify = Join-Path $root 'RL\verify_heroes.ps1' }
if (-not (Test-Path -LiteralPath $verify)) { Show ('[错误] 找不到 ' + $verify) 'Red'; exit 2 }

# ---------- 英雄表：HeroRegistry（脚本）+ 角色列表（中文名/特性）----------
function Read-Utf8([string]$p) { if (Test-Path -LiteralPath $p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } return '' }

$regTxt = Read-Utf8 (Join-Path $root 'heroes\HeroRegistry.gd')
$tbl = @()
foreach ($m in [regex]::Matches($regTxt, '"(hero_\d+)"\s*:\s*"(res://heroes/[^"]+\.gd)"')) {
    $id = $m.Groups[1].Value
    $script = $m.Groups[2].Value
    $num = 0
    [void][int]::TryParse(($id -replace '^hero_', ''), [ref]$num)
    $tbl += [pscustomobject]@{ Num = $num; Id = $id; Script = $script; Name = ''; Trait = ''; Registered = $true }
}
$tbl = @($tbl | Sort-Object Num)

# 盘上有脚本、但没写进 HeroRegistry.gd 的（新增英雄最容易漏这一步）
$unreg = @()
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'heroes') -Filter 'hero_*.gd' -File -ErrorAction SilentlyContinue)) {
    $mm = [regex]::Match($f.Name, '^(hero_\d+)_')
    if (-not $mm.Success) { continue }
    $uid = $mm.Groups[1].Value
    if (@($tbl | ForEach-Object { $_.Id }) -contains $uid) { continue }
    $un = 0
    [void][int]::TryParse(($uid -replace '^hero_', ''), [ref]$un)
    $unreg += [pscustomobject]@{ Num = $un; Id = $uid; Script = ('res://heroes/' + $f.Name); Name = ($f.Name -replace '^hero_\d+_', '' -replace '\.gd$', ''); Trait = ''; Registered = $false }
}
if ($unreg.Count -gt 0) {
    $tbl = @(@($tbl) + @($unreg) | Sort-Object Num)
    Show ''
    Show ('[注意] heroes\ 里有 ' + $unreg.Count + ' 个英雄脚本**没注册**到 heroes\HeroRegistry.gd：' + (($unreg | ForEach-Object { $_.Id }) -join ', ')) 'Yellow'
    Show '        新增英雄要两步：① 放 heroes\hero_XX_名字.gd  ② 在 HeroRegistry.gd 的 _SCRIPTS 里加一行 "hero_XX": "res://heroes/hero_XX_名字.gd"' 'Yellow'
    Show '        （没注册的话游戏和本工具都拿不到这个英雄，选它会被跳过）' 'Yellow'
}

$rows = @()
try { $rows = @(Get-Content -LiteralPath (Join-Path $root 'Data\Hero\Source\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
$byNum = @{}
foreach ($r in $rows) {
    $n = 0
    if ([int]::TryParse([string]$r[0], [ref]$n)) { $byNum[$n] = [pscustomobject]@{ Name = [string]$r[2]; Trait = [string]$r[5] } }
}
foreach ($h in $tbl) {
    if ($byNum.ContainsKey($h.Num)) { $h.Name = $byNum[$h.Num].Name; $h.Trait = $byNum[$h.Num].Trait }
    if ([string]::IsNullOrWhiteSpace($h.Name)) {
        $raw = $h.Script.Substring($h.Script.LastIndexOf('/') + 1) -replace '^hero_\d+_', '' -replace '\.gd$', ''
        $h.Name = $raw
    }
}

# ---------- 只列表 ----------
function Show-HeroTable {
    Show ''
    Show ('  ' + ('{0,-4} {1,-9} {2,-12} {3,-8} {4}' -f '编号', 'hero_id', '名字', '标记', '特性'))
    Show '  ----------------------------------------------------------------'
    foreach ($h in $tbl) { Show ('  ' + ('{0,-4} {1,-9} {2,-12} {3,-8} {4}' -f $h.Num, $h.Id, $h.Name, $(if ($h.Registered) { '' } else { '未注册' }), $h.Trait)) }
    Show ''
    Show ('  共 ' + $tbl.Count + ' 个英雄（来源：heroes\HeroRegistry.gd + Data\Hero\Source\角色列表.json）')
}
if ($List) { Show-HeroTable; exit 0 }

# ---------- 把用户输入解析成 hero_id ----------
function Resolve-Token([string]$tok) {
    $t = $tok.Trim()
    if ($t -eq '') { return @() }
    if ($t -match '^(all|ALL|全部|\*)$') { return @($tbl | ForEach-Object { $_.Id }) }
    if ($t -match '^hero_\d+$') { if ($tbl.Id -contains $t) { return @($t) } else { return @() } }
    if ($t -match '^(\d+)\s*-\s*(\d+)$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
        return @($tbl | Where-Object { $_.Num -ge $a -and $_.Num -le $b } | ForEach-Object { $_.Id })
    }
    if ($t -match '^\d+$') {
        $n = [int]$t
        $hit = @($tbl | Where-Object { $_.Num -eq $n })
        if ($hit.Count -gt 0) { return @($hit[0].Id) }
        return @()
    }
    $hit = @($tbl | Where-Object { $_.Name -eq $t })
    if ($hit.Count -eq 0) { $hit = @($tbl | Where-Object { $_.Name -like ('*' + $t + '*') }) }
    return @($hit | ForEach-Object { $_.Id })
}

function Resolve-Input([string]$line) {
    $ids = @(); $bad = @()
    foreach ($piece in @($line -split '[,，、\s]+' | Where-Object { $_ -ne '' })) {
        $got = @(Resolve-Token $piece)
        if ($got.Count -eq 0) { $bad += $piece } else { $ids += $got }
    }
    return [pscustomobject]@{ Ids = @($ids | Select-Object -Unique); Bad = $bad }
}

$picked = @()
if ($Heroes.Count -gt 0) {
    $r = Resolve-Input ($Heroes -join ',')
    $picked = $r.Ids
    if ($r.Bad.Count -gt 0) { Show ('[警告] 认不出的输入：' + ($r.Bad -join ' ')) 'Yellow' }
} elseif ($All) {
    $picked = @($tbl | ForEach-Object { $_.Id })
}

# ---------- 交互菜单 ----------
if ($picked.Count -eq 0) {
    if ($NoMenu) { Show '[错误] 没给 -Heroes/-All，且 -NoMenu 关闭了菜单' 'Red'; exit 2 }
    Show '============================================================' 'Cyan'
    Show '  英雄 AI 对拍（AI 预测  vs  实际发生）' 'Cyan'
    Show '============================================================' 'Cyan'
    Show '  要测哪些英雄？'
    Show '    编号（可多个）：30        或  26,22,30'
    Show '    范围          ：26-35'
    Show '    名字          ：嬉皮死神   或  死神（模糊匹配）'
    Show '    全部          ：all'
    Show '    先看名单      ：list        退出：q'
    if ([Console]::IsInputRedirected) {
        Show ''
        Show '[错误] 没有交互式控制台（stdin 被重定向）=> 菜单用不了。请直接给参数：' 'Red'
        Show '        powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -Heroes 30' 'Yellow'
        Show '        powershell -NoProfile -File Data\Hero\Source\英雄AI对拍.ps1 -All -Mode quick' 'Yellow'
        exit 2
    }
    $emptyStreak = 0
    while ($true) {
        $line = Read-Host '  输入'
        if ($null -eq $line) { $line = '' }
        if ($line.Trim() -eq '') {
            $emptyStreak++
            if ($emptyStreak -ge 3) { Show '  连续 3 次空输入 => 退出（再双击一次就能重来）。' 'Yellow'; exit 0 }
            continue
        }
        $emptyStreak = 0
        if ($line -match '^\s*(q|Q|quit|exit)\s*$') { Show '  已退出。' 'Yellow'; exit 0 }
        if ($line -match '^\s*(list|ls|名单)\s*$') { Show-HeroTable; continue }
        $r = Resolve-Input $line
        if ($r.Ids.Count -eq 0) { Show ('  认不出：' + ($r.Bad -join ' ') + '   （输入 list 看名单）') 'Yellow'; continue }
        if ($r.Bad.Count -gt 0) { Show ('  忽略认不出的：' + ($r.Bad -join ' ')) 'Yellow' }
        $picked = $r.Ids
        Show ('  选中 ' + $picked.Count + ' 个：' + ($picked -join ', ')) 'Green'
        break
    }
}

# 菜单模式再问一次跑法
if ($Heroes.Count -eq 0 -and -not $All -and -not $NoMenu) {
    Show ''
    Show '  跑法：'
    Show '    1 = 快（只跑技能对拍矩阵，最快）'
    Show '    2 = 标准（矩阵 + 实战抽查一次，推荐）'
    Show '    3 = 彻底（矩阵 + 实战抽查我方 + 敌方两遍，最慢）'
    $m = Read-Host '  输入 1/2/3 [2]'
    if ($m -eq '1') { $Mode = 'quick' } elseif ($m -eq '3') { $Mode = 'full' } else { $Mode = 'std' }
}

# ---------- 未注册的英雄：跳过并告诉用户怎么补 ----------
$unregPicked = @($picked | Where-Object { $u = $_; -not (@($tbl | Where-Object { $_.Id -eq $u -and $_.Registered }) ).Count })
if ($unregPicked.Count -gt 0) {
    Show ''
    Show ('[错误] 这些选中的英雄脚本还没注册到 heroes\HeroRegistry.gd，跑不了：' + ($unregPicked -join ', ')) 'Red'
    Show '        补法：在 heroes\HeroRegistry.gd 的 _SCRIPTS 里加一行，例如' 'Yellow'
    foreach ($u in $unregPicked) { Show ('          "' + $u + '": "res://heroes/' + $u + '_名字.gd",') 'Yellow' }
    $picked = @($picked | Where-Object { $u = $_; @($tbl | Where-Object { $_.Id -eq $u -and $_.Registered }).Count -gt 0 })
    if ($picked.Count -eq 0) { Show '  没有可跑的英雄了，退出。' 'Red'; exit 2 }
    Show ('  继续跑剩下的 ' + $picked.Count + ' 个：' + ($picked -join ', ')) 'Yellow'
}

# ---------- 找 Godot ----------
function Find-Godot {
    if ($Godot -ne '') { if (Test-Path -LiteralPath $Godot) { return (Resolve-Path -LiteralPath $Godot).Path } else { Show ('[错误] -Godot 指的路径不存在：' + $Godot) 'Red'; exit 2 } }
    foreach ($v in @($env:DSH_GODOT_EXE, $env:GODOT_EXE)) { if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path } }
    $roots = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Downloads", 'D:\Software', 'C:\', 'D:\')
    $hits = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hits += @(Get-ChildItem -LiteralPath $r -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue)
        $hits += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue })
    }
    $cand = @($hits | Where-Object { $_.Name -notlike '*_console*' } | Sort-Object Name -Descending)
    if ($cand.Count -gt 0) { return $cand[0].FullName }
    return ''
}
$exe = Find-Godot
if (-not $exe) { Show '[错误] 找不到 Godot 可执行文件（可用环境变量 DSH_GODOT_EXE 指定）' 'Red'; exit 2 }

# ---------- 冲突检查：一次只允许一个 Godot ----------
$others = @(Get-Process -Name 'godot*' -ErrorAction SilentlyContinue)
if ($others.Count -gt 0) {
    Show ''
    foreach ($o in $others) {
        $ttl = ''
        try { $ttl = $o.MainWindowTitle } catch { }
        Show ('[警告] 现在有别的 Godot 在跑：pid=' + $o.Id + '  启动=' + $o.StartTime.ToString('HH:mm:ss') + '  标题=「' + $ttl + '」') 'Yellow'
    }
    Show '        两个实例同时跑会抢同一个 user 目录 => 可能 signal 11 崩溃、也可能互相拖慢。' 'Yellow'
    Show '        （无窗口标题的一般是跑批残留；有标题的多半是你自己开的游戏/场景）' 'DarkGray'
    if ($Force) {
        Show '        -Force：忽略冲突继续。' 'Yellow'
    } elseif ([Console]::IsInputRedirected) {
        Show '        非交互环境 => 不会自动继续。想强跑就加 -Force。' 'Red'
        exit 2
    } else {
        $ans = Read-Host '        仍然继续？(y/N)'
        if ($ans -notmatch '^[yY]') { Show '  已取消（先把上面的 Godot 关掉再跑）。' 'Yellow'; exit 0 }
    }
}

# ---------- 全部英雄的耗时提醒 ----------
if ($picked.Count -ge 12) {
    $perHero = switch ($Mode) { 'quick' { '约 1 分钟' } 'std' { '约 2 分钟' } default { '约 3 分钟' } }   # 2026-09-23 实测：preflight+probe ~40s，矩阵 30s，抽查 20s（hero_30）
    Show ''
    Show ('[注意] 你选了 ' + $picked.Count + ' 个英雄，每个' + $perHero + ' => 粗略估计 ' + $perHero + ' × ' + $picked.Count + '。') 'Yellow'
    Show '       想快就先跑「快」档（只对拍技能矩阵），只对可疑的那几个英雄跑「标准/彻底」。' 'Yellow'
    if ($Force) {
        Show '        -Force：直接开跑。' 'Yellow'
    } elseif ([Console]::IsInputRedirected) {
        Show '        非交互环境 => 不会自动开跑。想强跑就加 -Force。' 'Red'
        exit 2
    } else {
        $ans = Read-Host '        继续？(y/N)'
        if ($ans -notmatch '^[yY]') { Show '  已取消。' 'Yellow'; exit 0 }
    }
}

# ---------- 组装并跑 verify_heroes.ps1 ----------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verify, '-Heroes', ($picked -join ','),
    '-Acts', "$Acts", '-Beam', "$Beam", '-Seed', "$Seed", '-Stamp', $stamp, '-Godot', $exe, '-Project', $root)
if ($Mode -eq 'quick') { $argList += '-SkipSweep' }
if ($Mode -eq 'full') { $argList += '-BothSides' }
if ($Weights -ne '') { $argList += @('-Weights', $Weights) }

Show ''
Show '============================================================' 'Cyan'
Show ('  开跑：' + $picked.Count + ' 个英雄 · 跑法=' + $Mode + ' · Acts=' + $Acts + ' · Beam=' + $Beam + ' · Seed=' + $Seed)
Show ('  Godot：' + $exe)
Show ('  日志：RL\reports\verify_' + $stamp + '.log')
Show '  （矩阵/抽查都是真跑 Godot，窗口会安静一会儿，正常）' 'DarkGray'
Show '============================================================' 'Cyan'
Show ''

# ---------- -DryRun：只回显"选了谁 + 要跑什么"，不真跑 ----------
if ($DryRun) {
    Show '[DryRun] 选中英雄：' 'Cyan'
    foreach ($id in $picked) {
        $h = $tbl | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        Show ('    ' + $h.Id + '  ' + $h.Name + '  ' + $h.Trait)
    }
    Show ''
    Show '[DryRun] 将执行：' 'Cyan'
    Show ('    powershell ' + ($argList -join ' '))
    Show ''
    Show '[DryRun] 没有跑任何东西。' 'Yellow'
    exit 0
}

$runStart = Get-Date
& powershell @argList | ForEach-Object { $_.ToString() }
$code = $LASTEXITCODE

# ---------- 收尾：清掉本次跑批留下的 headless 残留 ----------
# verify 只在"超时"时才杀 Godot；正常跑完时偶尔会漏下 headless 子进程（无窗口）。
# 判断标准很保守：**无窗口标题** 且 **启动时间晚于本次开跑** => 一定是本次跑批留下的。
$leftover = @(Get-Process -Name 'godot*' -ErrorAction SilentlyContinue | Where-Object {
        $t = ''
        try { $t = $_.MainWindowTitle } catch { }
        [string]::IsNullOrEmpty($t) -and $_.StartTime -ge $runStart
    })
if ($leftover.Count -gt 0) {
    Show ''
    Show ('[收尾] 发现 ' + $leftover.Count + ' 个本次跑批残留的 headless Godot（verify 的超时清理没覆盖到）：' + (($leftover | ForEach-Object { $_.Id }) -join ', ')) 'Yellow'
    foreach ($l in $leftover) { try { Stop-Process -Id $l.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Show '        已结束它们（你自己开的窗口/游戏不受影响）。' 'DarkGray'
}

# ---------- 汇总表（从 verify 的 transcript 里收 RESULT| 行）----------
$logPath = Join-Path $root ('RL\reports\verify_' + $stamp + '.log')
$results = @{}
if (Test-Path -LiteralPath $logPath) {
    foreach ($line in (Get-Content -LiteralPath $logPath -Encoding UTF8)) {
        if ($line -match '^RESULT\|(hero_\d+)\|([A-Z]+)\|diffs=(\d+)') {
            $results[$Matches[1]] = [pscustomobject]@{ Verdict = $Matches[2]; Diffs = [int]$Matches[3] }
        }
    }
}
Show ''
Show '============================================================' 'Cyan'
Show '  汇总（AI 预测 vs 实际发生）' 'Cyan'
Show '============================================================' 'Cyan'
Show ('  ' + ('{0,-4} {1,-9} {2,-12} {3,-8} {4}' -f '编号', 'hero_id', '名字', '判定', '差异行'))
Show '  ------------------------------------------------------------'
$nDiff = 0; $nCaution = 0; $nOk = 0; $nNone = 0
foreach ($id in $picked) {
    $h = $tbl | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    $res = $results[$id]
    if (-not $res) { $v = '（没跑到）'; $d = '-'; $nNone++ }
    else {
        $v = $res.Verdict; $d = [string]$res.Diffs
        if ($v -eq 'DIFF') { $nDiff++ } elseif ($v -eq 'CAUTION') { $nCaution++ } else { $nOk++ }
    }
    $color = 'Gray'
    if ($v -eq 'DIFF') { $color = 'Red' } elseif ($v -eq 'CAUTION') { $color = 'Yellow' } elseif ($v -eq 'OK') { $color = 'Green' }
    Show ('  ' + ('{0,-4} {1,-9} {2,-12} {3,-8} {4}' -f $h.Num, $h.Id, $h.Name, $v, $d)) $color
}
Show ''
Show ('  合计：OK ' + $nOk + ' · CAUTION ' + $nCaution + ' · DIFF ' + $nDiff + $(if ($nNone -gt 0) { ' · 没跑到 ' + $nNone } else { '' }))
Show ''
Show '  判定含义：'
Show '    OK      = 这一档里 AI 的预测和真实战斗逐案例一致' 'Green'
Show '    CAUTION = 没发现差异，但该英雄在技能对拍矩阵里没有专用场景臂 => 通用动作族覆盖不到它的入场/回合/被动/光环技能，' 'Yellow'
Show '              "全 MATCH" 不等于安全（新增英雄常见这种情况：先给它补一个矩阵场景再跑）' 'Yellow'
Show '    DIFF    = 有真实出入。逐行细节在上面的 CONCLUSION 段 + 日志（默认每个英雄最多打 20 行）' 'Red'
Show ''
Show '  下一步怎么用：'
Show '    DIFF  → 先看差异行说的是哪一步（哪个技能/哪笔结算），再对 英雄脚本 heroes\hero_XX_*.gd 与 AI 侧 src\BattleAI.gd / RL\ai\AI_Battle.gd 的同名处理'
Show '    CAUTION → 去 RL\harness\技能对拍.gd 里给这个英雄补一个专用场景臂，然后再跑一次'
Show ('    完整日志：RL\reports\verify_' + $stamp + '.log（含每个英雄的矩阵/抽查原始输出文件名）')
Show ''
switch ($code) {
    0 { Show '  退出码 0：全绿。' 'Green' }
    1 { Show '  退出码 1：至少有一个真实 DIFF（上面红色的行）。' 'Red' }
    default { Show ('  退出码 ' + $code + '：预检/环境问题，什么都没跑成（看日志开头）。') 'Red' }
}
exit $code
