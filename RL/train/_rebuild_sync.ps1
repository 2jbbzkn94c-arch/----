# 用 src/BattleAI.gd 重新生成两份同步副本（fork / 陪练副本），只做"表头 + beam 注入口"的替换。
# 为什么用脚本：三份正文必须逐字节一致，手改 10 处容易漏；生成后用 Compare-Object 复核差异块数量。
# 只写 RL\ai\*.gd 与临时文件；不碰 src（本脚本的输入）。
$ErrorActionPreference = 'Stop'
$p = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根（不写中文路径，避免编码问题）
$srcPath  = Join-Path $p 'src\BattleAI.gd'
$forkPath = Join-Path $p 'RL\ai\AI_Battle.gd'
$origPath = Join-Path $p 'RL\ai\AI_Battle_原版.gd'
$noBom = New-Object System.Text.UTF8Encoding($false)

$src     = [System.IO.File]::ReadAllText($srcPath, [System.Text.Encoding]::UTF8)
$forkOld = [System.IO.File]::ReadAllText($forkPath, [System.Text.Encoding]::UTF8)
$origOld = [System.IO.File]::ReadAllText($origPath, [System.Text.Encoding]::UTF8)

$ANCHOR = '# ---- 轻量模拟状态 ----'
$BEAM   = 'func _beam() -> int:'
$AFTER  = '# 难度相关的随机抖动'
$INJ    = '# ---- RL 陪练副本专用：对手侧 beam 注入口'

foreach ($pair in @(@('src', $src), @('fork', $forkOld), @('orig', $origOld))) {
    $n = $pair[0]; $t = $pair[1]
    if ($t.IndexOf($ANCHOR) -lt 0) { throw "$n missing ANCHOR" }
    if ($t.IndexOf($BEAM)   -lt 0) { throw "$n missing BEAM" }
    if ($t.IndexOf($AFTER)  -lt 0) { throw "$n missing AFTER" }
}
if ($origOld.IndexOf($INJ) -lt 0) { throw 'orig missing INJ' }

# ---------- fork ----------
$forkHeader = $forkOld.Substring(0, $forkOld.IndexOf($ANCHOR))
$srcBody    = $src.Substring($src.IndexOf($ANCHOR))
if ($forkHeader -match '(?m)^\s*class_name') { throw 'fork header must NOT declare class_name' }
$forkNew = $forkHeader + $srcBody

# ---------- 陪练副本 ----------
$origHeader = $origOld.Substring(0, $origOld.IndexOf($ANCHOR))
if ($origHeader -match '(?m)^\s*class_name') { throw 'orig header must NOT declare class_name' }
# 注入口 = 从 INJ 到"紧随 _beam() 之后的那段注释"之前
$injStart = $origOld.IndexOf($INJ)
$injEnd   = $origOld.IndexOf($AFTER, $injStart)
if ($injEnd -lt 0) { throw 'orig injection end not found' }
$injection = $origOld.Substring($injStart, $injEnd - $injStart)
if ($injection.IndexOf($BEAM) -lt 0) { throw 'injection must contain _beam()' }
# src 里 _beam() 那一段（含函数体）要被"注入口 + 副本自己的 _beam()"替换掉
$srcBeamStart = $srcBody.IndexOf($BEAM)
$srcBeamEnd   = $srcBody.IndexOf($AFTER, $srcBeamStart)
if ($srcBeamEnd -lt 0) { throw 'src beam end not found' }
$origNew = $origHeader + $srcBody.Substring(0, $srcBeamStart) + $injection + $srcBody.Substring($srcBeamEnd)

foreach ($pair in @(@('fork', $forkNew), @('orig', $origNew))) {
    $n = $pair[0]; $t = $pair[1]
    if (($t -split "`n").Count -lt 100) { throw "$n looks truncated" }
    if ($t -match '(?m)^\s*class_name') { throw "$n must not declare class_name" }
    if ($t.IndexOf('_incoming_damage_on') -lt 0) { throw "$n missing new helper" }
}

$forkTmp = Join-Path $p 'RL\ai\_new_fork.gd'
$origTmp = Join-Path $p 'RL\ai\_new_orig.gd'
[System.IO.File]::WriteAllText($forkTmp, $forkNew, $noBom)
[System.IO.File]::WriteAllText($origTmp, $origNew, $noBom)

# ---------- 复核：应该只差"表头(+注入口)" ----------
$srcLines  = [System.IO.File]::ReadAllLines($srcPath, [System.Text.Encoding]::UTF8)
$forkLines = [System.IO.File]::ReadAllLines($forkTmp,  [System.Text.Encoding]::UTF8)
$origLines = [System.IO.File]::ReadAllLines($origTmp,  [System.Text.Encoding]::UTF8)
$d1 = @(Compare-Object $srcLines $forkLines -SyncWindow 6)
$d2 = @(Compare-Object $srcLines $origLines -SyncWindow 40)
$bad1 = @($d1 | Where-Object { $_.InputObject.Trim() -ne '' -and -not $_.InputObject.Trim().StartsWith('#') -and $_.InputObject.Trim() -ne 'class_name BattleAI' })
$bad2 = @($d2 | Where-Object { $_.InputObject.Trim() -ne '' -and -not $_.InputObject.Trim().StartsWith('#') -and $_.InputObject.Trim() -ne 'class_name BattleAI' -and $_.InputObject.Trim() -notmatch '^("|\})' })
'srcLines=' + $srcLines.Count + ' forkLines=' + $forkLines.Count + ' origLines=' + $origLines.Count
'src-vs-fork 差异块=' + $d1.Count + '  意外差异=' + $bad1.Count
$bad1 | Select-Object -First 8 | ForEach-Object { '   ! ' + $_.SideIndicator + ' ' + $_.InputObject.Trim() }
'src-vs-orig 差异块=' + $d2.Count + '  意外差异=' + $bad2.Count
$bad2 | Select-Object -First 12 | ForEach-Object { '   ! ' + $_.SideIndicator + ' ' + $_.InputObject.Trim() }
'临时文件: ' + $forkTmp + ' / ' + $origTmp
