# RlTrain.ps1 -- RL weight-training pipeline helpers for the tactics game.
# PURE ASCII ONLY. PS 5.1 reads .ps1 as ANSI: any non-ASCII byte here becomes mojibake.
# Chinese text lives only in .md reports written with the write tool.
#
# Hard rules honoured by this file:
#   * only writes under RL\train\** and RL\weights\cand_*.json
#   * never touches .godot, src, heroes, scenes, project.godot, RL\ai, RL\harness
#   * one Godot instance at a time; never kills a process it did not start
#   * Godot stdout is captured via cmd /c redirection (PowerShell capture yields empty)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'project.godot'))) {
    throw "Repo root not detected from $PSScriptRoot (no project.godot in $script:RepoRoot)"
}
# 【2026-09-19 改·用户批准"自动"】Godot 可执行文件**自动探测**（原来写死桌面路径；
#   用户把 Godot 移到 Documents 后整条训练链直接跑不了）。顺序：
#     ① 环境变量 `DSH_GODOT_EXE` / `GODOT_EXE`（最高优先，方便临时指向别的版本）
#     ② 常见位置：Documents / Desktop / Downloads / D:\Software / C:\ / D:\
#        每个位置既看"顶层 exe"，也看"同名子目录里的 exe"（官方 zip 解压后就是那种形态）
#     ③ 排除 `*_console.exe`（控制台版是伴生程序，不能当编辑器/主程序用）
#     ④ 多个候选时按文件名倒序（版本号大的优先）
#   找不到就抛错并提示可用环境变量指定 —— 不再静默失败。
function Find-GodotExe {
    foreach ($v in @($env:DSH_GODOT_EXE, $env:GODOT_EXE)) {
        if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path }
    }
    $roots = @("$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", 'D:\Software', 'C:\', 'D:\')
    $hits = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hits += @(Get-ChildItem -LiteralPath $r -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue)
        $hits += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue })
    }
    $cand = @($hits | Where-Object { $_.Name -notlike '*_console*' } | Sort-Object Name -Descending)
    if ($cand.Count -gt 0) { return $cand[0].FullName }
    return $null
}
$script:GodotExe = Find-GodotExe
if (-not $script:GodotExe) {
    throw "Godot executable not found (searched Documents/Desktop/Downloads/D:\Software/C:\/D:\). Set env DSH_GODOT_EXE to point at it."
}
$script:KnownEditorPid = 0              # 仅日志用；冲突判据已改成"有没有窗口标题"（见 Wait-GodotSlot）

# The harness / opponent files have CJK names. Rather than embed those characters in this script
# (PS 5.1 decodes a BOM-less .ps1 as ANSI and would corrupt them), identify them by content.
$aiDir = Join-Path $script:RepoRoot 'RL\ai'
$oppHit = @(Get-ChildItem -LiteralPath $aiDir -File | Where-Object {
    $_.Extension -eq '.gd' -and $_.Name -like 'AI_Battle_*' -and $_.Name -ne 'AI_Battle.gd'
})
if ($oppHit.Count -ne 1) {
    throw ('expected exactly one AI_Battle_<variant>.gd in ' + $aiDir + ', found ' + $oppHit.Count)
}
$script:OpponentScript = $oppHit[0].FullName

# The duel harness is the .tscn whose sibling .gd prints the R|SUMMARY| protocol.
$hDir = Join-Path $script:RepoRoot 'RL\harness'
$sceneHit = @(Get-ChildItem -LiteralPath $hDir -File | Where-Object {
    if ($_.Extension -ne '.tscn') { return $false }
    $gd = Join-Path $hDir ($_.BaseName + '.gd')
    if (-not (Test-Path -LiteralPath $gd)) { return $false }
    return ([System.IO.File]::ReadAllText($gd, [System.Text.Encoding]::UTF8)).Contains('R|SUMMARY|')
})
if ($sceneHit.Count -ne 1) {
    throw ('expected exactly one harness .tscn (sibling .gd prints R|SUMMARY|) in ' + $hDir + ', found ' + $sceneHit.Count)
}
$script:HarnessScene = 'res://RL/harness/' + $sceneHit[0].Name
$script:HarnessScript = Join-Path $hDir ($sceneHit[0].BaseName + '.gd')

function Assert-ScriptEncoding([string[]]$Paths, [switch]$Repair) {
    # PS 5.1 decodes a BOM-less .ps1 as ANSI, which silently corrupts every CJK path literal inside it
    # (a real incident: 9 files once got rewritten as 0 bytes). We repair the BOM when we can and
    # refuse to run otherwise, instead of running with mangled paths.
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { throw ('missing script: ' + $p) }
        $b = [System.IO.File]::ReadAllBytes($p)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { continue }
        if ($Repair) {
            if ($b.Length -lt 1) { throw ('ENCODING GUARD: ' + $p + ' is empty; refusing to touch it') }
            $text = [System.Text.Encoding]::UTF8.GetString($b)
            [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host ('[guard] re-added UTF-8 BOM to ' + (Split-Path -Leaf $p) + ' (PS 5.1 would otherwise misread it as ANSI)')
            continue
        }
        throw ('ENCODING GUARD: ' + $p + ' has no UTF-8 BOM (PS 5.1 would misread it as ANSI). Run with -RepairBom to fix it.')
    }
}

# ============================ small utilities ============================

function Get-Sha256Hex12([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower().Substring(0, 12)
    } finally { $sha.Dispose() }
}

function Get-Num([object]$Value) {
    # JSON numbers come back as Int64 / Double / Decimal; normalise to double.
    return [double]::Parse(([string]$Value), [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Num([double]$Value, [int]$Digits = 6) {
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 'NA' }
    return $Value.ToString('F' + $Digits, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Read-JsonFile([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Add-ContentUtf8([string]$Path, [string[]]$Lines) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::AppendAllText($Path, (($Lines -join "`r`n") + "`r`n"), $enc)
}

function Write-TextUtf8([string]$Path, [string[]]$Lines) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

function Format-Argv([string[]]$Argv) {
    $parts = @()
    foreach ($a in $Argv) {
        if ($a -eq '' -or $a -match '[\s"]') { $parts += ('"' + ($a -replace '"', '\"') + '"') } else { $parts += $a }
    }
    return ($parts -join ' ')
}

# ============================ statistics ============================

function Inv-NormalCdf([double]$P) {
    # Acklam's rational approximation to the standard normal quantile; |err| < 1.15e-9.
    if ($P -le 0.0 -or $P -ge 1.0) { throw "Inv-NormalCdf: p must be in (0,1), got $P" }
    $a = @(-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
           1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00)
    $b = @(-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
           6.680131188771972e+01, -1.328068155288572e+01)
    $c = @(-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
           -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00)
    $d = @(7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00)
    $pLow = 0.02425
    $pHigh = 1.0 - $pLow
    if ($P -lt $pLow) {
        $q = [Math]::Sqrt(-2.0 * [Math]::Log($P))
        return ((((($c[0] * $q + $c[1]) * $q + $c[2]) * $q + $c[3]) * $q + $c[4]) * $q + $c[5]) /
               (((($d[0] * $q + $d[1]) * $q + $d[2]) * $q + $d[3]) * $q + 1.0)
    }
    if ($P -le $pHigh) {
        $q = $P - 0.5
        $r = $q * $q
        return (((((($a[0] * $r + $a[1]) * $r + $a[2]) * $r + $a[3]) * $r + $a[4]) * $r + $a[5]) * $q) /
               ((((($b[0] * $r + $b[1]) * $r + $b[2]) * $r + $b[3]) * $r + $b[4]) * $r + 1.0)
    }
    $q = [Math]::Sqrt(-2.0 * [Math]::Log(1.0 - $P))
    return -((((($c[0] * $q + $c[1]) * $q + $c[2]) * $q + $c[3]) * $q + $c[4]) * $q + $c[5]) /
            (((($d[0] * $q + $d[1]) * $q + $d[2]) * $q + $d[3]) * $q + 1.0)
}

function Get-WilsonInterval([int]$W, [int]$N, [double]$Z = 1.959963984540054) {
    # Equal-tailed Wilson score interval (closed form; exact for integer counts).
    #   lo,hi = [ phat + z^2/2n +/- z*sqrt( phat(1-phat)/n + z^2/4n^2 ) ] / (1 + z^2/n)
    # n here is the number of *Bernoulli trials*; a draw contributes one half-win across two trials.
    $res = [ordered]@{ phat = 0.0; lo = [double]::NaN; hi = [double]::NaN; n = $N; w = $W }
    if ($N -le 0) { return [pscustomobject]$res }
    $phat = [double]$W / [double]$N
    $res.phat = $phat
    $z2 = $Z * $Z
    $denom = 1.0 + $z2 / $N
    $center = ($phat + $z2 / (2.0 * $N)) / $denom
    $half = ($Z * [Math]::Sqrt($phat * (1.0 - $phat) / $N + $z2 / (4.0 * $N * $N))) / $denom
    $lo = $center - $half
    $hi = $center + $half
    if ($W -eq 0) { $lo = 0.0 }
    if ($W -eq $N) { $hi = 1.0 }
    $res.lo = [Math]::Max(0.0, $lo)
    $res.hi = [Math]::Min(1.0, $hi)
    return [pscustomobject]$res
}

function Get-Stats([array]$Rows, [double]$Z = 1.959963984540054) {
    # Rows: objects with .res ('W'/'L'/'D') and .diff (ptsA - ptsB), one per game.
    $n = $Rows.Count
    $w = 0; $l = 0; $d = 0
    $sumDiff = 0.0
    $diffs = New-Object System.Collections.Generic.List[double]
    $sumWin = 0.0
    foreach ($r in $Rows) {
        $res = [string]$r.res
        if ($res -eq 'W') { $w++ } elseif ($res -eq 'L') { $l++ } else { $d++ }
        $dv = Get-Num $r.diff
        $sumDiff += $dv
        $diffs.Add($dv)
        $wi = 0.0
        if ($res -eq 'W') { $wi = 1.0 } elseif ($res -eq 'D') { $wi = 0.5 }
        $sumWin += $wi
    }
    $out = [ordered]@{
        n = $n; w = $w; l = $l; d = $d
        rate = [double]::NaN; rate_lo = [double]::NaN; rate_hi = [double]::NaN
        pts_per_game = [double]::NaN; pts_sd = [double]::NaN; pts_se = [double]::NaN
        pts_lo95 = [double]::NaN; pts_hi95 = [double]::NaN
        winrate_raw = [double]::NaN; rate_units = 0
    }
    if ($n -eq 0) { return [pscustomobject]$out }

    $out.rate = $sumWin / $n
    $out.winrate_raw = [double]$w / $n
    # Wilson in half-win units: W counts 2, D counts 1, L counts 0 (=> 2n trials).
    $k = [int][Math]::Round($sumWin * 2.0, 0)
    $out.rate_units = $k
    $wi2 = Get-WilsonInterval -W $k -N (2 * $n) -Z $Z
    $out.rate_lo = $wi2.lo
    $out.rate_hi = $wi2.hi

    $out.pts_per_game = $sumDiff / $n
    if ($n -gt 1) {
        $mean = $out.pts_per_game
        $var = 0.0
        foreach ($dv in $diffs) { $var += ($dv - $mean) * ($dv - $mean) }
        $var = $var / ($n - 1)
        $out.pts_sd = [Math]::Sqrt($var)
        $out.pts_se = $out.pts_sd / [Math]::Sqrt([double]$n)
        $out.pts_lo95 = $mean - $Z * $out.pts_se
        $out.pts_hi95 = $mean + $Z * $out.pts_se
    }
    return [pscustomobject]$out
}

function Test-StatsSelfTest {
    $fail = 0
    # Reference values cross-checked against published Wilson score intervals:
    #   4/5 -> 0.3755..0.9638 ; 10/100 -> 0.0552..0.1744 ; 50/100 -> 0.4038..0.5962
    #   the study baseline 8/14 -> 0.3259..0.7862
    $cases = @(
        @{ w = 4; n = 5; lo = 0.375535; hi = 0.963776 },
        @{ w = 10; n = 100; lo = 0.055229; hi = 0.174366 },
        @{ w = 50; n = 100; lo = 0.403832; hi = 0.596168 },
        @{ w = 8; n = 14; lo = 0.325906; hi = 0.786192 }
    )
    foreach ($c in $cases) {
        $got = Get-WilsonInterval -W $c.w -N $c.n
        if (([Math]::Abs($got.lo - $c.lo) -lt 1e-5) -and ([Math]::Abs($got.hi - $c.hi) -lt 1e-5)) {
            Write-Host ('ok  wilson ' + $c.w + '/' + $c.n + ' = ' + (Format-Num $got.lo 6) + ' .. ' + (Format-Num $got.hi 6) + '  (reference ' + (Format-Num $c.lo 6) + ' .. ' + (Format-Num $c.hi 6) + ')')
        } else {
            $fail++
            Write-Host ('FAIL wilson ' + $c.w + '/' + $c.n + ' -> ' + (Format-Num $got.lo 6) + ' .. ' + (Format-Num $got.hi 6))
        }
    }

    $wi2 = Get-WilsonInterval -W 5 -N 10
    if ([Math]::Abs(($wi2.lo + $wi2.hi) - 1.0) -lt 1e-12) { Write-Host 'ok  wilson 5/10 symmetric' }
    else { $fail++; Write-Host 'FAIL wilson symmetry 5/10' }

    $wi3 = Get-WilsonInterval -W 0 -N 10
    $wi4 = Get-WilsonInterval -W 10 -N 10
    if (($wi3.lo -eq 0.0) -and ($wi4.hi -eq 1.0)) { Write-Host 'ok  wilson 0/10 and 10/10 degenerate' }
    else { $fail++; Write-Host 'FAIL wilson degenerate' }

    $z = Inv-NormalCdf 0.975
    if ([Math]::Abs($z - 1.959964) -lt 1e-5) { Write-Host ('ok  Inv-NormalCdf(0.975) = ' + (Format-Num $z 8)) }
    else { $fail++; Write-Host ('FAIL Inv-NormalCdf(0.975) = ' + (Format-Num $z 8)) }

    # half-win semantics: 17W 14L 1D on 32 games -> units = 34+1 = 35 of 64
    $rows = @()
    for ($i = 0; $i -lt 17; $i++) { $rows += [pscustomobject]@{ res = 'W'; diff = 10.0 } }
    for ($i = 0; $i -lt 14; $i++) { $rows += [pscustomobject]@{ res = 'L'; diff = -10.0 } }
    $rows += [pscustomobject]@{ res = 'D'; diff = 0.0 }
    $st = Get-Stats -Rows $rows
    $want = 35.0 / 64.0
    if (([Math]::Abs($st.rate - 35.0 / 64.0) -lt 1e-12) -and ($st.rate_units -eq 35) -and ([Math]::Abs($st.rate_lo - (Get-WilsonInterval -W 35 -N 64).lo) -lt 1e-12)) {
        Write-Host ('ok  Get-Stats 17W/14L/1D -> rate=35/64=' + (Format-Num $st.rate 4) + ' lo=' + (Format-Num $st.rate_lo 4))
    } else { $fail++; Write-Host ('FAIL Get-Stats half-win: rate=' + $st.rate + ' units=' + $st.rate_units) }

    if ([Math]::Abs($st.pts_per_game - ((17 * 10.0 - 14 * 10.0) / 32.0)) -lt 1e-12) { Write-Host 'ok  Get-Stats pts/game' }
    else { $fail++; Write-Host 'FAIL Get-Stats pts/game' }

    Write-Host ('selftest failures: ' + $fail)
    return $fail
}

# ============================ weights ============================

function Get-OrderedScoreKeys {
    # ===== 训练空间（2026-09-18：7 → 6）=====
    # 依据 = 9 批实验（约 4700 局）+ 探针，逐键判定见 RL/reports/逐键有效性_20260917.md §八 与
    # AI评分项全清单.md §14#88。**只有"确实会改变结果、且方向还没定"的键留在这里**：
    #   FOCUS_FIRE_WEIGHT   降它显著变差（三块合并 −5.85，CI[−10.9,−0.8]）；升它两轮都为正 ⇒ 值得训
    #   HP_VALUE_W          活键：两轮都指向"调低更好"（合并 +4.48，CI 刚跨 0）⇒ 值得训
    #   THREAT_MOVE_DISCOUNT 探针里唯一干净的剂量-响应（翻盘率最高 0.23）；游戏臂样本不足 ⇒ 值得训
    #   THREAT_DEAD_FOLD    调低 −6.48（CI 上界 +0.23）⇒ 它**有效果**，最优值未定 ⇒ 值得训
    #   THREAT_INCOMING_W   调到 0.5 → +4.83 但 sd 57（全场最大）⇒ 影响大、方向不定 ⇒ 值得训
    #   BUFF_TAKE_WEIGHT    历史唯一出现过显著（别调低），但在 94 对上翻正 ⇒ 不稳健 ⇒ 值得训
    # 【2026-09-20 用户要求·解 const】`ENGAGE_PULL_PER_CELL` **移回搜索空间** —— 它在 `src/BattleAI.gd`
    #   里已从 `const` 改回 `var w_engage_pull`（默认仍 = 1.2 ⇒ 不注入时逐位不变）。
    #   当初把它移出的唯一理由是"写死成 const ⇒ 留着只会生成'设了也无效'的空臂"，那个理由已消失。
    #   它仍是**弱依据**的键（镜像同队伍 64 局 sd 0.05），但方向确实还没定：它是「进圈拉力」这条链上
    #   唯一还活着的斜率旋钮（另一半是 `ENGAGE_STANDOFF` 停止线）⇒ 训练空间 6 → **7**。
    # 其余移入 Get-PinnedScoreKeys（不进搜索、但仍可在 theta 里显式点名）：OBSTACLE_DETOUR_WEIGHT /
    #   BEAM / JITTER；另有 4 个已写死（见该函数的说明）。
    # 【2026-09-19 用户同意】`FOCUS_TIMES_WEIGHT` 已**整项从引擎删除**（键 + 评分项 + `hurt_times`）⇒
    #   它既不在这里、也不在 Pinned 里；权重文件/theta 里再写它会被 `set_weights` 静默忽略。
    # 2026-09-15: the six GOLD_* keys are hero_42-only specialisation -> flat form HERO_hero_42_GOLD_*.
    return @('FOCUS_FIRE_WEIGHT',
             'HP_VALUE_W',
             'THREAT_MOVE_DISCOUNT',
             'THREAT_DEAD_FOLD',
             'BUFF_TAKE_WEIGHT',
             # 2026-09-20 解 const 移回（"进圈拉力"每格分；默认 1.2）
             'ENGAGE_PULL_PER_CELL')
}

function Get-PinnedScoreKeys {
    # 被 set_weights 接受、**不进自动搜索**、但**允许在 theta 里显式点名**的键（2026-09-17 精简）。
    # 它们都已被实验判定为"改了几乎不改结果"或"不是评分旋钮"：
    #   OBSTACLE_DETOUR_WEIGHT(4.0) 探针零翻盘；p1_obst 臂无显著
    #   BEAM(200) / JITTER(0)  不是评分项：归难度定义（简单 50/100/200、±8/±1.5/0）
    # 【2026-09-19 用户同意】`FOCUS_TIMES_WEIGHT` 已整项删除（不是钉住、是**不存在**）。
    # ⚠️ 2026-09-18（用户批准"写死依据强的"）：`VALUE_SOLO_W` / `VALUE_RELATION_W` /
    #   `PLAYER_VALUE_MULT` / `MAX_MOVE_OPTIONS` **已从本清单移出** ——
    #   它们在 `src/BattleAI.gd` 里变成了 `const`，权重文件再写也会被忽略（值恒为 const）。
    #   依据见 BattleAI.gd 顶部"键退出可调表"块（探针 + 多批游戏臂的实测数字）。
    #   ⚠️ 【2026-09-20 解 const】`ENGAGE_PULL_PER_CELL` 已回到 `Get-OrderedScoreKeys`（搜索空间），
    #   所以它既不在本清单里、也不是写死的。
    #   代价：那批历史 run（p1_*、k_pv_*、shj_* 等）里的这些键从此**静默失效**——
    #   它们本来就是历史留档，复跑会得到与旧记录不同的结果（重新测才准）。
    return @('OBSTACLE_DETOUR_WEIGHT', 'BEAM')
}

function New-CandidateWeights {
    <#
      Build RL\weights\cand_<Name>.json from a base weights file plus a theta overlay.
      $Theta may contain score keys (numbers), 'HERO_VALUE' (nested dict),
      'HERO_VALUE_HERO_XX' (flat per-hero value coefficient), or 'HERO_hero_XX_SCORE_KEY'
      (flat per-hero score-key override -> written as { "hero_XX": { "SCORE_KEY": v } }).
      Returns the path written.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][object]$Theta = $null,
        [Parameter(Mandatory = $false)][string]$Note = '',
        # Where to write. Defaults to RL/weights/cand_<Name>.json; the league checkpoint overrides it.
        [Parameter(Mandatory = $false)][string]$OutPath = ''
    )
    if ($Name -notmatch '^[A-Za-z0-9_\-]+$') { throw "candidate name must be ASCII [A-Za-z0-9_-]: $Name" }
    $obj = Read-JsonFile $BasePath
    $scoreKeys = Get-OrderedScoreKeys
    $hv = [ordered]@{}
    if ($obj.PSObject.Properties.Name -contains 'HERO_VALUE') {
        foreach ($p in $obj.HERO_VALUE.PSObject.Properties) { $hv[$p.Name] = Get-Num $p.Value }
    }
    # Per-hero sections (e.g. hero_42 -> { GOLD_TAKE_VALUE: 40 }) that the base file already carries.
    $heroSec = [ordered]@{}
    foreach ($pn in $obj.PSObject.Properties.Name) {
        if ($pn -match '^hero_[0-9]{2}$') {
            $sec0 = [ordered]@{}
            foreach ($p in $obj.$pn.PSObject.Properties) { $sec0[$p.Name] = Get-Num $p.Value }
            $heroSec[$pn] = $sec0
        }
    }
    $overrides = [ordered]@{}
    if ($null -ne $Theta) {
        foreach ($p in $Theta.PSObject.Properties) {
            $k = $p.Name
            if ($k -eq 'HERO_VALUE') {
                foreach ($pp in $p.Value.PSObject.Properties) { $hv[$pp.Name] = Get-Num $pp.Value }
                $overrides['HERO_VALUE'] = 'nested'
                continue
            }
            if ($k -like 'HERO_VALUE_HERO_*') {
                $hid = 'hero_' + $k.Substring('HERO_VALUE_HERO_'.Length)
                if ($hid -notmatch '^hero_[0-9]{2}$') { throw "bad hero override key: $k" }
                $hv[$hid] = Get-Num $p.Value
                $overrides[$k] = Get-Num $p.Value
                continue
            }
            # Flat per-hero score-key override: HERO_hero_42_GOLD_TAKE_VALUE
            if ($k -like 'HERO_hero_*') {
                $m = [regex]::Match($k, '^HERO_(hero_[0-9]{2})_([A-Z][A-Z0-9_]*)$')
                if (-not $m.Success) { throw "bad hero-scoped key (want HERO_hero_XX_SCORE_KEY): $k" }
                $hid = $m.Groups[1].Value
                $sk = $m.Groups[2].Value
                if (-not $heroSec.Contains($hid)) { $heroSec[$hid] = [ordered]@{} }
                $heroSec[$hid][$sk] = Get-Num $p.Value
                $overrides[$k] = Get-Num $p.Value
                continue
            }
            # 规则键（FOCUS_KILL_RULE / MOVE_ACCEPT_DAMAGE / SUB_JOIN_RULE …）与**钉住的键**
            # （Get-PinnedScoreKeys：VALUE_SOLO_W / PLAYER_VALUE_MULT / FOCUS_TIMES_WEIGHT …）都
            # **允许显式点名**（对照臂就是这么做的），但它们都不在自动搜索清单里。
            if ($scoreKeys -notcontains $k -and (Get-RuleScoreKeys) -notcontains $k -and (Get-PinnedScoreKeys) -notcontains $k) { throw "theta key not accepted by AI_Battle.set_weights: $k" }
            # 基档(噩梦.json)里还没有这个键时也要能写进去：旧代码直接赋值会抛
            # "The property 'XXX' cannot be found on this object" —— 等于"新增评分键必须先改基档
            # 才能跑"，很坑。这里改成缺就 Add-Member（缺的键在 AI 侧回落到代码默认值）。
            if ($obj.PSObject.Properties.Name -contains $k) {
                $obj.$k = Get-Num $p.Value
            } else {
                $obj | Add-Member -NotePropertyName $k -NotePropertyValue (Get-Num $p.Value) -Force
            }
            $overrides[$k] = Get-Num $p.Value
        }
    }
    if ($hv.Count -gt 0) {
        $obj | Add-Member -NotePropertyName 'HERO_VALUE' -NotePropertyValue ([pscustomobject]$hv) -Force
    }
    # Per-hero score-key sections: { "hero_42": { "GOLD_TAKE_VALUE": 40 } }. Written whenever the base
    # file or the theta carries them; the AI side reads them through set_hero_weights (set_weights
    # forwards any 'hero_XX' dictionary section, see BattleAI.set_weights).
    foreach ($hid in @($heroSec.Keys)) {
        if ($heroSec[$hid].Count -eq 0) { continue }
        $obj | Add-Member -NotePropertyName $hid -NotePropertyValue ([pscustomobject]$heroSec[$hid]) -Force
    }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $meta = 'cand_' + $Name + ' | generated by RlTrain.ps1 at ' + $stamp +
            ' | base=' + (Split-Path -Leaf $BasePath) + ' | overrides=' + ($overrides | ConvertTo-Json -Compress -Depth 6) +
            ' | note=' + $Note
    $obj | Add-Member -NotePropertyName '_rl_generated' -NotePropertyValue $meta -Force
    $obj | Add-Member -NotePropertyName '_rl_base_sha12' -NotePropertyValue (Get-Sha256Hex12 $BasePath) -Force

    $outPath = $OutPath
    if (-not $outPath) { $outPath = Join-Path (Join-Path $script:RepoRoot 'RL\weights') ('cand_' + $Name + '.json') }
    $json = $obj | ConvertTo-Json -Depth 8
    Write-TextUtf8 -Path $outPath -Lines ($json -split "`n" | ForEach-Object { $_.TrimEnd() })
    return $outPath
}

function Get-WeightsFingerprint([string]$Path) {
    # Fingerprint of only the fields the AI consumes (so _-prefixed notes do not matter).
    $obj = Read-JsonFile $Path
    $parts = @()
    foreach ($k in ((Get-OrderedScoreKeys) + (Get-FrozenScoreKeys) + (Get-PinnedScoreKeys) + (Get-RuleScoreKeys))) {
        if ($obj.PSObject.Properties.Name -contains $k) { $parts += ($k + '=' + (Format-Num (Get-Num $obj.$k) 6)) }
    }
    if ($obj.PSObject.Properties.Name -contains 'HERO_VALUE') {
        $ids = @($obj.HERO_VALUE.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object
        $hvParts = @()
        foreach ($id in $ids) { $hvParts += ($id + '=' + (Format-Num (Get-Num $obj.HERO_VALUE.$id) 6)) }
        $parts += ('HERO_VALUE{' + ($hvParts -join ',') + '}')
    }
    # Per-hero score-key sections ({ "hero_42": { "GOLD_TAKE_VALUE": 40 } }) are consumed by the AI too,
    # so they MUST enter the fingerprint -- otherwise two arms differing only in hero_42's gold values
    # would look like the same weights file.
    foreach ($pn in (@($obj.PSObject.Properties.Name) | Sort-Object)) {
        if ($pn -notmatch '^hero_[0-9]{2}$') { continue }
        $sub = $obj.$pn
        $subParts = @()
        foreach ($sk in (@($sub.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object)) {
            $subParts += ($sk + '=' + (Format-Num (Get-Num $sub.$sk) 6))
        }
        $parts += ($pn + '{' + ($subParts -join ',') + '}')
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join '|'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower().Substring(0, 16) }
    finally { $sha.Dispose() }
}

# ============================ spec / seeds / lineups ============================

function Read-TrainSpec([string]$Path) {
    $spec = Read-JsonFile $Path
    $spec.seeds.train = @($spec.seeds.train | ForEach-Object { [int]$_ })
    $spec.seeds.holdout = @($spec.seeds.holdout | ForEach-Object { [int]$_ })
    $spec.measurement.firsts = @($spec.measurement.firsts | ForEach-Object { [string]$_ })
    $spec.measurement.asides = @($spec.measurement.asides | ForEach-Object { [string]$_ })
    $inter = @($spec.seeds.train | Where-Object { $spec.seeds.holdout -contains $_ })
    if ($inter.Count -gt 0) { throw ('SEED SPLIT VIOLATION: train and holdout overlap on ' + ($inter -join ',')) }
    $dup = @($spec.seeds.train | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dup.Count -gt 0) { throw ('duplicate seeds in train set: ' + (($dup | ForEach-Object { $_.Name }) -join ',')) }
    # lineup pools must exist and be disjoint in combination space
    if (-not ($spec.PSObject.Properties.Name -contains 'lineups')) { throw 'spec.lineups missing' }
    # Candidate order for the deterministic anchor-side filler (see Get-FillHero): the whole hero universe,
    # lexicographically sorted. (hero_NN zero padding makes lexical order == numeric order.) Must exist
    # BEFORE Test-LineupPools, which already enumerates every seed through Get-SeedInfo.
    $script:FillCandidateOrder = @(Get-HeroUniverse -Spec $spec | Sort-Object)
    # Opponent-beam default for config objects that predate the beam_opp key (see Get-CfgBeamOpp).
    $script:SpecBeamOppDefault = [int]$spec.beam.opponent
    $combos = Test-LineupPools -Spec $spec
    $spec | Add-Member -NotePropertyName '_seed_intersection' -NotePropertyValue $inter.Count -Force
    $spec | Add-Member -NotePropertyName '_lineup_overlap' -NotePropertyValue $combos.Overlap -Force
    return $spec
}

function Get-Lineup([int]$Seed, [int]$Stride, [int]$Slots, [int]$PoolSize) {
    # Deterministic round-robin triple generator.
    #   round r = floor(seed / Slots), slot j = seed mod Slots
    #   members = (i*Stride + r) mod 49  for i = j, j+1, j+2
    # Every 49 consecutive slots yield all 49 heroes; each slot switches stride between rounds
    # (see Get-SeedInfo), so the 105 train lineups cover every hero at least 3 times and the
    # holdout stride set was searched so holdout lineups stay disjoint from the train ones.
    if ($PoolSize -le 0) { throw 'Get-Lineup: PoolSize must be > 0' }
    $r = [int][Math]::Floor([double]$Seed / [double]$Slots)
    $j = ((($Seed % $Slots) + $Slots) % $Slots)
    $ids = @()
    for ($i = $j; $i -le $j + 2; $i++) {
        $v = ((($i * $Stride + $r) % $PoolSize) + $PoolSize) % $PoolSize
        $ids += ('hero_{0:D2}' -f ($v + 1))
    }
    return $ids
}

function Get-LineupVersion([object]$Spec) {
    if ($Spec.lineups.PSObject.Properties.Name -contains 'version') { return [string]$Spec.lineups.version }
    return 'v1'
}

function Get-LineupPoolSet([object]$Spec) {
    # v1 (historical): one fixed anchor list, rotated by (round+slot) mod n. It CAN put the same hero
    # on both sides (measured: 23/120 train seeds), which muddies HERO_VALUE interpretation.
    # v2 (current): several small disjoint anchor pools; per seed the anchor rotates within the pool
    # whose name starts with 0 (the "primary"), passed via anchors_v2. The anchor is chosen so that it
    # shares NO hero with that seed's generated lineup, guaranteeing both sides are always disjoint.
    $out = [ordered]@{ train = @(); holdout = @() }
    foreach ($set in @('train', 'holdout')) {
        $node = $Spec.lineups.$set
        if ($node.PSObject.Properties.Name -contains 'anchors_v2') {
            $out[$set] = @($node.anchors_v2 | ForEach-Object { , @($_ | ForEach-Object { [string]$_ }) })
        } else {
            $out[$set] = @(@($Spec.lineups.anchors | ForEach-Object { [string]$_.deck }))
        }
    }
    return $out
}

function Get-HeroUniverse([object]$Spec) {
    # Every hero id the spec's deck generator can produce, derived from lineups.pool_size with the same
    # 'hero_%02d' numbering Get-Lineup uses. NOT a hard-coded table of 49 ids (hero_01..hero_49 kept
    # sorted as strings is also sorted numerically because they are zero padded).
    $n = [int]$Spec.lineups.pool_size
    if ($n -le 0) { throw 'Get-HeroUniverse: lineups.pool_size must be > 0' }
    $out = @()
    for ($i = 1; $i -le $n; $i++) { $out += ('hero_{0:D2}' -f $i) }
    return $out
}

function Get-FillHero([int]$Seed, [string[]]$Exclude) {
    # The anchor side needs exactly 3 heroes but an anchor pool holds only 2, so one deterministic filler
    # completes it. Rule (see Get-SeedInfo for why):
    #   candidates = hero universe MINUS this seed's generated lineup MINUS this seed's anchor pools,
    #                sorted lexicographically (== numerically here, ids are zero padded);
    #   pick       = candidates[seed mod candidates.Count]
    # Pure function of (seed, excluded set): re-running a seed always yields the same deck, so a
    # measurement stays reproducible. No RNG, no clock, no filesystem.
    $ex = @{}
    foreach ($h in @($Exclude)) { if ($h) { $ex[[string]$h] = $true } }
    if (-not $script:FillCandidateOrder -or $script:FillCandidateOrder.Count -eq 0) {
        throw 'Get-FillHero: $script:FillCandidateOrder is not initialised (Read-TrainSpec must run first)'
    }
    $cand = @($script:FillCandidateOrder | Where-Object { -not $ex.ContainsKey([string]$_) })
    if ($cand.Count -eq 0) { throw ('Get-FillHero: no fill candidate left for seed ' + $Seed + ' after excluding ' + ($Exclude -join ',')) }
    $idx = ((($Seed % $cand.Count) + $cand.Count) % $cand.Count)
    return [string]$cand[$idx]
}

function Assert-DeckSide([string]$Label, [int]$Seed, [string]$Deck) {
    # HARD self-check (3v3): the harness lays a deck out on P_CELLS / E_CELLS (3 slots each, see
    # RL/harness/对局.gd _setup) and indexes it directly, so a 2-hero side is an out-of-bounds crash and
    # a duplicated hero silently fields the same unit twice. Refuse to measure a lineup that cannot
    # describe a legal 3v3 board.
    $d = @($Deck -split ',' | Where-Object { $_ -ne '' })
    if ($d.Count -ne 3) { throw ('DECK SIDE SIZE: seed ' + $Seed + ' ' + $Label + ' has ' + $d.Count + ' heroes (must be exactly 3 for 3v3): [' + $Deck + ']') }
    $dup = @($d | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dup.Count -gt 0) { throw ('DECK SIDE DUP: seed ' + $Seed + ' ' + $Label + ' repeats ' + ($dup -join ',') + ' within the same side: [' + $Deck + ']') }
}

function Get-FillCovCounts([object]$Spec, [string]$Set) {
    # Which hero is the anchor-side filler, and how often, over one seed set. Report-only; the hard
    # lineup checks still run on the generated lineups (Test-LineupPools).
    $cov = @{}
    foreach ($sd in @($Spec.seeds.$Set)) {
        $i = Get-SeedInfo -Spec $Spec -Seed ([int]$sd)
        if (-not $i.fill_hero) { continue }
        $h = [string]$i.fill_hero
        if ($cov.ContainsKey($h)) { $cov[$h]++ } else { $cov[$h] = 1 }
    }
    return $cov
}

function Get-SeedInfo([object]$Spec, [int]$Seed) {
    # Single source of truth for "which lineups does this seed use, on which side, with which anchor".
    $version = Get-LineupVersion $Spec
    $slots = [int]$Spec.lineups.slots
    $poolSize = [int]$Spec.lineups.pool_size
    $r = [int][Math]::Floor([double]$Seed / [double]$slots)
    $j = ((($Seed % $slots) + $slots) % $slots)
    $ts = @($Spec.lineups.train.strides | ForEach-Object { [int]$_ })
    $hs = @($Spec.lineups.holdout.strides | ForEach-Object { [int]$_ })
    $tStride = $ts[(($r + $j) % $ts.Count)]
    $hStride = $hs[(($r + $j) % $hs.Count)]
    $trainIds = Get-Lineup -Seed $Seed -Stride $tStride -Slots $slots -PoolSize $poolSize
    $holdIds = Get-Lineup -Seed $Seed -Stride $hStride -Slots $slots -PoolSize $poolSize
    $isHold = (@($Spec.seeds.holdout) -contains $Seed)
    $gen = $(if ($isHold) { $holdIds } else { $trainIds })
    $genSide = $(if ($Seed % 2 -eq 0) { 'enemy' } else { 'player' })
    $pools = Get-LineupPoolSet -Spec $Spec
    $genPool = $(if ($isHold) { $pools.holdout } else { $pools.train })
    $anchorDeck = ''; $anchorName = ''; $shared = @(); $fillHero = ''
    if ($version -eq 'v2') {
        # A pool holds only 2 heroes, so the anchor side is completed with 1 deterministic filler:
        # 2 anchors + filler = the 3 heroes a 3v3 side needs (before this the 2-hero pool was handed to
        # the harness as a whole deck and _setup walked off the end -> "Out of bounds get index '2'").
        # Filler rule, deterministic per seed (= Get-FillHero): from the hero universe drop this seed's
        # generated lineup AND every pool of this seed's set, then take the lexicographically sorted
        # candidates[seed mod count]. Dropping the generated lineup is what keeps the disjointness proof
        # intact: generated (3) vs anchor side (2 pool heroes + a filler outside the generated lineup)
        # still share no hero, so shared_heroes stays empty and the "overlap = 0" hard check holds.
        foreach ($pool in $genPool) {
            $inter = @($pool | Where-Object { $gen -contains $_ })
            if ($inter.Count -eq 0) { $anchorDeck = ($pool -join ','); $anchorName = ($pool -join '+'); break }
        }
        if ($anchorDeck) {
            $fillHero = Get-FillHero -Seed $Seed -Exclude (@($gen) + @($genPool | ForEach-Object { $_ }))
            if (-not $fillHero) { throw ('no fill hero found for seed ' + $Seed) }
            $anchorDeck = ($anchorDeck + ',' + $fillHero)
        }
    } else {
        $anchorArr = @($Spec.lineups.anchors)
        $anchorIdx = ((($r + $j) % $anchorArr.Count) + $anchorArr.Count) % $anchorArr.Count
        $anchorDeck = [string]$anchorArr[$anchorIdx].deck
        $anchorName = [string]$anchorArr[$anchorIdx].name
    }
    if (-not $anchorDeck) { throw ('no disjoint anchor found for seed ' + $Seed) }
    $shared = @($gen | Where-Object { ($anchorDeck -split ',') -contains $_ })
    $enemyDeck = $(if ($genSide -eq 'enemy') { ($gen -join ',') } else { $anchorDeck })
    $playerDeck = $(if ($genSide -eq 'player') { ($gen -join ',') } else { $anchorDeck })
    # Self-check every side we are about to hand to the harness, at the moment it is built: 3 heroes each
    # and no hero twice inside a side. Better to abort than to measure a board the harness cannot set up.
    Assert-DeckSide -Label 'enemy_deck' -Seed $Seed -Deck $enemyDeck
    Assert-DeckSide -Label 'player_deck' -Seed $Seed -Deck $playerDeck
    return [pscustomobject]@{
        seed = $Seed; round = $r; slot = $j; version = $version
        train_stride = $tStride; holdout_stride = $hStride
        lineup_train = ($trainIds -join ','); lineup_holdout = ($holdIds -join ',')
        lineup_used = ($gen -join ','); lineup_side = $genSide
        anchor_name = $anchorName; anchor_deck = $anchorDeck; fill_hero = $fillHero
        shared_heroes = ($shared -join ',')
        enemy_deck = $enemyDeck
        player_deck = $playerDeck
        is_holdout = $isHold
    }
}

function Test-LineupPools([object]$Spec) {
    # Enumerates every lineup the configured seed sets can produce, checks train/holdout disjointness,
    # and fails loudly if any hero appears fewer than twice in the train lineup set.
    $trainCombos = @{}; $holdCombos = @{}
    $trainCov = @{}; $holdCov = @{}
    $changedCov = @{}
    foreach ($sd in @($Spec.seeds.train)) {
        $i = Get-SeedInfo -Spec $Spec -Seed ([int]$sd)
        $trainCombos[$i.lineup_train] = $true
        foreach ($h in ($i.lineup_train -split ',')) {
            if ($trainCov.ContainsKey($h)) { $trainCov[$h]++ } else { $trainCov[$h] = 1 }
            if ($changedCov.ContainsKey($h)) { $changedCov[$h]++ } else { $changedCov[$h] = 1 }
        }
    }
    foreach ($sd in @($Spec.seeds.holdout)) {
        $i = Get-SeedInfo -Spec $Spec -Seed ([int]$sd)
        $holdCombos[$i.lineup_holdout] = $true
        foreach ($h in ($i.lineup_used -split ',')) {
            if ($holdCov.ContainsKey($h)) { $holdCov[$h]++ } else { $holdCov[$h] = 1 }
            if ($changedCov.ContainsKey($h)) { $changedCov[$h]++ } else { $changedCov[$h] = 1 }
        }
    }
    $overlap = @($trainCombos.Keys | Where-Object { $holdCombos.ContainsKey($_) })
    if ($overlap.Count -gt 0) { throw ('LINEUP SPLIT VIOLATION: train/holdout share lineups: ' + ($overlap -join ' , ')) }
    # Hard check: no seed may put the same hero on both sides (v2 guarantee).
    $sharedSeeds = @()
    foreach ($sd in (@($Spec.seeds.train) + @($Spec.seeds.holdout))) {
        $i = Get-SeedInfo -Spec $Spec -Seed ([int]$sd)
        if ($i.shared_heroes) { $sharedSeeds += ($i.seed.ToString() + ':' + $i.shared_heroes) }
    }
    if ($sharedSeeds.Count -gt 0) {
        throw ('ANCHOR/GENERATED OVERLAP: ' + $sharedSeeds.Count + ' seed(s) share a hero between the two sides, e.g. ' + (($sharedSeeds | Select-Object -First 5) -join ' ; '))
    }
    $thin = @()
    for ($i = 1; $i -le [int]$Spec.lineups.pool_size; $i++) {
        $h = ('hero_{0:D2}' -f $i)
        $a = 0
        if ($trainCov.ContainsKey($h)) { $a = $trainCov[$h] }
        if ($a -lt 2) { $thin += ($h + '=' + $a) }
    }
    if ($thin.Count -gt 0) { throw ('LINEUP COVERAGE FAILURE: heroes with <2 train appearances: ' + ($thin -join ', ')) }
    return [pscustomobject]@{
        Overlap = $overlap.Count; TrainCombos = $trainCombos.Count; HoldCombos = $holdCombos.Count
        TrainCov = $trainCov; HoldCov = $holdCov; ChangedCov = $changedCov; PoolSize = [int]$Spec.lineups.pool_size
        SharedSeeds = $sharedSeeds.Count
    }
}

function Get-ScriptHashes {
    # The four scripts that define what a measurement MEANS. Every run records them so a results table
    # can never silently mix two versions of the rules/candidate.
    $cand = Join-Path $script:RepoRoot 'RL\ai\AI_Battle.gd'
    return [pscustomobject][ordered]@{
        cand = (Get-Sha256Hex12 $cand)
        base = (Get-Sha256Hex12 $script:OpponentScript)
        duel = (Get-Sha256Hex12 $script:HarnessScript)
        skil = (Get-Sha256Hex12 (Join-Path $script:RepoRoot 'RL\harness\技能对拍.gd'))
    }
}

function Get-ScriptHashString {
    $h = Get-ScriptHashes
    return ('cand=' + $h.cand + ' base=' + $h.base + ' duel=' + $h.duel + ' skil=' + $h.skil)
}

function Get-RunManifestPath([string]$Run) { return (Join-Path (Get-ResultsDir $Run) 'run_manifest.json') }

function Assert-ScriptHashes {
    <#
      Hard guard against mixing script versions inside one results table.
      First run in a run dir: write run_manifest.json.
      Later runs: compare; on mismatch THROW unless -AllowHashChange, in which case the old manifest is
      archived as run_manifest.<timestamp>.json and a fresh one is written (results are then explicitly
      segregated by the archived manifest).
      Pass -CheckOnly to inspect without touching anything (used by -Task status).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $false)][switch]$AllowHashChange,
        [Parameter(Mandatory = $false)][switch]$CheckOnly
    )
    $dir = Get-ResultsDir $Run
    $cur = Get-ScriptHashes
    $path = Get-RunManifestPath $Run
    if (-not (Test-Path -LiteralPath $path)) {
        if ($CheckOnly) { return [pscustomobject]@{ Status = 'new'; Manifest = $null; Current = $cur } }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $obj = [ordered]@{
            run = $Run
            created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            cand = $cur.cand; base = $cur.base; duel = $cur.duel; skil = $cur.skil
            note = 'Any later run whose script hashes differ must not append into this run dir.'
        }
        Write-TextUtf8 -Path $path -Lines (($obj | ConvertTo-Json -Depth 4) -split "`n" | ForEach-Object { $_.TrimEnd() })
        Write-Host ('[guard] wrote run manifest: ' + (Get-ScriptHashString))
        return [pscustomobject]@{ Status = 'created'; Manifest = $obj; Current = $cur }
    }
    $old = Read-JsonFile $path
    $same = (([string]$old.cand -eq $cur.cand) -and ([string]$old.base -eq $cur.base) -and
             ([string]$old.duel -eq $cur.duel) -and ([string]$old.skil -eq $cur.skil))
    if ($same) {
        Write-Host ('[guard] script hashes match the run manifest: ' + (Get-ScriptHashString))
        return [pscustomobject]@{ Status = 'match'; Manifest = $old; Current = $cur }
    }
    $msg = ('HASH GUARD: run "' + $Run + '" was created with ' +
            'cand=' + $old.cand + ' base=' + $old.base + ' duel=' + $old.duel + ' skil=' + $old.skil +
            ' but the scripts now are ' + (Get-ScriptHashString) +
            '. Appending would mix two versions in one measure.csv.')
    if ($CheckOnly) { return [pscustomobject]@{ Status = 'mismatch'; Manifest = $old; Current = $cur; Message = $msg } }
    if (-not $AllowHashChange) {
        throw ($msg + ' Use -AllowHashChange to archive the old manifest and continue (or use a new -Run).')
    }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    Copy-Item -LiteralPath $path -Destination (Join-Path $dir ('run_manifest.' + $stamp + '.json')) -Force
    $obj = [ordered]@{
        run = $Run
        created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        cand = $cur.cand; base = $cur.base; duel = $cur.duel; skil = $cur.skil
        supersedes = (Split-Path -Leaf ($path))
        note = ('Script hashes changed; previous manifest archived as run_manifest.' + $stamp + '.json. Rows measured before this point belong to the archived version.')
    }
    Write-TextUtf8 -Path $path -Lines (($obj | ConvertTo-Json -Depth 4) -split "`n" | ForEach-Object { $_.TrimEnd() })
    Write-Host ('[guard] HASH CHANGE ACCEPTED: archived old manifest as run_manifest.' + $stamp + '.json ; now ' + (Get-ScriptHashString))
    return [pscustomobject]@{ Status = 'changed'; Manifest = $obj; Current = $cur }
}

function Get-RunHashStatus([string]$Run) {
    return (Assert-ScriptHashes -Run $Run -CheckOnly)
}

function Get-LineupCoverageReport([object]$Spec) {
    $c = Test-LineupPools -Spec $Spec
    $lines = @()
    $strideCount = @($Spec.lineups.train.strides).Count
    $lines += ('- lineups.slots = ' + $Spec.lineups.slots + ', pool_size = ' + $c.PoolSize + ', strides per round = ' + $strideCount)
    $lines += ('- distinct lineups: train=' + $c.TrainCombos + ', holdout=' + $c.HoldCombos + ', overlap=' + $c.Overlap + ' (must be 0)')
    $lines += ('- train strides: ' + (@($Spec.lineups.train.strides) -join ',') + ' ; holdout strides: ' + (@($Spec.lineups.holdout.strides) -join ','))
    $lines += ('- lineup version = ' + (Get-LineupVersion $Spec))
    $pools = Get-LineupPoolSet -Spec $Spec
    $lines += ('- anchor pools (the side that does NOT get the generated lineup): train=' +
               (($pools.train | ForEach-Object { '[' + ($_ -join '+') + ']' }) -join ' ') + ' ; holdout=' +
               (($pools.holdout | ForEach-Object { '[' + ($_ -join '+') + ']' }) -join ' '))
    $lines += ('- anchor/generated hero overlap across all 144 seeds: ' + $c.SharedSeeds + ' (hard failure if > 0)')
    $lines += ('- anchor side = 2 pool heroes + 1 filler (deterministic: candidates = universe minus that ' +
               'seed''s generated lineup minus that seed''s pools, sorted; pick = candidates[seed mod count]). ' +
               'Filler never enters the generated lineup, so it cannot create anchor/generated overlap.')
    $fillTrain = Get-FillCovCounts -Spec $Spec -Set 'train'
    $fillHold = Get-FillCovCounts -Spec $Spec -Set 'holdout'
    if ($fillTrain.Count -gt 0 -or $fillHold.Count -gt 0) {
        $fk = @(@($fillTrain.Keys) + @($fillHold.Keys) | Sort-Object -Unique)
        $lines += ('- filler rotation: ' + ($fk.Count) + ' distinct filler(s) over ' +
                   (@($Spec.seeds.train).Count) + ' train + ' + (@($Spec.seeds.holdout).Count) + ' holdout seeds: ' +
                   (($fk | ForEach-Object {
                        $h = $_
                        $a = 0; if ($fillTrain.ContainsKey($h)) { $a = $fillTrain[$h] }
                        $b = 0; if ($fillHold.ContainsKey($h)) { $b = $fillHold[$h] }
                        $h + '=' + $a + ' train/' + $b + ' holdout'
                     }) -join ', '))
    }
    $minCov = 9999; $minHero = ''
    for ($i = 1; $i -le $c.PoolSize; $i++) {
        $h = ('hero_{0:D2}' -f $i)
        $a = 0
        if ($c.TrainCov.ContainsKey($h)) { $a = $c.TrainCov[$h] }
        if ($a -lt $minCov) { $minCov = $a; $minHero = $h }
    }
    $lines += ('- train-lineup coverage: min=' + $minCov + ' (' + $minHero + '); the >=2 rule is a hard failure')
    $zero = @()
    for ($i = 1; $i -le $c.PoolSize; $i++) {
        $h = ('hero_{0:D2}' -f $i)
        if (-not $c.ChangedCov.ContainsKey($h)) { $zero += $h }
    }
    $lines += ('- heroes never appearing in any train or holdout lineup: ' + $(if ($zero.Count -eq 0) { 'none' } else { $zero -join ', ' }))
    $lines += ('- total distinct heroes seen during training: ' + $c.ChangedCov.Count + ' of ' + $c.PoolSize)
    return [pscustomobject]@{ Lines = $lines; Coverage = $c }
}

function Get-LineupCoverageTable([object]$Spec) {
    $c = Test-LineupPools -Spec $Spec
    $fTrain = Get-FillCovCounts -Spec $Spec -Set 'train'
    $fHold = Get-FillCovCounts -Spec $Spec -Set 'holdout'
    $lines = @()
    # "in train lineups" counts the GENERATED lineups (the hard >=2 rule). "as filler" counts how many
    # seeds rotate this hero onto the anchor side as the 3rd hero - not part of the >=2 rule.
    $lines += '| hero | in train lineups | in holdout lineups | total | as filler (train) | as filler (holdout) |'
    $lines += '|---|---|---|---|---|---|'
    for ($i = 1; $i -le $c.PoolSize; $i++) {
        $h = ('hero_{0:D2}' -f $i)
        $a = 0; $b = 0; $t = 0; $fa = 0; $fb = 0
        if ($c.TrainCov.ContainsKey($h)) { $a = $c.TrainCov[$h] }
        if ($c.HoldCov.ContainsKey($h)) { $b = $c.HoldCov[$h] }
        if ($c.ChangedCov.ContainsKey($h)) { $t = $c.ChangedCov[$h] }
        if ($fTrain.ContainsKey($h)) { $fa = $fTrain[$h] }
        if ($fHold.ContainsKey($h)) { $fb = $fHold[$h] }
        $lines += ('| ' + $h + ' | ' + $a + ' | ' + $b + ' | ' + $t + ' | ' + $fa + ' | ' + $fb + ' |')
    }
    return $lines
}

function Get-HoldoutGuard([string]$SeedSet, [bool]$Ack) {
    # The holdout seed set and the holdout lineup pool may be examined only once, for final acceptance.
    if ($SeedSet -eq 'holdout' -and -not $Ack) {
        throw 'REFUSED: -SeedSet holdout requires -IKnowThisIsHoldout. The holdout set may be used only once, for final acceptance.'
    }
}

function Enter-RunLock([string]$Run, [int]$StaleMinutes = 30) {
    # Two concurrent writers to the same results directory would interleave measure.csv rows.
    # A stale lock (older than $StaleMinutes) is reported, never silently deleted.
    $dir = Get-ResultsDir $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lock = Join-Path $dir 'RUNNING.lock'
    if (Test-Path -LiteralPath $lock) {
        $content = [System.IO.File]::ReadAllText($lock)
        $age = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes
        throw ('RUN LOCK: ' + $lock + ' exists (age ' + (Format-Num $age 1) + ' min, content: ' + $content + '). Another run may be active; remove the lock only if you are sure it is stale.')
    }
    [System.IO.File]::WriteAllText($lock, ('pid=' + $PID + ' started=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' run=' + $Run), (New-Object System.Text.UTF8Encoding($false)))
    return $lock
}

function Exit-RunLock([string]$LockPath) {
    if ($LockPath -and (Test-Path -LiteralPath $LockPath)) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}

function Get-ConfigByName([object]$Spec, [string]$Name) {
    $hit = @($Spec.configs | Where-Object { [string]$_.name -eq $Name })
    if ($hit.Count -ne 1) { throw ('config not found in spec: ' + $Name) }
    return $hit[0]
}

function Resolve-Configs([object]$Spec, [string[]]$Names, [string]$Run) {
    # Materialises RL/weights/cand_<Run>_<Config>.json for every config that carries a theta overlay
    # (or points at an existing weights file) and returns the run-ready config objects.
    $basePath = Join-Path $script:RepoRoot $Spec.base_weights
    $out = @()
    foreach ($n in $Names) {
        $c = Get-ConfigByName -Spec $Spec -Name $n
        $theta = $null
        if ($c.PSObject.Properties.Name -contains 'theta') { $theta = $c.theta }
        $hasWeights = ($c.PSObject.Properties.Name -contains 'weights') -and ($c.weights)
        if ($hasWeights) {
            $wf = Join-Path $script:RepoRoot ([string]$c.weights)
        } else {
            $note = ''
            if ($c.PSObject.Properties.Name -contains 'note') { $note = [string]$c.note }
            $wf = New-CandidateWeights -BasePath $basePath -Name ($Run + '_' + $n) -Theta $theta -Note $note
        }
        if (-not (Test-Path -LiteralPath $wf)) { throw ('resolved weights file does not exist: ' + $wf) }
        # Per-config beam (optional): lets ONE run compare beam arms using an identical weights file,
        # which is exactly what the injection check and the speed sweep need. `beam` is the candidate
        # side, `beam_opp` the opponent side (both validated by Get-ConfigBeamSpec).
        $beams = Get-ConfigBeamSpec -Spec $Spec -CfgObj $c
        $out += [pscustomobject]@{ name = $n; weights_file = $wf; base = $basePath; theta = $theta
                                   beam = [int]$beams.candidate; beam_opp = [int]$beams.opponent }
    }
    return $out
}

function Get-SeedLineupSummary([object]$Spec, [int]$Seed) {
    return (Get-SeedInfo -Spec $Spec -Seed $Seed)
}

# ============================ process control ============================

function Wait-GodotSlot {
    param([int]$MaxRounds = 20, [int]$SleepSeconds = 30, [string]$Tag = '', [int]$MaxSlots = 0)
    # Overridable via env so a long experiment can wait through several of another tool's shorter
    # runs instead of aborting after a fixed 20 rounds (default stays 20 x 30s = 10 min).
    if ($env:RL_SLOT_ROUNDS) { $MaxRounds = [int]$env:RL_SLOT_ROUNDS }
    if ($env:RL_SLOT_SLEEP_S) { $SleepSeconds = [int]$env:RL_SLOT_SLEEP_S }
    # 【2026-09-21 用户批准「多开几个线程」】原来这里是**全局单槽**：只要还有**任何一个**无窗口
    #   Godot 在跑就不放行 ⇒ 8 条并行链被串行化，全机同时只有 1 个在算（实测 1.5 配对/分钟，
    #   而 8 条链本该 8 倍）。现在改成**多槽**：并发数 < `MaxSlots` 就放行。
    #   `MaxSlots` 取值顺序：显式参数 → `$env:RL_SLOT_MAX` → **1**（= 改动前的行为，逐位不变）。
    #   要提速就设 `RL_SLOT_MAX=<并发数>`（8 条链 ⇒ 设 8~10；12 核机器建议 ≤10，给用户留核）。
    if ($MaxSlots -le 0) {
        if ($env:RL_SLOT_MAX) { $MaxSlots = [int]$env:RL_SLOT_MAX } else { $MaxSlots = 1 }
    }
    for ($i = 1; $i -le $MaxRounds; $i++) {
        $all = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue)
        # 【2026-09-19 改·用户批准"自动"】原来靠一个**写死的**"用户编辑器 pid"（25124，早就失效）
        #   来把它排除在冲突之外。现在改成**动态判据**：`MainWindowTitle` 非空的 Godot =
        #   用户的编辑器 / 正在跑的游戏窗口（不抢槽位、只在日志里报告）；无窗口的 =
        #   我们自己的 headless 跑批（算冲突）。
        $userWin = @($all | Where-Object { $_.MainWindowTitle -and ([string]$_.MainWindowTitle).Length -gt 0 })
        $foreign = @($all | Where-Object { -not ($_.MainWindowTitle -and ([string]$_.MainWindowTitle).Length -gt 0) })
        if ($foreign.Count -lt $MaxSlots) {
            $uw = ($userWin | ForEach-Object { [string]$_.Id + ':' + $_.MainWindowTitle }) -join ' ; '
            Write-Host ('[slot] free (round ' + $i + '; running ' + $foreign.Count + '/' + $MaxSlots + '); user windows ignored: ' + $(if ($uw) { $uw } else { '(none)' }))
            return $true
        }
        $desc = ($foreign | ForEach-Object { [string]$_.Id + ':' + $_.MainWindowTitle }) -join ' ; '
        Write-Host ('[slot] round ' + $i + '/' + $MaxRounds + ' busy (' + $foreign.Count + '/' + $MaxSlots + ') -> ' + $desc + ' ; sleeping ' + $SleepSeconds + 's ' + $Tag)
        Start-Sleep -Seconds $SleepSeconds
    }
    return $false
}

function Get-NewGodotPids([int[]]$Before) {
    $now = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    return @($now | Where-Object { $Before -notcontains $_ })
}

function Invoke-GodotBatch {
    param(
        [Parameter(Mandatory = $true)][int[]]$Seeds,
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $false)][string]$EDeck = '-',
        [Parameter(Mandatory = $false)][string]$PDeck = '-',
        [Parameter(Mandatory = $true)][string]$WeightsA,
        [Parameter(Mandatory = $false)][string]$WeightsB = '-',
        [Parameter(Mandatory = $false)][int]$BeamA = 1200,
        [Parameter(Mandatory = $false)][int]$BeamB = 800,
        [Parameter(Mandatory = $false)][string]$Opp = 'base',
        [Parameter(Mandatory = $true)][string]$LogBase,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 3600,
        [Parameter(Mandatory = $false)][string]$AppData = '',
        [Parameter(Mandatory = $false)][switch]$SkipSlotWait,
        # Batch-instance token of the CALLER (see Get-MeasureHeader). Regenerated here when absent so a
        # direct call still yields a distinguishable instance.
        [Parameter(Mandatory = $false)][string]$InvToken = ''
    )
    if (-not $InvToken) { $InvToken = New-InvToken }
    if ($Seeds.Count -eq 0) { throw 'Invoke-GodotBatch: empty seed list' }
    if (-not $SkipSlotWait) {
        if (-not (Wait-GodotSlot -Tag ('for ' + [System.IO.Path]::GetFileName($LogBase)))) {
            throw 'Invoke-GodotBatch: no free Godot slot after 20 rounds; aborted without starting anything'
        }
    }
    $seed0 = ($Seeds | Measure-Object -Minimum).Minimum
    # 【2026-09-18 新增】`--disable-crash-handler`：用户报告"老是弹 Godot 应用程序错误 / 该内存不能为 read"，
    # 影响到他用电脑 ⇒ 从这条路径起的 Godot **一律不带崩溃处理器的弹窗**（日志照旧写进 .godot.log）。
    # 这不是掩盖问题：崩溃仍然会记录，只是不再弹窗打断用户。
    $argv = @('--headless', '--disable-crash-handler', '--path', $script:RepoRoot,
              '--log-file', ($LogBase + '.godot.log'),
              '--scene', $script:HarnessScene, '--',
              [string]$Seeds.Count, [string]$seed0, $EDeck, $PDeck, $WeightsA, $WeightsB,
              [string]$BeamA, [string]$BeamB, $Opp, $First)
    $inner = '"' + $script:GodotExe + '" ' + (Format-Argv $argv) + ' > "' + ($LogBase + '.out') + '" 2>&1'
    Write-Host ('[godot] start seeds=' + $seed0 + '..' + ($seed0 + $Seeds.Count - 1) + ' first=' + $First + ' opp=' + $Opp + ' beamA=' + $BeamA + ' e=' + $EDeck + ' p=' + $PDeck)
    $tagFile = $LogBase + '.jobpid'
    $godotPidFile = $LogBase + '.godotpid'
    $appDataDir = $AppData
    $job = Start-Job -ScriptBlock {
        param($innerCmd, $tagPath, $pidPath, $sandbox)
        [System.IO.File]::WriteAllText($tagPath, [string]$PID)
        if ($sandbox) {
            # Per-worker APPDATA => Godot resolves an ISOLATED user:// dir. Without it, concurrent
            # instances fight over the same user:// logs (previously seen as a signal 11 crash).
            if (-not (Test-Path -LiteralPath $sandbox)) { New-Item -ItemType Directory -Force -Path $sandbox | Out-Null }
            $env:APPDATA = $sandbox
            $env:LOCALAPPDATA = $sandbox
        }
        # Record the EXACT Godot pid as soon as cmd spawns it, so a timeout kills precisely this
        # process - never one picked by name or by start time.
        # 引号：`Start-Process -ArgumentList` 会把"含空格的项"再包一层引号、并把内部引号转义成 `\"`，
        # 而 cmd.exe 不认 `\"` → 报 "The filename, directory name, or volume label syntax is incorrect."，
        # Godot 根本没被拉起来：`.out` 0 字节、退出码空、每批 "produced 0 game rows (exit=-1)"，而且**不报错**。
        # （实测：同一串命令用 `& cmd /c $inner` 直调完全正常，只有经 Start-Process 才会坏。）
        # 修法同 `RL/stats/collect_stats.ps1`：整条命令**再包一层引号**交给 cmd（`cmd /c "…"`）。
        $p = Start-Process -FilePath (Get-Command cmd).Source -ArgumentList '/c', ('"' + $innerCmd + '"') -NoNewWindow -PassThru
        while (-not $p.HasExited) {
            $kids = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $p.Id) -ErrorAction SilentlyContinue)
            foreach ($k in $kids) {
                if ($k.Name -like 'Godot*') { [System.IO.File]::WriteAllText($pidPath, [string]$k.ProcessId); break }
            }
            Start-Sleep -Milliseconds 250
        }
        return $p.ExitCode
    } -ArgumentList $inner, $tagFile, $godotPidFile, $appDataDir
    $t0 = Get-Date
    $done = Wait-Job -Job $job -Timeout $TimeoutSec
    if (-not $done) {
        # Kill ONLY the pids this batch recorded itself (its own Godot child + its own job host).
        Write-Host ('[godot] TIMEOUT after ' + $TimeoutSec + 's; cleaning up only this batch (recorded pids)')
        if (Test-Path -LiteralPath $godotPidFile) {
            $gpid = 0
            [void][int]::TryParse(([System.IO.File]::ReadAllText($godotPidFile)).Trim(), [ref]$gpid)
            if ($gpid -gt 0) {
                Write-Host ('[godot] stopping own godot pid ' + $gpid)
                Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $tagFile) {
            $hostPid = 0
            [void][int]::TryParse(([System.IO.File]::ReadAllText($tagFile)).Trim(), [ref]$hostPid)
            if ($hostPid -gt 0) {
                Write-Host ('[godot] stopping own job host pid ' + $hostPid)
                Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue
            }
        }
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw ('Invoke-GodotBatch: timeout after ' + $TimeoutSec + 's; batch cleaned up, rerun the same command to resume')
    }
    $exit = -1
    try {
        $vals = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        if ($vals.Count -gt 0) { $exit = [int]$vals[$vals.Count - 1] }
    } catch { $exit = -1 }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $wall = ((Get-Date) - $t0).TotalSeconds
    $outPath = $LogBase + '.out'
    $stdout = ''
    if (Test-Path -LiteralPath $outPath) { $stdout = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8) }
    Write-Host ('[godot] done exit=' + $exit + ' wall=' + (Format-Num $wall 1) + 's out_bytes=' + $stdout.Length)
    return [pscustomobject]@{
        ExitCode = $exit; OutPath = $outPath; LogPath = ($LogBase + '.godot.log')
        WallSec = $wall; Stdout = $stdout; Seeds = $Seeds; First = $First
    }
}

# ============================ parsing ============================

function ConvertFrom-RmLine([string]$Line, [int]$LineNo) {
    $kv = [ordered]@{}
    foreach ($tok in ($Line -split '\|')) {
        $i = $tok.IndexOf('=')
        if ($i -gt 0) { $kv[$tok.Substring(0, $i)] = $tok.Substring($i + 1) }
    }
    $kv['_line_no'] = $LineNo
    $kv['_raw'] = $Line
    return [pscustomobject]$kv
}

function Read-RowsFromText([string]$Text) {
    $rows = [ordered]@{ cfg = @(); m = @(); summary = @(); warn = @() }
    $no = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $no++
        if (-not $line.StartsWith('R|')) { continue }
        if ($line.StartsWith('R|m|')) { $rows.m += (ConvertFrom-RmLine $line $no) }
        elseif ($line.StartsWith('R|SUMMARY|')) { $rows.summary += (ConvertFrom-RmLine $line $no) }
        elseif ($line.StartsWith('R|cfg|')) { $rows.cfg += (ConvertFrom-RmLine $line $no) }
        else { $rows.warn += $line }
    }
    return [pscustomobject]$rows
}

function Get-ResultsDir([string]$Run) { return (Join-Path (Join-Path $script:RepoRoot 'RL\train\results') $Run) }

function Get-CfgBeamOpp([object]$Cfg) {
    # Effective opponent-side beam of an already-resolved config. Normally $Cfg.beam_opp (set by
    # Resolve-Configs / Resolve-OneConfig from the config's beam_opp or the spec's beam.opponent).
    # When the property is absent the config predates beam_opp, and the spec default is the only safe
    # value to fall back to - it must never silently become the CANDIDATE beam ($Cfg.beam).
    if ($null -eq $Cfg) { throw 'Get-CfgBeamOpp: null config' }
    if ($Cfg.PSObject.Properties.Name -contains 'beam_opp' -and [int]$Cfg.beam_opp -gt 0) { return [int]$Cfg.beam_opp }
    return [int]$script:SpecBeamOppDefault
}

function Get-ConfigBeamSpec([object]$Spec, [object]$CfgObj) {
    # Effective beams for one config entry: the candidate side (beamA) and the opponent side (beamB).
    #   beam      : optional per-config override of Spec.beam.candidate  (pre-existing behaviour)
    #   beam_opp  : optional per-config override of Spec.beam.opponent   (new; the opponent side is the
    #               most expensive side of a game, and 800 in the spec was only ever a guess)
    # Both are validated here so a typo in train_spec.json fails at resolve time, naming the config,
    # instead of silently measuring a different workload than the one that was intended.
    $beams = [ordered]@{ candidate = [int]$Spec.beam.candidate; opponent = [int]$Spec.beam.opponent }
    $names = @($CfgObj.PSObject.Properties.Name)
    # NOTE: `-ne $null`, not truthiness. `... -and $CfgObj.beam_opp` reads beam_opp=0 as "not set" and
    # silently falls back to the spec default, so an explicit 0 sailed straight past the validation below.
    if (($names -contains 'beam') -and ($null -ne $CfgObj.beam)) { $beams.candidate = [int]$CfgObj.beam }
    if (($names -contains 'beam_opp') -and ($null -ne $CfgObj.beam_opp)) { $beams.opponent = [int]$CfgObj.beam_opp }
    $bad = @()
    foreach ($k in @('candidate', 'opponent')) {
        $v = [int]$beams[$k]
        if ($v -le 0) { $bad += ($k + '=' + $v + ' (must be > 0)'); continue }
        if (($v % 25) -ne 0) { $bad += ($k + '=' + $v + ' (must be a positive multiple of 25; the beam sweep uses 50/100/200/400/800)') }
    }
    if ($bad.Count -gt 0) {
        throw ('BEAM CONFIG: config "' + [string]$CfgObj.name + '" has ' + ($bad -join '; ') +
               ' -- fix train_spec.json (`beam` = candidate side, `beam_opp` = opponent side, or the spec defaults beam.candidate/beam.opponent)')
    }
    return [pscustomobject]$beams
}

function ConvertFrom-BeamToken([string]$Audit) {
    # Reads the candidate beam and the opponent beam back out of an audit string.
    #   new format (>= this revision): 'beam=400 beamB=800'
    #   old format                    : 'beam=400'  -> opponent unknown, callers fall back to the spec
    $b = 0; $bo = 0
    $m = [regex]::Match([string]$Audit, '(?:^|\s)beam=(\d+)')
    if ($m.Success) { $b = [int]$m.Groups[1].Value }
    $m2 = [regex]::Match([string]$Audit, '(?:^|\s)beamB=(\d+)')
    if ($m2.Success) { $bo = [int]$m2.Groups[1].Value }
    return [pscustomobject]@{ beam = $b; beam_opp = $bo }
}

function Get-MeasureHeader {
    # Keep in sync with the ordered hashtable built in Start-MeasureRun (33 columns).
    # opp / wB_sha are the opponent identity (base | cand) and, for self-play, the checkpoint's sha12.
    # inv identifies the BATCH INSTANCE. The same batch file name is reused every time the same cell is
    # measured (re-measure after a weights/harness change, resume, -Force), so without it neither the
    # append-only raw log nor the derived table can tell an old measurement of a cell from a new one.
    return 'run,config,weights_file,weights_fp,seed,round,first,a_side,lineup_used,lineup_side,res,killsA,killsB,rounds,ptsA,ptsB,dmgA,dmgB,hpA,hpB,over,subA,subB,batch_out,batch_wall_s,seq,line_no,weights_sha12,beam_opp,opp,wB_sha,inv,audit'
}

function Get-AuditString([object]$Meta, [string]$Opp = '', [string]$WB = '', [int]$BeamBOverride = 0) {
    # Auditable one-liner: which weights file (by content hash) plus the effective numeric knobs.
    # The harness's R|cfg| line does not print these and 对局.gd is frozen, so the driver records them
    # to the raw log header and to measure.csv.
    # $Opp/$WB/$BeamBOverride describe THIS cell: the opponent arm and its beam are decided per cell
    # (league self-play runs the mirror match at the candidate beam), while $Meta describes the
    # candidate weights, which every cell of a config shares.
    if ($null -eq $Meta) { return '' }
    $sh = $Meta.script_hash
    # Property lookup MUST go through PSObject.Properties: on a PSCustomObject that lacks the property,
    # a plain `$Meta.opp` raises PropertyNotFoundException, and that killed a worker mid-run (the
    # payload's flattened meta does not carry opp/wB_sha - the caller passes them explicitly here).
    $mNames = @($Meta.PSObject.Properties.Name)
    $oppS = $Opp
    if (-not $oppS) { if ($mNames -contains 'opp') { $oppS = [string]$Meta.opp } }
    $wbS = $WB
    if (-not $wbS) { if ($mNames -contains 'wB_sha') { $wbS = [string]$Meta.wB_sha } }
    $beamBS = [string]$Meta.beam_opp
    if ($BeamBOverride -gt 0) { $beamBS = [string]$BeamBOverride }
    # beamB= is appended AFTER 'beam=' so an existing `beam=(\d+)` parser still reads the candidate beam;
    # it is the effective opponent beam (config beam_opp, else spec beam.opponent) and it is what makes a
    # row attributable to a beam sweep arm. Older logs simply lack the token.
    # opp= / wB= identify WHICH OPPONENT produced the row: opp=base is the fixed difficulty-2 copy,
    # opp=cand is self-play against the league checkpoint, and wB is that checkpoint's sha12 (empty for
    # base). Appended so every existing `beam=`/`beamB=` parser keeps working.
    return ('w=' + $Meta.sha12 + ' beam=' + $Meta.beam + ' beamB=' + $beamBS +
            ' opp=' + $oppS + ' wB=' + $wbS +
            ' jitter=' + (Format-Num $Meta.jitter 1) +
            ' kill=' + (Format-Num $Meta.kill_bonus 1) + ' focus=' + (Format-Num $Meta.focus_fire 1) +
            ' threat=' + (Format-Num $Meta.threat 2) +
            ' vip=' + (Format-Num $Meta.vip 2) +
            ' hv=' + $Meta.hero_value_n + '/' + $Meta.hero_value_changed + ' entries=' + $Meta.entries +
            $(if ($sh) { ' scripts[' + $sh + ']' } else { '' }))
}

function Get-FrozenScoreKeys {
    # 被 set_weights 接受、但**故意不给训练器调**的键（2026-09-15）。
    # KILL_BONUS：实测"改了也不改出招"（探针零翻盘 + 游戏臂逐字节相同），用户要求
    # "噩梦和噩梦+ 直接把它删掉，免得影响训练" ⇒ 噩梦权重里钉死 0、任何臂都不许改它。
    # SELF_DEATH_W：同一类（探针专属场景 ×0~×15 零翻盘），且罚款只有 −4/−8/−12，
    # 比"单位死掉 → 身价项整项消失"那笔自动 −20 小 4~6 倍；用户 2026-09-15 选 B ——
    # 噩梦/噩梦+ 也设 0 + 退出训练空间（生产三档仍是 4.0）。
    # VALUE_STUN_FOLD / VALUE_SILENCE_FOLD：用户 2026-09-15「状态折减的键删掉」——
    # 这两项是"被控敌人身价 ×0.4/×0.6"，**折减类的"删掉" = 设 1.0**（乘 1 = 机制不存在）；
    # 探针只在 ×2.5 以上、且只对带控阵容才偶发翻盘，臂 shj_nofold 无显著（生产三档仍 0.4/0.6）。
    # 它们仍要进**权重指纹**（下面 Get-WeightsFingerprint 会把两份清单合起来算），
    # 否则"只差这些键的两个权重文件"会被当成同一份。
    # 【2026-09-19 变更·用户批准】`KILL_BONUS` / `SELF_DEATH_W` **已从引擎整项删除**（冗余计价，见 §14#108），
    #   所以冻结清单 4 → **2**：只剩两个状态折减（它们仍是「噩梦/噩梦+ 设 1.0、生产三档 0.4/0.6」的分档手段）。
    # 【2026-09-19 变更·用户决定】VALUE_STUN_FOLD / VALUE_SILENCE_FOLD **也已从引擎整项删除**
    #   （用户原话：「噩梦没有的，那三个档位也不应该有」）⇒ 冻结清单 **2 → 0**，这份清单现在为空。
    #   保留本函数是为了指纹与 -notcontains 判断的形状一致；将来若又出现'只许文件写、不许臂改'的键，往这里加。
    return @()
}

function Get-RuleScoreKeys {
    # 规则 A/B/C 的开关与参数（2026-09-15 用户定；见 `src/BattleAI.gd` 文件头的常量块）。
    # 它们是"硬裁决/硬约束"，**不参与自动搜索**（不进 Get-OrderedScoreKeys），但：
    #   ① 允许在 spec 的 theta 里**显式点名**（这样才能跑"A 开 vs A 关"这类配对臂——评估规则的正确方式）；
    #   ② 必须进**权重指纹** —— 否则"只差规则开关的两份权重文件"会被当成同一份。
    # 2026-09-18 追加 VALUE_IMPORTANCE_POW：身价乘法化（用户：「身价得是乘法吧？加法会被其他分数给稀释…
    #   身价一点都不重要。但我觉得身价非常重要」）。默认 0 = 关闭 ⇒ 生产三档逐位不变；
    #   它是**连续参数**（要扫 0/1/2/3），所以走"显式点名"这条通道，不进自动搜索。
    # 【2026-09-20 用户拍板·已删】原 'FOCUS_KILL_RULE' / 'FOCUS_NET_MARGIN'（规则 A：合力可杀净收益）、
    #   'EVADE_NETWORK_BONUS' / 'NEXT_TURN_THREAT_W'（规则 B 的另两条）—— 四个都判死，键与代码一起删除。
    return @('MOVE_ACCEPT_DAMAGE',
             'SUB_JOIN_RULE',
             # 2026-09-18 追加：结局量（用户第 2/3 条「本回合输出与下回合被输出的最优平衡」
             # 「被输出尽量分摊、优先保护核心、用肉盾抗伤害」）。都默认 0 = 关闭 ⇒ 生产逐位不变。
             # TERMINAL_W = 终局项（判负线凸曲线）· RISK_W = ⑦位置暴露（max 型）· RISK_CORE_POW = 其中的核心指数
             # ⑦ 于 2026-09-20 第三轮随分摊族删过，2026-09-21 按用户拍板 A 恢复（输入换成「挨打合计」）。
             'TERMINAL_W', 'RISK_W', 'RISK_CORE_POW',
             # 2026-09-21 追加：**"我方挨打按血量池折算"**（用户：「一个 2 的坦克不敢打 4 攻的输出，
             #   但实际坦克的血多，不一定亏」）⇒ 倍率 = 1 + INCOMING_POOL_W × (20 ÷ 当前血 − 1)，
             #   只作用在 ③血量账的**我方掉血**那一侧（打出去那侧已有 ④集火 frac² 计价）。默认 0 = 关。
             'INCOMING_POOL_W',
             # 用户：「如何确定核心，靠的是这个公式」+ 探针实测"那条公式三项里两项是空的" ⇒
             # 核心改由**威胁**算（`_outgoing_threat_on`，0 手写表）。默认 0 = 现状。
             # 2026-09-19 追加（学棋类/围棋 AI 的架构）：判负线意识 + **对手最优反击一层**。
             #   RISK_DEATH_MULT = 判负线乘子（乘在风险罚上：我方存活 3/2/1 ⇒ ×1/×(1+m)/×(1+2m)）
             #   REPLY_TOPK / REPLY_W = 束搜索收敛后对**最终候选前 K 条**做"对手贪心一层"推演并重排
             # 都默认 0 = 关闭 ⇒ 生产三档逐位不变。
             # 2026-09-19 追加（今晚的**主杠杆**）：**并列裁决层**。
             # 探针实测：83% 的局面"最优 vs 次优"分差 < 0.5、中位 margin = 0.000 ⇒
             # AI 的行为大半由"并列时怎么破"决定，而现有裁决只有规则 A（+0.20 n.s.）。
             # TIEBREAK_MODE = 1/2（结局量字典序；2 = 再带威胁差）· TIEBREAK_EPS = 多小算并列。
             'TIEBREAK_MODE', 'TIEBREAK_EPS',
             # 【2026-09-22 晚·已删】原来这里还有 `'ROLLOUT_TOPK', 'ROLLOUT_MODE'`（"下一回合真推演"
             #   终选层）：剂量批 16/32 都与关打平（−1.72 / −1.74，CI 跨 0）、实机又验出它把
             #   「对面会来打我们」判成 0（过度乐观）⇒ 用户拍板**整段删除**（引擎那一段已删干净）
             #   ⇒ 键从规则表移除：规则键 31 → 29、可注入 39 → 37。依据见 progress_tracking §四登记表。
             # 2026-09-19 追加：**吃矿的机会成本系数**（用户选的口径）。
             #   `矿的净价值 = 矿分 − GOLD_OPPORTUNITY_W × (这一手若改为攻击能造成的价值)`；
             #   只有能捡矿的单位（hero_42 黄金矿工）会走这段，但键放在通用表里方便注入。
             #   默认 0 = 关 ⇒ 生产三档逐位不变。
             'GOLD_OPPORTUNITY_W',
             # 2026-09-19 追加：A 档英雄特化项（毒蛇/宿魂/装甲堡垒/古拉），全默认 0 = 关
             'POISON_TICK_VALUE',
             # 2026-09-20 追加（T6）：**『这一击新挂上毒』的动作收益**（只在目标原本没毒时计数 +1）。
             #   与 POISON_TICK_VALUE（计价『敌人身上有毒』这个状态）互补：一个付状态钱、一个付动作钱。默认 0 = 关。
             'POISON_APPLY_W', 'POSSESS_TARGET_W', 'SOLID_HOLD_W',
             # 【2026-09-21 追加·B 档英雄特化（用户拍板：做沉默 / 荆棘树人打远程后勤 / 战锤克毒蛇）】
             #   三个键都是**动作量**：由 `_apply` 在我方命中那一刻累加（`sim.silence_val` / `pin_val` /
             #   `paralyze_val`）、`_evaluate` 直接入账，价钱按**施加者**英雄段覆盖读（`_wh`）⇒
             #   值写在 `噩梦.json` 的 `hero_34` / `hero_49` / `hero_25` 段里，扁平键只是兜底（默认 0 = 关）。
             #   为什么要新键：⑥⑦ 估的是「它这回合能打出多少伤害」，而这三件事关掉的是**结构上读不到的那部分**
             #   （放不出技能 / 走不动 / 攻击力归零导致命中附带机制失效）⇒ 详见 `src/BattleAI.gd` 的
             #   `const SILENCE_VALUE_W` 那块说明。规则键 22 → 26。
             'SILENCE_VALUE_W', 'THORN_PIN_SUP_W', 'THORN_PIN_RANGED_W', 'PARALYZE_ZERO_W',
             # 【2026-09-20·用户拍板】原 'LEECH_TRIGGER_W'（古拉 hero_14 的"触发吸血补一笔"）**已判死删除**：
             #   3 队 × 3 个值的棋力批越调越负（−0.56 / −1.83 / −3.70，胜率 0.39→0.33）⇒ 连引擎代码一起
             #   删干净（规则键 41 → 40）。权重文件 / theta 里再写它会落到 `set_weights` 的未知键分支、静默忽略。
             # 2026-09-19 追加：**推进停止线**（口径 A，用户选）—— 用户实测「开局 AI 不顾一切往前冲，
             # 冲到前面，到我的回合可以给他重创」。0 = 关（默认，逐位不变）/ 1 = 拉力只推到"对方下回合
             # 够不到"的那一格（`opp_reach + 1`）为止，只有这一回合真能打到人时才进威胁圈。0 参数规则。
             # 2026-09-19 追加：**终选抽签**（用户设计）—— 剪枝保持纯评分，只在终选那一下：
             #   若第 2..K 名与第 1 名分差 ≤ T，就在「够接近」的线里随机抽一条（K/T 两个数当难度旋钮）。
             #   默认 K=0 = 关。⚠️ 抽签用**专用 RNG + 局面哈希播种** ⇒ 同一局面同一签、整局可复现
             #   （不像 JITTER 用全局 randf()，跨进程不可复现）。
             # 【2026-09-20 用户拍板·已删】原 'LOTTERY_K', 'LOTTERY_T', 'LOTTERY_STRICT', 'LOTTERY_SEED'
             #   （终选抽签）：用户实测「设置 L 和 T 没让 AI 变弱，反倒胜率还增加了」⇒ 当难度旋钮无效，
             #   键与 `_lottery_pick()` 一起从引擎删除（规则键 39 → 35）。
             # 2026-09-19 追加：**难度档「概率性弱化」**（用户设计：「我希望简单难度和普通难度也有概率
             #   可以打出最好的操作。就是概率的多少问题」）。与抽签/抖动那一族**本质不同**：那些都在
             #   "评分分不出来的并列区"里动手脚（实测全部无效）；这一条是**两个强度不同的引擎按概率混合**
             #   ⇒ `期望棋力 = p × 满血 + (1−p) × 弱化`，p 本身就是一个单调的难度旋钮。
             #   WEAK_MODE = 0 关 / 1 每单位独立贪心 / 2 关威胁预判整层 / 3 两者都弱化；
             #   WEAK_P = 这一回合走弱化引擎的概率；WEAK_SEED = 抽签种子（用局面哈希播种 ⇒ 可复现）。
             #   默认 0 ⇒ 生产三档与噩梦逐位不变。
             'WEAK_MODE', 'WEAK_P', 'WEAK_SEED',
             # 2026-09-19 追加：替补「收尾优先」（用户：「战局中主动撤下英雄来收尾」）。
             #   对面只剩 1 个存活单位时（打死它 = 直判负对方）：落点优先能打到/打死它，选人优先补
             #   「上来就能收官」的那个。默认 0 = 关 ⇒ 生产三档与噩梦逐位不变。
             'SUB_FINISH_W',
             # 2026-09-19 追加：**判负线硬闸门**（用户实机：「敌人死了两人还去打人、被反击致死」）。
             #   走完这一步我方非召唤物存活 = 0（= 直接判负）的候选线直接丢弃 —— 用支配关系而不是罚分，
             #   因为罚分会被平坦评分地形淹掉。默认 0 = 关 ⇒ 生产三档逐位不变。
             'NO_LOSS_FILTER',
             # 2026-09-20 追加：**位移技能威胁**（用户「我有暗域，把敌人换位他就受巨额伤害」；探针证实
             # AI 落点评分完全不认 ⇒ 12 次能打人的决策里 11 次贴到暗域旁边）。默认 0 = 关 ⇒ 生产逐位不变。
                  # 2026-09-20 追加：**低档"只用弱化旋钮"**（用户实测「我觉得现在简单和普通太离谱了。
             #   你再简单再弱智，能打的时候你得打吧，而不是能打敌人的时候跑开，或者敲一下障碍」）。
             #   1 = `_beam()`/`_jitter()` 回到 `w_beam`/`w_jitter`（默认 200 / 0），不再吃难度自带的
             #   "简单 50 + 抖动 ±8 · 普通 100 + 抖动 ±1.5" —— 抖动是**逐候选**加的随机数，而决策分差
             #   中位 0.000 ⇒ 在平地上等于掷骰子（能打不打、敲墙、后退）。默认 0 = 关 ⇒ 困难/噩梦逐位不变。
             # 2026-09-20 追加：**「原地不动」候选**（用户实机日志：装甲堡垒 `[本步 Δ-3.3]` 还动）。
             #   根因：`_actions_for()` 里所有"纯移动"分支都写了 `if mc != u.cell` ⇒ 候选表**从来没有**
             #   "原地不动、什么都不做"这一项（只有原地攻击/原地拆墙；no-op 兜底只在 `combos.size()==0`）
             #   ⇒ **AI 每个单位每回合被迫移动**，装甲堡垒 hero_48 因此永远拿不到[坚固]（机制：回合结束
             #   没移动 ⇒ 获得坚固）。1 = 允许"不动"进候选表。默认 0 = 关 ⇒ 全档逐位不变。
             'STAY_OPTION',
             # 【2026-09-20 第三轮 · 已删】原 TEAM_THREAT_W（⑪队级威胁）与 THREAT_ALLOC_W（⑮分摊记账）
             #   —— 用户拍板整族删除（「下回合挨打太难了…可以删掉吗」）。依据：剂量批 2.0−关掉 = −0.20
             #   [−9.40, +8.99]、3.0−关掉 = −5.58 [−15.65, +4.49] ⇒ 风格旋钮不是强度旋钮（§14#174）。
             #   替代：⑮只剩必死折（THREAT_DEAD_FOLD，判据换成「挨打合计」）+ ⑥MOVE_ACCEPT_DAMAGE + 终选层 T13。
             # 2026-09-20 追加：**"站着能打到人却不打"的代价**（用户实测：`不攻击（原地够得到3个）`
             #   却退开）。根因是**"放弃一次出手"在评分里没有成本**（只有真打出去的伤害有钱）。
             #   ⚠️ 同一位置的旧注（TEAM_THREAT_W / THREAT_ALLOC_W / THREAT_SUM_CAP 三段）已随键删除。
             #   ⚠️ 见上面那三行 2026-09-20 第三轮说明。
             # 2026-09-20 追加：**威胁求和上限**（用户实测诊断：「AI 的该格挨打是不是计算的不对，
             #   加起来都超过对方总伤害了，然后挨打扣分大部分时候比伤害加分高，所以就会退」）。
             #   旧口径 `_incoming_damage` / `_incoming_plain` 都是**逐敌人求和**（每个够得着的敌人都按
             #   满伤算一次），而每个 AI 单位各算一遍 ⇒ 对面 3 人时全队合计 = 真实总输出的 **3 倍**。
             #   N>0 = 只累加最疼的 N 个（现实里同一格不可能被所有人同时打到）。0 = 关（旧口径、逐位不变）。
                  # 2026-09-20 追加：**"站着能打到人却不打"的代价**（用户实测：`不攻击（原地够得到3个）`
             #   却退开）。根因是**"放弃一次出手"在评分里没有成本**（只有真打出去的伤害有钱）。
             #   本键 = 本回合没攻击、但它移动前站在原位就够得到人 ⇒ 罚该分（价钱不是硬规则）。
             #   判据在**动作层**算（`_evaluate` 看不到"移动前"）。默认 0 = 关 ⇒ 逐位不变。
             'IDLE_HIT_PENALTY',
             # 【2026-09-21 用户提问后追加·两项"队形"评分】用户原话：「现在有没有什么评分会让 AI 保持
             #   一个不错的队形。现在 AI 有个问题，他会因为某些格子的能打的伤害高或者被伤害少而站得
             #   四分五裂，然后被玩家隔离，逐个击破。远程也有可能因为这个原因走进死胡同，或者选择贴墙，
             #   最后被玩家包夹」。核对结论：**现有项里没有任何一项看"队友之间离多远"**（⑥⑦⑮ 全是
             #   "我这个单位会不会挨打"的个人罚分，合力恰好是"各躲各的"；唯一整队味道的 ⑦ 是 max 型，
             #   只管得住"某个人站太前"）⇒ 必须新增项、调旧键治不了（调大 ⑦ 只会躲得更散）。
             #   ⑳`FORM_COHESION_W` 抱团：只在"半径 2 格内一个队友都没有"时罚 1 分，**只罚孤立不罚抱团**
             #   ⇒ 不会把队伍逼成一坨去吃 AoE；㉑`FORM_ESCAPE_W` 退路/被夹：可走邻格少于 2 罚差额
             #   + "相邻敌多于相邻友"的差额（治贴墙/死胡同/被包夹）。两项都是纯局面量、纯罚分。
             #   默认 0 = 关 ⇒ 生产三档逐位不变；噩梦档初值写在 `RL/weights/噩梦.json`。规则键 26 → 28。
             'FORM_COHESION_W', 'FORM_ESCAPE_W',
             # 【2026-09-21 用户提问后追加】**"治疗"计价**（用户问「捡血量buff加分，回血也加分，是不是重复了」→
             #   答：不重复；但顺着问出一个真缺口：**技能治疗在评分里一分都不加** ⇒ AI 天生不看重医疗单位）。
             #   `HEAL_CREDIT_W` = 按**实际回血量**计价（1 血 = W 分，含溢出）：我方回血 +、对面回血 −；
             #   >0 时 ⑧ 的 `heal` 那一份自动归 0（改由本项计）⇒ 同一件事只算一次。
             #   默认 0 = 关（生产三档逐位不变）；噩梦 = 1.0（1 血 1 分，与 HP_VALUE_W 同价）。规则键 28 → 29。
             # 【2026-09-22 用户拍板·㉒隔断】用户原话：「如果AI的走位可以把玩家的英雄给隔开就不错」，
             #   并定了两条硬约束：**不能为了隔断把远程去贴身**、**不能为了隔断让自己的队伍走散/漏单**。
             #   判据 = 对玩家每一对存活单位各算两套路网距离（墙 = 地形 / 地形+**合格的我方身体**），
             #   只付"我方身体造成的那部分切断"；**只在全队行动完的末态结算**（与 ⑳㉑ 同一层）。
             #   两条约束落在"谁能算墙"：算墙者必须**自己有队友在 2 格内**（孤军堵路不加分）、
             #   **远程只有在没贴到玩家身上时才算墙**。默认 0 = 关；噩梦档初值 2.0。
             #   ⚠️ 这是**新评分项** ⇒ 按规矩要跑剂量批再定值。规则键 29 → 30。
             'HEAL_CREDIT_W', 'SPLIT_W',
             # 【2026-09-22 用户拍板·㉓离队距离】用户原话：「位置拉力的得分压过了抱团，导致烈焰祭司宁愿
             #   更加往前冲，也不和队友站到一起」。**病灶**：⑳ 是 0/1 阶跃 ⇒ 掉单之后「原地」与「再跑 3 格」
             #   代价一样 ⇒ 只要 ⑤位置拉力（噩梦 2.4/格）大过 FORM_COHESION_W 就一路前冲、永不回头
             #   （实机读数：烈焰祭司拉近 2 格 +4.8 vs 抱团 −3.0 ⇒ 净 +1.8）。**改法**：本键给 ⑳ 补上
             #   距离梯度 = 每个我方非召唤物单位再按 `max(0, 与最近队友的格距 − 1)` 罚（贴身 0 罚、
             #   格距 3 罚 2 份）；**只看格距、不看地形**（隔墙仍由 ⑳ 的 0/1 份管）；**只在末态结算**。
             #   同时把噩梦档 `FORM_COHESION_W` 3.0 → 5.0。默认 0 = 关（生产三档逐位不变）；噩梦 = 3.0/格。
             #   ⚠️ 也是**新评分项** ⇒ 剂量批（0 / 3 / 6）待做。规则键 30 → 31。
             'FORM_SPREAD_CELL_W',
             # 【2026-09-22 晚·用户拍板】队形"一把尺"开关 `FORM_MERGE_MODE`（0 = 现役三项独立 /
             #   1 = ⑳ 并进 ㉓、㉑ 退役）：把"0/1 孤立份"并进 ㉓ 的距离梯度当**台阶**（比例
             #   `FORM_ISO_STEP_RATIO = 5/3` ⇒ 现役取值下与 ⑳+㉓ 逐点等价，见 `RL/probe/队形合并自检.gd`），
             #   整条队形曲线只由 `FORM_SPREAD_CELL_W` 一个键缩放。默认 0 ⇒ 生产三档逐位不变。
             #   规则键 31 → 32。
             'FORM_MERGE_MODE',
             # 【2026-09-23 用户拍板「按2」】搜索模式 `SEARCH_MODE`（0 = 现役"每个单位的移动+攻击绑成一个
             #   组合、一步做完就出局" / 1 = **严格两段**联合搜索：先联合决定"每个单位走到哪"、再联合决定
             #   "谁打谁 / 敲哪块障碍 / 不打"与出手顺序 / 2 = 模式 1 **放宽一处**：阶段 2 里还没挪位的单位
             #   可以直接用现役那一整套组合（含"移动+攻击"）⇒ 支持"A 挪位、B 挪位、C 移动+出手、B 出手、
             #   A 出手"这类**移动与出手互相穿插**的顺序）。
             #   用户原话：「我希望 AI 的攻击不要按顺序，移动打移动打移动打这样…比如 A 走 然后 B 走 然后 C 打
             #   然后 A 打 然后 B 打这种逻辑」+「A 挪位，B 挪位，C 挪位打，B 打，A 打 能吗」。
             #   **这是动搜索结构、不是动价格** ⇒ 剂量批三臂（0 旧 / 1 严格两段 / 2 穿插）
             #   见 `Data/Progress_tracking/1_通用策略.md` §五 T19。默认 0 ⇒ 生产三档逐位不变；噩梦 = 2。
             #   规则键 32 → 33。
             'SEARCH_MODE',
             # 【2026-09-23 用户拍板「你把超时时间加长点？」】单次搜索的思考上限 `TIME_BUDGET_MS`
             #   （毫秒；引擎默认 10000）。为什么要能调：两阶段搜索的**出手阶段**常被这个上限砍掉
             #   ⇒ 实机表现就是「AI 都不攻击了/只挪位不出手」；单位多（含召唤物）时走位阶段就超时，
             #   而那处的兜底原来还会把『已挪位未出手』的单位当成已完成 ⇒ 攻击整段丢（已同时修）。
             #   它**不是评分权重**、不进自动搜索，只是"能搜多广"的预算 ⇒ 放规则表（只影响写了它的档：
             #   噩梦 = 25000；简单/普通/困难没有这个键 ⇒ 仍是 10000、逐位不变）。
             #   规则键 33 → 34。
             'TIME_BUDGET_MS',
             # 【2026-09-23 用户拍板·㉔破盾】用户原话：「增加破盾，但是需要有这个意图，用越低的伤害去破盾越值」。
             #   病灶：盾在推演里是「整次免伤并消耗」⇒ 打带盾目标 ③血量账/④集火 都是 0 ⇒ 破盾这一击等于白送
             #   （实机读数：小 mesmer 宁可去打旁边没盾的黄金矿工 +1.10，也不拆盾）。
             #   口径：价值 = 本键 × SHIELD_BREAK_DMG_REF(1.0) / max(这一击的伤害, 1.0) ⇒ **伤害越低越值**
             #   （1 伤破盾=满价、3 伤=1/3、5 伤=1/5：小 poke 拆盾划算，大招砸盾几乎不值）；对面盾被我方破 +、
             #   我方盾被对面破 −（对称）。默认 0 = 关（生产三档逐位不变）；噩梦 = 4.0（首版，待剂量批）。
             #   规则键 34 → 35。
             'SHIELD_BREAK_W')
}

function Get-WeightsMeta([string]$Path, [int]$Beam, [int]$BeamOpp = 0, [string]$Opp = 'base', [string]$WBSha = '') {
    # Everything needed to answer "which weights produced this row, with which knobs".
    $obj = Read-JsonFile $Path
    $names = @($obj.PSObject.Properties.Name)
    $hvN = 0; $hvChanged = 0
    if ($names -contains 'HERO_VALUE') {
        foreach ($p in $obj.HERO_VALUE.PSObject.Properties) {
            $hvN++
            if ([Math]::Abs((Get-Num $p.Value) - 1.0) -gt 1e-9) { $hvChanged++ }
        }
    }
    $kill = 0.0; $focus = 0.0; $engage = 0.0; $threat = 0.0; $jitter = 0.0; $vip = 0.0
    if ($names -contains 'KILL_BONUS') { $kill = Get-Num $obj.KILL_BONUS }
    if ($names -contains 'FOCUS_FIRE_WEIGHT') { $focus = Get-Num $obj.FOCUS_FIRE_WEIGHT }
    if ($names -contains 'ENGAGE_PULL_PER_CELL') { $engage = Get-Num $obj.ENGAGE_PULL_PER_CELL }
    if ($names -contains 'THREAT_MOVE_DISCOUNT') { $threat = Get-Num $obj.THREAT_MOVE_DISCOUNT }
    if ($names -contains 'JITTER') { $jitter = Get-Num $obj.JITTER }
    # 2026-09-18：身价乘法化的指数（默认 0 = 关闭）。放进 audit 字符串，让每行自己说明"这局开没开乘法"。
    if ($names -contains 'VALUE_IMPORTANCE_POW') { $vip = Get-Num $obj.VALUE_IMPORTANCE_POW }
    return [pscustomobject]@{
        file = (Split-Path -Leaf $Path); sha12 = (Get-Sha256Hex12 $Path); entries = $names.Count
        beam = $Beam; beam_opp = $BeamOpp; opp = $Opp; wB_sha = $WBSha
        jitter = $jitter; kill_bonus = $kill; focus_fire = $focus
        engage_pull = $engage; threat = $threat; vip = $vip
        hero_value_n = $hvN; hero_value_changed = $hvChanged
        script_hash = (Get-ScriptHashString)
    }
}

function Read-MeasureRows([string]$Run) {
    $p = Join-Path (Get-ResultsDir $Run) 'measure.csv'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Import-Csv -LiteralPath $p -Encoding UTF8)
}

function Get-AsideKey([string]$Value) {
    # The harness prints a_side as a numeric faction id; older runs printed side letters. Those ids
    # have not been stable across harness revisions, so identity must NOT depend on the raw letter.
    # Map: player-like -> 'P', enemy-like -> 'E', unknown -> the raw value.
    $v = ([string]$Value).Trim().ToLower()
    if ($v -eq 'p' -or $v -eq 'player' -or $v -eq '2') { return 'P' }
    if ($v -eq 'e' -or $v -eq 'enemy' -or $v -eq '0') { return 'E' }
    return $v
}

function Get-FirstKey([string]$Value) {
    # CLI first modes are 'p'/'e'/'both'; the harness prints the first-mover as the numeric side id from
    # GameState (autoload/GameState.gd: SIDE_PLAYER := 0, SIDE_ENEMY := 1), i.e. a 'first=e' batch records
    # `first=1` and a 'first=p' batch records `first=0`. Normalise BOTH directions to one token so the
    # key/token built from the CLI spec and the one parsed from a recorded row always agree.
    # (Before: '0' was not recognised at all -> a row recorded from the log kept the raw '0' while the
    # resume key was built from 'p' -> 'P', so resume/repair could not see the row and re-measured it,
    # and the numbers were attached to the wrong side.)
    $v = ([string]$Value).Trim().ToLower()
    if ($v -eq 'p' -or $v -eq 'player' -or $v -eq '0') { return 'P' }
    if ($v -eq 'e' -or $v -eq 'enemy' -or $v -eq '1') { return 'E' }
    return $v
}

function Get-LeagueConfig([object]$Spec) {
    <#
      The self-play league, read from the spec's `league` block:
        league.self_play_fraction : share of cells played against the checkpoint (0..1)
        league.checkpoint         : weights file of "the previous generation", repo-relative
        league.base_opp_beam      : beam for the fixed difficulty arm (printed/audited; the value that
                                    actually reaches the harness is the config's beam_opp)
      Returns $null when the spec has no league block (every cell then runs the plain fixed opponent).
      The checkpoint's sha12 is read here so it lands in the audit string and therefore in the cell key:
      a new checkpoint automatically invalidates every self-play measurement of the old one.
    #>
    if (-not ($Spec.PSObject.Properties.Name -contains 'league')) { return $null }
    $lg = $Spec.league
    if (($lg.PSObject.Properties.Name -contains 'enabled') -and (-not [bool]$lg.enabled)) {
        Write-Host '[league] league block present but enabled=false -> using the fixed opponent for every cell'
        return $null
    }
    $frac = 0.0
    if ($lg.PSObject.Properties.Name -contains 'self_play_fraction') { $frac = [double]$lg.self_play_fraction }
    if ($frac -lt 0.0 -or $frac -gt 1.0) {
        throw ('LEAGUE CONFIG: league.self_play_fraction=' + $frac + ' is outside [0,1]')
    }
    $ckName = ''
    if ($lg.PSObject.Properties.Name -contains 'checkpoint') { $ckName = [string]$lg.checkpoint }
    $ckPath = ''
    $ckSha = ''
    $ckExists = $false
    if ($frac -gt 0.0) {
        if (-not $ckName) { throw 'LEAGUE CONFIG: league.self_play_fraction > 0 but league.checkpoint is empty' }
        $ckPath = Join-Path $script:RepoRoot $ckName
        $ckExists = Test-Path -LiteralPath $ckPath
        if ($ckExists) { $ckSha = Get-Sha256Hex12 $ckPath }
    }
    $baseBeam = 0
    if ($lg.PSObject.Properties.Name -contains 'base_opp_beam') { $baseBeam = [int]$lg.base_opp_beam }
    return [pscustomobject]@{ fraction = $frac; checkpoint_name = $ckName; checkpoint = $ckPath
                              checkpoint_sha12 = $ckSha; checkpoint_exists = $ckExists; base_opp_beam = $baseBeam }
}

function Assert-LeagueCheckpoint([object]$League) {
    <#
      The hard gate, called only where self-play cells are about to be PLANNED or RUN. A missing
      checkpoint must never silently degrade into a plain fixed-opponent run: the report would still say
      "league" while 70% of the cells quietly measured something else.
      Kept out of Get-LeagueConfig so that `-Task league` can still CREATE the checkpoint.
    #>
    if (-not $League) { return }
    if ($League.fraction -le 0.0) { return }
    if (-not $League.checkpoint_exists) {
        throw ('LEAGUE CONFIG: checkpoint weights file not found: ' + $League.checkpoint +
               ' (league.self_play_fraction=' + $League.fraction + ' needs it; create it with' +
               ' `-Task league -Configs <cfg> -Run <run>`; refusing to fall back to opp=base)')
    }
}

function Assert-LeagueArmConsistency([string]$Run, [object]$Spec, [object[]]$Configs, [int[]]$Seeds, [string]$LeagueScope = '') {
    <#
      GATE: every config measured in this run must face the SAME opponent at the same (seed, first).
      The sensitivity/compare table pairs configs on (seed, first, a_side) and subtracts their scores, so
      if g1_best faced opp=base while g1_c1 faced opp=cand on the same cell, every delta would silently
      mix "parameter effect" with "opponent effect" and the whole table would be meaningless.
      This is a hard throw, naming the offending cells: a silently-unpairable table is worse than no table.
      (The split itself no longer depends on the config - see Test-LeagueSelfPlay - so this gate exists to
      catch a future regression or a hand-edited table, not to paper over one.)
    #>
    $lg = Get-LeagueConfig -Spec $Spec
    $frac = 0.0
    if ($lg) { $frac = [double]$lg.fraction }
    $bad = @()
    foreach ($sd in $Seeds) {
        foreach ($fs in @($Spec.measurement.firsts)) {
            $seen = @{}
            foreach ($c in $Configs) {
                $opp = 'base'; $wb = ''
                if ($frac -gt 0.0 -and (Test-LeagueSelfPlay -Run $Run -Config ([string]$c.name) -Seed $sd -First $fs -Fraction $frac -Scope $LeagueScope)) {
                    $opp = 'cand'; $wb = [string]$lg.checkpoint_sha12
                }
                $bB = [int](Get-CfgBeamOpp $c)
                if ($opp -eq 'cand') { $bB = [int]$c.beam }
                $sig = ([string]$opp + '/' + [string]$wb + '/' + [string]$bB)
                if (-not $seen.ContainsKey($sig)) { $seen[$sig] = @() }
                $seen[$sig] += [string]$c.name
            }
            if ($seen.Count -gt 1) {
                $desc = @()
                foreach ($k in ($seen.Keys | Sort-Object)) { $desc += ($k + ' <- ' + ($seen[$k] -join ',')) }
                $bad += ('seed=' + $sd + ' first=' + $fs + ' : ' + ($desc -join '  VS  '))
            }
        }
    }
    if ($bad.Count -gt 0) {
        $msg = 'LEAGUE ARM MISMATCH: the same (seed, first) is played against DIFFERENT opponents by ' +
               'different configs, so this run cannot be compared pairwise (delta pts would mix parameter ' +
               'and opponent effects). Offending cells: ' + ($bad -join ' ; ')
        throw $msg
    }
    Write-Host ('[league] arm consistency OK: every (seed, first) has ONE opponent identity across all ' +
                $Configs.Count + ' config(s) x ' + $Seeds.Count + ' seed(s)')
}

function Test-LeagueSelfPlay([string]$Run, [string]$Config, [int]$Seed, [string]$First, [double]$Fraction, [string]$Scope = '') {
    <#
      Which arm does this cell play? Deterministic, no RNG, no clock, and derived ONLY from
      (scope, seed, first) - explicitly NOT from the config.

      Why the config must stay out of it: several configs are measured as a PAIRED comparison on the
      same (seed, first) - the sensitivity table subtracts their per-game scores. If the arm depended on
      the config, g1_best could face opp=base while g1_c1 faces opp=cand on the very same cell, and every
      delta would then mix "parameter effect" with "opponent effect" - the comparison would be worthless
      with no error anywhere. Keying only on (seed, first) guarantees all configs of a run meet the same
      opponent at the same cell, which is what Assert-LeagueArmConsistency now enforces.

      $Config is accepted but unused, so existing callers keep working.
      $Scope lets an equivalence check force BOTH arms onto the same split (two run names would other-
      wise disagree, and equiv_serial vs equiv_parallel would look different for no real reason).
      Threshold is `value < fraction` with value in [0,1): fraction=0 -> never self-play, =1 -> always.
    #>
    if ($Fraction -le 0.0) { return $false }
    if ($Fraction -ge 1.0) { return $true }
    $scopeUse = $Run
    if ($Scope) { $scopeUse = $Scope }
    $s = ([string]$scopeUse).ToLower() + '|' + [string]$Seed + '|' + (Get-FirstKey $First)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash($bytes)
        # top 32 bits -> [0,1); enough resolution for a 70/30 split over thousands of cells.
        # Built with [uint32] arithmetic on purpose: `[int]$h[0] -shl 24` OVERFLOWS in PowerShell 5.1
        # (238 << 24 = -301989888). That made the sum negative for every input, so EVERY cell landed in
        # the self-play arm no matter what the fraction was.
        $u = ([uint32]$h[0] * 16777216) + ([uint32]$h[1] * 65536) + ([uint32]$h[2] * 256) + [uint32]$h[3]
        $v = ([double]$u) / 4294967296.0
        return ($v -lt $Fraction)
    } finally { $sha.Dispose() }
}

function Get-CellIdentity([string]$Config, [int]$Seed, [string]$First, [string]$Opp, [string]$WBSha) {
    # The full identity of one (config, seed, first) cell: the two sides of the game must be pinned too,
    # otherwise a self-play cell and a fixed-opponent cell look like the same measurement.
    return [pscustomobject]@{ Config = $Config; Seed = $Seed; First = $First
                              Opp = $(if ($Opp) { $Opp } else { 'base' })
                              WBSha = $(if ($WBSha) { $WBSha } else { '' }) }
}

function New-InvToken {
    # Unique id of one batch instance (one Godot launch for one cell). The batch FILE name is
    # deterministic and reused, so this token is what lets the append-only raw log and the derived table
    # distinguish "the same cell measured again" from "a duplicate of the same measurement".
    return ('i' + (Get-Date).ToString('yyyyMMddHHmmss') + '_' + [string]$PID)
}

function Get-RowField([object]$Row, [string]$Name, [string]$Default = '') {
    # Tolerant field read for measure.csv rows. A table written before a column existed (or an older
    # worker dir still sitting in the pool) simply has no such property, and `$row.opp` on a
    # PSCustomObject raises PropertyNotFoundException instead of returning $null.
    if ($null -eq $Row) { return $Default }
    if (@($Row.PSObject.Properties.Name) -contains $Name) {
        $v = $Row.$Name
        if ($null -eq $v) { return $Default }
        return [string]$v
    }
    return $Default
}

function Get-TupleKey([string]$Config, [object]$Seed, [string]$First, [string]$AKey, [object]$Seq,
                      [string]$Opp = '', [string]$WBSha = '') {
    # Identity of one measured game. The last two fields pin the OPPONENT: a self-play game against
    # checkpoint X and a fixed-opponent game are not the same measurement even for the same
    # (config, seed, first, seq), and a self-play game against checkpoint Y is a third one.
    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Config, [string]$Seed, [string]$First, $AKey, [string]$Seq,
            $(if ($Opp) { $Opp } else { 'base' }), $(if ($WBSha) { $WBSha } else { '' }))
}

function Get-MeasureKeys([object[]]$Rows) {
    # Identity = (config, seed, first, X, seq within the batch, opp, wB_sha). `a_side` is deliberately
    # excluded: the harness prints it as the game index inside the batch (1 then 0), NOT as the faction
    # the candidate played, so keying on it made resume re-run every batch.
    $set = @{}
    $byBatch = @{}
    foreach ($r in $Rows) {
        $b = [string]$r.batch_out
        if (-not $byBatch.ContainsKey($b)) { $byBatch[$b] = 0 }
        $byBatch[$b]++
        $seq = [string]$r.seq
        if (-not $seq) { $seq = [string]$byBatch[$b] }
        $k = Get-TupleKey -Config ([string]$r.config) -Seed $r.seed -First (Get-FirstKey ([string]$r.first)) -AKey 'X' -Seq $seq `
             -Opp (Get-RowField $r 'opp' 'base') -WBSha (Get-RowField $r 'wB_sha')
        $set[$k] = $true
    }
    return $set
}

function Remove-MeasureRowsForSeed([string]$Run, [string]$Config, [int]$Seed, [string]$First) {
    $p = Join-Path (Get-ResultsDir $Run) 'measure.csv'
    if (-not (Test-Path -LiteralPath $p)) { return }
    $rows = @(Read-MeasureRows $Run)
    # Compare on the same normalised token the rows and the resume keys use (callers pass the CLI form
    # 'e'/'p', the file holds 'E'/'P'; a raw string compare silently kept stale rows of a re-measured cell).
    $fk = Get-FirstKey $First
    $kept = @($rows | Where-Object { -not (([string]$_.config -eq $Config) -and ([int]$_.seed -eq $Seed) -and ((Get-FirstKey ([string]$_.first)) -eq $fk)) })
    if ($kept.Count -eq $rows.Count) { return }
    if ($kept.Count -eq 0) {
        # 【2026-09-21 修·单批 run 掉表头】一行都不留时**删掉整份表**，不要写空表：
        # `@() | Export-Csv -NoTypeInformation` 只留 3 字节 BOM、没有表头，而 Add-MeasureRows
        # 只在"文件不存在"时补表头 ⇒ 单批 run（池子每格就是 1 批）会产出无表头 measure.csv，
        # 紧接着的 completeness 门禁 Import-Csv 直接抛错、整批报失败。删掉 ⇒ 下一批重建带表头的表。
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        return
    }
    # Export-Csv handles quote escaping correctly. Hand-rolled "join with commas" corrupts any field
    # that contains a comma (lineup_used does), so never build CSV text by hand here.
    $kept | Select-Object (Get-MeasureColumns) | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8
}

function Add-ThroughputEvent([string]$Run, [int]$Games, [double]$WallSec, [int]$Workers) {
    <#
      Persist the REAL elapsed wall clock of one invocation. measure.csv only carries per-batch wall
      clocks, and those add up across parallel workers, so without a line like this there is no durable
      record of how long a run actually took - and `-Task estimate` had to guess. It guessed from the
      summed figure, which for a 16-game 6-worker run reads ~9x too pessimistic: the difference between
      "P1 = 2.6 h" and "P1 = 24 h". Append-only, one row per invocation.
    #>
    if ($Games -le 0 -or $WallSec -le 0) { return }
    $dir = Get-ResultsDir $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir 'throughput.csv'
    $lines = @()
    if (-not (Test-Path -LiteralPath $p)) { $lines += 'run,when,games,workers,wall_s,sec_per_game' }
    $spg = $WallSec / [double]$Games
    $lines += ($Run + ',' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ',' + $Games + ',' + $Workers + ',' +
               (Format-Num $WallSec 1) + ',' + (Format-Num $spg 2))
    Add-ContentUtf8 -Path $p -Lines $lines
}

function Get-ThroughputEvents([string]$Run) {
    # One event per recorded invocation. Throughput = games actually written by that invocation, so a
    # resumed run (few new games, short wall) is comparable with a full one.
    $out = @()
    $p = Join-Path (Get-ResultsDir $Run) 'throughput.csv'
    if (Test-Path -LiteralPath $p) {
        foreach ($r in @(Import-Csv -LiteralPath $p -Encoding UTF8)) {
            $out += [pscustomobject]@{ Games = [int]$r.games; WallSec = (Get-Num $r.wall_s)
                                       Workers = [int]$r.workers; When = [string]$r.when }
        }
    }
    if ($out.Count -eq 0) {
        # Fallback for runs measured before throughput.csv existed: only present when the run was
        # rendered with -OutMd (results/<Run>.md).
        $out = @(Get-RunWallEvents -Run $Run | ForEach-Object {
            [pscustomobject]@{ Games = $_.Games; WallSec = $_.WallSec; Workers = 1; When = 'from results md' } })
    }
    return $out
}

function Get-RunWallEvents([string]$Run) {
    <#
      Real elapsed wall clock of previous invocations of this run, as reported in results/<Run>.md
      ("- total Godot wall clock this invocation: 415.7s"). measure.csv only carries PER-BATCH wall
      clocks, and those add up across parallel workers, so they cannot be turned into an elapsed time.
      One event per (games, wall) pair; duplicates from re-rendered reports are collapsed.
    #>
    $p = Join-Path $script:RepoRoot ('RL\train\results\' + $Run + '.md')
    $out = @()
    if (-not (Test-Path -LiteralPath $p)) { return $out }
    $seen = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) {
        $m = [regex]::Match($ln, 'wall clock this invocation:\s*([0-9]+(?:\.[0-9]+)?)s')
        if (-not $m.Success) { continue }
        $games = 0
        $mg = [regex]::Match($ln, 'for\s+([0-9]+)\s+game')
        if ($mg.Success) { $games = [int]$mg.Groups[1].Value }
        $w = [double]$m.Groups[1].Value
        $k = ([string]$games + '/' + (Format-Num $w 1))
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += [pscustomobject]@{ Run = $Run; Games = $games; WallSec = $w }
    }
    return $out
}

function Get-MeasureColumns {
    return @('run', 'config', 'weights_file', 'weights_fp', 'seed', 'round', 'first', 'a_side', 'lineup_used',
             'lineup_side', 'res', 'killsA', 'killsB', 'rounds', 'ptsA', 'ptsB', 'dmgA', 'dmgB', 'hpA', 'hpB',
             'over', 'subA', 'subB', 'batch_out', 'batch_wall_s', 'seq', 'line_no', 'weights_sha12', 'beam_opp',
             'opp', 'wB_sha', 'inv', 'audit')
}

function Add-MeasureRows([string]$Run, [object[]]$Rows) {
    $p = Join-Path (Get-ResultsDir $Run) 'measure.csv'
    $header = Get-MeasureHeader
    $cols = @($header -split ',')
    $lines = @()
    # 【2026-09-21 修·单批 run 掉表头】判空不能只看 Test-Path：`@() | Export-Csv -NoTypeInformation`
    # 会留下一个**只有 BOM（3 字节）**的文件（Remove-MeasureRowsForSeed 把行全删光时就是这样），
    # 于是这里以为"表已存在"而跳过表头 ⇒ measure.csv 变成无表头表 ⇒ 之后所有 Import-Csv
    # （completeness 门禁 / 排名 / compare）都抛 "成员已存在"。⇒ 长度 ≤ 3 也算空，补表头。
    $empty = $true
    if (Test-Path -LiteralPath $p) { $empty = ((Get-Item -LiteralPath $p).Length -le 3) }
    if ($empty) { $lines += $header }
    foreach ($r in $Rows) {
        $vals = @()
        foreach ($c in $cols) {
            # Get-RowField, not $r.$c: a row coming from an older pool table lacks the newer columns
            # (opp / wB_sha / inv) and a direct property read throws PropertyNotFoundException.
            $v = Get-RowField $r $c
            if ($v -match '[,"]') { $vals += ('"' + ($v -replace '"', '""') + '"') } else { $vals += $v }
        }
        $lines += ($vals -join ',')
    }
    Add-ContentUtf8 -Path $p -Lines $lines
}

function Add-RawLines([string]$Run, [string[]]$Lines, [string]$Header) {
    # Verbatim R| lines, append-only, in the order Godot printed them.
    $p = Join-Path (Get-ResultsDir $Run) 'raw_lines.log'
    $out = @()
    if (-not (Test-Path -LiteralPath $p)) { $out += ('# verbatim harness R| lines for run ' + $Run) }
    $out += ('# ---- ' + $Header)
    $out += $Lines
    Add-ContentUtf8 -Path $p -Lines $out
}

function Get-RawLogPath([string]$Run) { return (Join-Path (Get-ResultsDir $Run) 'raw_lines.log') }

function Get-CfgLine([string]$Run) {
    $p = Get-RawLogPath $Run
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $all = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)
    return @($all | Where-Object { $_.StartsWith('R|cfg|') -or $_.StartsWith('R|SUMMARY|') })
}

function Repair-MeasureCsv([string]$Run, [object]$Spec = $null) {
    <#
      Rebuild measure.csv from raw_lines.log + the per-batch .out files, which are append-only and
      verbatim. measure.csv is derived data, so if it is ever damaged this restores it without
      re-running any Godot. When $Spec is given, the weights file/fingerprint columns are restored
      from the run's cand_*.json. Returns the number of rows rebuilt.
    #>
    $logPath = Get-RawLogPath $Run
    if (-not (Test-Path -LiteralPath $logPath)) { throw ('repair: no raw log at ' + $logPath) }
    $dir = Get-ResultsDir $Run
    # Opponent identity for log headers that predate the opp= token (older runs used the spec's opponent).
    $oppDefault = 'base'
    if ($null -ne $Spec -and ($Spec.PSObject.Properties.Name -contains 'opponent') -and $Spec.opponent) { $oppDefault = [string]$Spec.opponent }
    $wfByConfig = @{}
    if ($null -ne $Spec) {
        foreach ($c in @($Spec.configs)) {
            $cn = [string]$c.name
            $cand = Join-Path $script:RepoRoot ('RL\weights\cand_' + $Run + '_' + $cn + '.json')
            if (Test-Path -LiteralPath $cand) {
                $wfByConfig[$cn] = [pscustomobject]@{ file = (Split-Path -Leaf $cand); fp = (Get-WeightsFingerprint $cand) }
            }
        }
    }
    $all = [System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::UTF8)
    $rows = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $curSeq = 0   # per-batch game counter; must match what Start-MeasureRun wrote
    $invSeen = @{}
    foreach ($ln in $all) {
        if ($ln.StartsWith('# ---- ')) {
            $h = $ln.Substring(7)
            $kv = @{}
            foreach ($tok in ($h -split ' ')) {
                $e = $tok.IndexOf('=')
                if ($e -gt 0) { $kv[$tok.Substring(0, $e)] = $tok.Substring($e + 1) }
            }
            $cur = [pscustomobject]@{
                batch = [string]$kv['batch']; config = [string]$kv['config']; seed = [int]$kv['seed']
                first = [string]$kv['first']; wall = [string]$kv['wall_s']
                edeck = [string]$kv['e_deck']; pdeck = [string]$kv['p_deck']
                audit = ''; wsha = ''; beamOpp = ''; opp = 'base'; wbSha = ''; inv = ''
            }
            # audit=[w=<sha12> beam=... beamB=... opp=... wB=... ...] as written by Start-MeasureRun
            # (no spaces inside). beamB is the opponent-side beam, opp/wB the opponent identity; older
            # logs lack them, so opp falls back to the run-wide opponent and wB stays empty.
            $mo = [regex]::Match($h, '(?:^|\s)opp=([A-Za-z0-9_]+)')
            if ($mo.Success) { $cur.opp = $mo.Groups[1].Value } else { $cur.opp = [string]$oppDefault }
            $mw2 = [regex]::Match($h, '(?:^|\s)wB=([0-9a-f]*)')
            if ($mw2.Success) { $cur.wbSha = $mw2.Groups[1].Value }
            # audit=[w=<sha12> beam=... beamB=... ...] as written by Start-MeasureRun (no spaces inside).
            # beamB is the opponent-side beam of that batch; older logs lack it, so it stays empty there.
            $ma = [regex]::Match($h, 'audit=\[([^\]]*)\]')
            if ($ma.Success) {
                $cur.audit = $ma.Groups[1].Value
                $mw = [regex]::Match($cur.audit, 'w=([0-9a-f]{12})')
                if ($mw.Success) { $cur.wsha = $mw.Groups[1].Value }
                $mb = ConvertFrom-BeamToken $cur.audit
                if ($mb.beam_opp -gt 0) { $cur.beamOpp = [string]$mb.beam_opp }
            }
            # Batch instance: the same batch name appears again every time this cell is measured, so an
            # occurrence counter is what makes each instance distinguishable in the append-only log.
            $invCount = 0
            if ($invSeen.ContainsKey([string]$cur.batch)) { $invCount = [int]$invSeen[[string]$cur.batch] }
            $invCount++
            $invSeen[[string]$cur.batch] = $invCount
            $cur.inv = ([string]$cur.batch + '#' + $invCount)
            $curSeq = 0
            if (-not $cur.edeck -and $cur.batch) {
                # older logs lack the deck columns: recover them from the batch stdout instead
                $outFile = Join-Path $dir $cur.batch
                if (Test-Path -LiteralPath $outFile) {
                    foreach ($l2 in [System.IO.File]::ReadAllLines($outFile, [System.Text.Encoding]::UTF8)) {
                        if ($l2.StartsWith('R|cfg|')) {
                            $m1 = [regex]::Match($l2, 'edeck=\[(.*?)\]')
                            $m2 = [regex]::Match($l2, 'pdeck=\[(.*?)\]')
                            if ($m1.Success) { $cur.edeck = (($m1.Groups[1].Value -replace '"', '') -replace ', ', ',') }
                            if ($m2.Success) { $cur.pdeck = (($m2.Groups[1].Value -replace '"', '') -replace ', ', ',') }
                            break
                        }
                    }
                }
            }
            continue
        }
        if (-not $ln.StartsWith('R|m|')) { continue }
        if ($null -eq $cur) { continue }
        $kv = @{}
        foreach ($tok in ($ln -split '\|')) {
            $e = $tok.IndexOf('=')
            if ($e -gt 0) { $kv[$tok.Substring(0, $e)] = $tok.Substring($e + 1) }
        }
        $genSide = 'enemy'
        if ($cur.seed % 2 -ne 0) { $genSide = 'player' }
        $lineup = $cur.edeck
        $lineupSide = 'enemy'
        if ($genSide -eq 'enemy') { $lineup = $cur.edeck; $lineupSide = 'enemy' }
        else { $lineup = $cur.pdeck; $lineupSide = 'player' }
        $wfFile = ''; $wfFp = ''
        if ($wfByConfig.ContainsKey($cur.config)) {
            $wfFile = $wfByConfig[$cur.config].file
            $wfFp = $wfByConfig[$cur.config].fp
        }
        $curSeq++
        $rows.Add([pscustomobject][ordered]@{
            run = $Run; config = $cur.config; weights_file = $wfFile
            weights_fp = $wfFp; seed = $cur.seed; round = [int][Math]::Floor([double]$cur.seed / 12)
            first = (Get-FirstKey ([string]$kv['first'])); a_side = [string]$kv['a_side']
            lineup_used = $lineup; lineup_side = $lineupSide
            res = [string]$kv['res']; killsA = [string]$kv['killsA']; killsB = [string]$kv['killsB']
            rounds = [string]$kv['rounds']; ptsA = [string]$kv['ptsA']; ptsB = [string]$kv['ptsB']
            dmgA = [string]$kv['dmgA']; dmgB = [string]$kv['dmgB']
            hpA = [string]$kv['hpA']; hpB = [string]$kv['hpB']; over = [string]$kv['over']
            subA = [string]$kv['subA']; subB = [string]$kv['subB']
            batch_out = $cur.batch; batch_wall_s = $cur.wall; seq = [string]$curSeq; line_no = ''
            inv = $cur.inv
            weights_sha12 = $cur.wsha; beam_opp = $cur.beamOpp
            opp = $cur.opp; wB_sha = $cur.wbSha; audit = $cur.audit
        })
    }
    if ($rows.Count -eq 0) { throw ('repair: raw log has no parsable game rows for run ' + $Run) }
    # A batch id can legitimately appear more than once in the append-only log (an accidental re-run,
    # a -Force re-measure, or a re-run after a change), so it is NOT a safe dedup key. Dedup on the
    # measurement identity itself = (config, seed, first, seq), keeping the first occurrence.
    $seen = @{}
    $uniq = New-Object System.Collections.Generic.List[object]
    $dropped = 0
    foreach ($r in $rows) {
        # First must be normalised exactly like Get-MeasureKeys does (harness prints first as a numeric
        # side id, the CLI/resume path as E/P). Building the key from the raw token produced a key that
        # never matched the resume keys, so a repair could not see the rows already in measure.csv and
        # the same (config, seed, first, seq) got appended again on every later batch.
        $fk = Get-FirstKey ([string]$r.first)
        $r.first = $fk   # and write it back canonically, so the file and the resume keys agree forever
        # Identity includes the batch INSTANCE when the log carries one: the same cell measured again
        # after a version change is a NEW measurement whose tuple key differs only in the weights/opponent
        # fields, so a key without `inv` would either collide (losing the new one) or coexist (showing a
        # stale row for a cell that was just re-measured). Two rows of the SAME instance are duplicates.
        $inv = Get-RowField $r 'inv'
        $k = Get-TupleKey -Config ([string]$r.config) -Seed $r.seed -First $fk -AKey 'X' -Seq ([string]$r.seq) `
             -Opp ((Get-RowField $r 'opp' 'base') + '@' + (Get-RowField $r 'wB_sha') + '#' + $inv)
        if ($seen.ContainsKey($k)) { $dropped++; continue }
        $seen[$k] = $true
        $uniq.Add($r)
    }
    if ($dropped -gt 0) {
        Write-Host ('[repair] dropped ' + $dropped + ' duplicate measurement(s) (kept the first run of each tuple)')
    }
    $rows = $uniq
    # Keep only the NEWEST batch instance of each cell. Without this a cell re-measured after a version
    # change appears twice in the table (old weights AND new weights) and the report would claim
    # missing=0 while some of those rows came from the previous version. Rows are in log order.
    $newest = @{}
    $lastIdx = @{}
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $ck = ([string]$r.config + '|' + [string]$r.seed + '|' + (Get-FirstKey ([string]$r.first)) + '|s' + (Get-RowField $r 'seq'))
        $newest[$ck] = $r
        $lastIdx[$ck] = $i
    }
    if ($newest.Count -lt $rows.Count) {
        $kept = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $ck = ([string]$r.config + '|' + [string]$r.seed + '|' + (Get-FirstKey ([string]$r.first)) + '|s' + (Get-RowField $r 'seq'))
            # index comparison, not ReferenceEquals: PowerShell can hand back a different wrapper for the
            # same underlying object, which made that check reject EVERY row and empty the table.
            if ([int]$lastIdx[$ck] -eq $i) { $kept.Add($r) }
        }
        Write-Host ('[repair] superseded ' + ($rows.Count - $kept.Count) + ' older measurement(s) of cells measured again (kept the newest batch of each)')
        $rows = $kept
    }
    $target = Join-Path $dir 'measure.csv'
    if (Test-Path -LiteralPath $target) {
        Copy-Item -LiteralPath $target -Destination ($target + '.before_repair') -Force
    }
    $rows | Select-Object (Get-MeasureColumns) | Export-Csv -LiteralPath $target -NoTypeInformation -Encoding UTF8
    return $rows.Count
}

# ============================ one measurement cell + serial/parallel runners ============================

function Invoke-GodotCell {
    <#
      Run ONE cell (config, seed, first, opp, wB_sha): a single Godot process playing every configured
      side. Split out of Start-MeasureRun so the serial path and every worker share exactly one code path.
      Returns NewGames / WallSec, or NewGames=0 when the batch produced no parsable rows.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Cfg,
        [Parameter(Mandatory = $true)][int]$Seed,
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $false)][string]$AppData = '',
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 3600,
        [Parameter(Mandatory = $false)][switch]$FixedDecks,
        # League: which opponent this cell plays. 'base' = the fixed difficulty copy; 'cand' = self-play,
        # in which case -WeightsB is the checkpoint file the B side is given.
        [Parameter(Mandatory = $false)][string]$Opp = '',
        [Parameter(Mandatory = $false)][string]$WeightsB = '',
        [Parameter(Mandatory = $false)][string]$WBSha = '',
        [Parameter(Mandatory = $false)][int]$BeamOpp = 0,
        # Batch-instance token (see Get-MeasureHeader). Empty -> a fresh one is generated, so even a
        # direct call produces a distinguishable batch instance.
        [Parameter(Mandatory = $false)][string]$InvToken = ''
    )
    if (-not $InvToken) { $InvToken = New-InvToken }
    $dir = Get-ResultsDir $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $info = Get-SeedInfo -Spec $Spec -Seed $Seed
    $ed = $Spec.decks.enemy; $pd = $Spec.decks.player
    if (-not $FixedDecks) { $ed = $info.enemy_deck; $pd = $info.player_deck }
    $oppUse = $Opp; if (-not $oppUse) { $oppUse = [string]$Spec.opponent }
    $beamOppUse = $BeamOpp; if ($beamOppUse -le 0) { $beamOppUse = [int](Get-CfgBeamOpp $Cfg) }
    $wBUse = $WeightsB; if (-not $wBUse) { $wBUse = '-' }
    if ($oppUse -eq 'cand' -and $wBUse -eq '-') {
        throw ('league: cell ' + $Cfg.name + '/' + $Seed + '/' + $First + ' wants opp=cand but no B-side weights file was given')
    }
    if ($oppUse -eq 'cand' -and -not (Test-Path -LiteralPath $wBUse)) {
        throw ('league: B-side weights file does not exist: ' + $wBUse)
    }
    $base = Join-Path $dir ('b_' + $Cfg.name + '_s' + $Seed + '_f' + $First)
    $r = Invoke-GodotBatch -Seeds @([int]$Seed) -First $First -EDeck $ed -PDeck $pd `
         -WeightsA $Cfg.weights_file -WeightsB $wBUse -BeamA ([int]$Cfg.beam) -BeamB $beamOppUse `
         -Opp $oppUse -LogBase $base -TimeoutSec $TimeoutSec -AppData $AppData -SkipSlotWait -InvToken $InvToken
    $parsed = Read-RowsFromText $r.Stdout
    $verbatim = @($r.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('R|') })
    Add-RawLines -Run $Run -Lines $verbatim -Header ('batch=' + (Split-Path -Leaf $base) + ' config=' + $Cfg.name + ' seed=' + $Seed + ' first=' + $First + ' exit=' + $r.ExitCode + ' wall_s=' + (Format-Num $r.WallSec 1) + ' e_deck=' + $ed + ' p_deck=' + $pd + ' audit=[' + (Get-AuditString $Cfg.meta $oppUse $WBSha $beamOppUse) + ']')
    if ($parsed.m.Count -eq 0) {
        Write-Host ('[cell] !! ' + (Split-Path -Leaf $base) + ' produced 0 game rows (exit=' + $r.ExitCode + ')')
        return [pscustomobject]@{ NewGames = 0; WallSec = $r.WallSec; Cell = ((Split-Path -Leaf $base)) }
    }
    $newRows = @()
    $seq = 0
    foreach ($m in $parsed.m) {
        if ([int]$m.seed -ne $Seed) { continue }
        $seq++
        $ptsA = Get-Num $m.ptsA
        $ptsB = Get-Num $m.ptsB
        $newRows += [pscustomobject][ordered]@{
            run = $Run; config = $Cfg.name; weights_file = (Split-Path -Leaf $Cfg.weights_file)
            weights_fp = $Cfg.weights_fp; seed = $Seed; round = $info.round; first = (Get-FirstKey ([string]$m.first))
            a_side = [string]$m.a_side; lineup_used = $info.lineup_used; lineup_side = $info.lineup_side
            res = [string]$m.res; killsA = [string]$m.killsA; killsB = [string]$m.killsB
            rounds = [string]$m.rounds; ptsA = (Format-Num $ptsA 2); ptsB = (Format-Num $ptsB 2)
            dmgA = [string]$m.dmgA; dmgB = [string]$m.dmgB
            hpA = [string]$m.hpA; hpB = [string]$m.hpB; over = [string]$m.over
            subA = [string]$m.subA; subB = [string]$m.subB
            batch_out = (Split-Path -Leaf $r.OutPath); batch_wall_s = (Format-Num $r.WallSec 1)
            # _line_no (not _lineNo): ConvertFrom-RmLine writes the lowercase key. A PSCustomObject
            # property name IS case sensitive, so the old spelling threw PropertyNotFoundException
            # the moment a cell wrote a row here - which only ever happens on the parallel path (the
            # serial path repairs from the raw log and leaves line_no empty).
            seq = [string]$seq; line_no = [string]$m._line_no
            weights_sha12 = [string]$Cfg.meta.sha12
            beam_opp = [string]$beamOppUse; opp = [string]$oppUse; wB_sha = [string]$WBSha; inv = [string]$InvToken
            audit = (Get-AuditString $Cfg.meta $oppUse $WBSha $beamOppUse)
        }
    }
    Add-MeasureRows -Run $Run -Rows $newRows
    if ($parsed.summary.Count -gt 0) {
        $s = $parsed.summary[0]
        Write-Host ('[cell] ' + $Cfg.name + ' seed=' + $Seed + ' first=' + $First + ' opp=' + $oppUse +
                    $(if ($WBSha) { '(' + $WBSha + ')' } else { '' }) +
                    ' lineup=' + $info.lineup_used + '(' + $info.lineup_side + ') -> ' + $newRows.Count + ' game(s) | harness w=' + $s.w + ' l=' + $s.l + ' d=' + $s.d + ' search_ms_max=' + $s.search_ms_max + ' wall_s=' + $s.wall_s)
    }
    return [pscustomobject]@{ NewGames = $newRows.Count; WallSec = $r.WallSec; Cell = (Split-Path -Leaf $base) }
}

function Resolve-OneConfig {
    # Single source of truth for "which weights file + which beam does this config use", shared by the
    # parent (Resolve-Configs) and every worker so they can never disagree.
    param(
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Run
    )
    $specObj = @($Spec.configs | Where-Object { [string]$_.name -eq $Name })[0]
    if ($null -eq $specObj) { throw ('config not found in spec: ' + $Name) }
    $beams = Get-ConfigBeamSpec -Spec $Spec -CfgObj $specObj
    $beam = [int]$beams.candidate
    $beamOpp = [int]$beams.opponent
    if (($specObj.PSObject.Properties.Name -contains 'weights') -and $specObj.weights) {
        $wf = Join-Path $script:RepoRoot ([string]$specObj.weights)
    } else {
        $wf = Join-Path $script:RepoRoot ('RL\weights\cand_' + $Run + '_' + $Name + '.json')
    }
    if (-not (Test-Path -LiteralPath $wf)) { throw ('resolved weights file does not exist: ' + $wf) }
    return [pscustomobject]@{
        name = $Name; weights_file = $wf; beam = $beam; beam_opp = $beamOpp
        fp = (Get-WeightsFingerprint $wf); meta = (Get-WeightsMeta -Path $wf -Beam $beam -BeamOpp $beamOpp)
    }
}

function Get-CellList {
    # Work partition unit = one cell, where a cell is (config, seed, first, opp, wB_sha): the two sides
    # of the game are part of the identity, so a self-play cell and a fixed-opponent cell are planned
    # separately. A whole cell always goes to one worker so resumability (key = config+seed+first+seq+
    # opp+wB_sha) and pairing stay intact.
    param(
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object[]]$Configs,
        [Parameter(Mandatory = $true)][int[]]$Seeds,
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][string]$Run = '',
        # League split-scope (see Test-LeagueSelfPlay): `-Task equiv` passes one scope to both arms.
        [Parameter(Mandatory = $false)][string]$LeagueScope = ''
    )
    $existing = @{}
    if ($Run) { $existing = Get-MeasureKeys @(Read-MeasureRows $Run) }
    $lg = Get-LeagueConfig -Spec $Spec
    if ($lg -and ($lg.fraction -gt 0.0)) { Assert-LeagueCheckpoint -League $lg }
    $cells = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Configs) {
        $beamOpp = [int](Get-CfgBeamOpp $c)
        foreach ($sd in $Seeds) {
            foreach ($fs in @($Spec.measurement.firsts)) {
                $opp = 'base'; $wb = ''; $beamOppCell = $beamOpp
                if ($lg -and (Test-LeagueSelfPlay -Run $Run -Config ([string]$c.name) -Seed $sd -First $fs -Fraction $lg.fraction -Scope $LeagueScope)) {
                    $opp = 'cand'; $wb = [string]$lg.checkpoint_sha12
                    if (-not $wb) { throw ('league: self-play cell ' + $c.name + '/' + $sd + '/' + $fs + ' has no checkpoint sha12') }
                    # Self-play is a MIRROR match: the opponent is our own previous generation, so it
                    # plays at the candidate's beam. Giving it the weakened fixed-opponent beam (the
                    # spec's base_opp_beam) would measure "us vs a hobbled copy of us", not self-play.
                    $beamOppCell = [int]$c.beam
                }
                $need = $false
                $wantSeq = @(1..(@($Spec.measurement.asides).Count))
                foreach ($sq in $wantSeq) {
                    $key = Get-TupleKey -Config ([string]$c.name) -Seed $sd -First (Get-FirstKey $fs) -AKey 'X' -Seq $sq -Opp $opp -WBSha $wb
                    if ($Force -or (-not $existing.ContainsKey($key))) { $need = $true }
                }
                if ($need) {
                    $cells.Add([pscustomobject]@{ Config = [string]$c.name; Seed = [int]$sd; First = [string]$fs
                                                  Opp = $opp; WBSha = $wb; BeamOpp = $beamOppCell
                                                  WBFile = $(if ($opp -eq 'cand') { [string]$lg.checkpoint } else { '' }) })
                }
            }
        }
    }
    # Return a REAL object[] of cells. `return , $cells` handed back the List itself one level down, so
    # the caller's @(...) produced an array whose element 0 WAS the whole list: $cells.Count still read
    # as the right number (a List has .Count too, so nothing looked wrong) while $cells[0] was not a cell
    # at all -> the partition stored the list as if it were one cell and every worker got a bogus cell
    # whose .Config did not exist.
    return $cells.ToArray()
}

function Invoke-ParallelCells {
    <#
      Run cells across K workers. Each worker job:
        * has its OWN results dir results/<Run>/w<k>/ (never shares measure.csv),
        * its OWN APPDATA sandbox (isolated Godot user://),
        * its own .out / .godot.log / .gcdpid files.
      The parent then merges all worker rows into the main run and repairs from the merged raw log,
      so duplicate/missing cells are a hard, checkable property rather than a hope.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object[]]$Configs,
        [Parameter(Mandatory = $true)][object[]]$Cells,
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][string]$SpecPath,
        [Parameter(Mandatory = $false)][int]$Workers = 6,
        [Parameter(Mandatory = $false)][string]$SandboxRoot = '',
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 3600,
        # League split-scope; forwarded to the worker so it recomputes the same opponent per cell.
        [Parameter(Mandatory = $false)][string]$LeagueScope = ''
    )
    if ($Cells.Count -eq 0) { return [pscustomobject]@{ Batches = 0; NewGames = 0; GodotWallSec = 0.0; WallSec = 0.0 } }
    $k = [Math]::Max(1, [Math]::Min(10, $Workers))
    if (-not $SandboxRoot) { $SandboxRoot = Join-Path $env:TEMP 'dsh_godot_workers' }
    $configNames = @($Configs | ForEach-Object { [string]$_.name })
    # Configs as plain strings/numbers only (meta flattened to the scalar fields Get-AuditString reads),
    # so the values survive the Start-Job serialization boundary unchanged.
    $cfgList = @()
    foreach ($c in $Configs) {
        $m = $c.meta
        $cfgList += [pscustomobject]@{
            name = [string]$c.name; weights_file = [string]$c.weights_file; beam = [int]$c.beam
            beam_opp = [int](Get-CfgBeamOpp $c)
            weights_fp = [string]$c.weights_fp
            meta = [pscustomobject]@{
                sha12 = [string]$m.sha12; beam = [int]$m.beam; beam_opp = [int]$m.beam_opp
                opp = 'base'; wB_sha = ''
                jitter = [double]$m.jitter
                kill_bonus = [double]$m.kill_bonus; focus_fire = [double]$m.focus_fire
                engage_pull = [double]$m.engage_pull; threat = [double]$m.threat
                vip = [double]$m.vip
                hero_value_n = [int]$m.hero_value_n; hero_value_changed = [int]$m.hero_value_changed
                entries = [int]$m.entries; script_hash = [string]$m.script_hash
            }
        }
    }
    # round-robin partition (cells are already grouped by config then seed, so this spreads seeds)
    $parts = @()
    for ($i = 0; $i -lt $k; $i++) { $parts += , (New-Object System.Collections.Generic.List[object]) }
    for ($i = 0; $i -lt $Cells.Count; $i++) { $parts[$i % $k].Add($Cells[$i]) }
    $libPath = Join-Path $PSScriptRoot 'RlTrain.ps1'
    $t0 = Get-Date
    $jobs = @()
    $workerRuns = @()
    for ($w = 0; $w -lt $k; $w++) {
        if ($parts[$w].Count -eq 0) { continue }
        # .ToArray(), NOT @($parts[$w]): in PowerShell 5.1 the array subexpression operator cannot
        # convert a generic List[object] (it throws "ArgumentException: Argument types do not match"),
        # and it throws the moment the list holds exactly one item - i.e. exactly when K >= cell count,
        # which is the normal case for a small run. The exception came out of this line before any
        # worker was started, so the parallel arm died instantly and wrote nothing but its manifest.
        $wCells = $parts[$w].ToArray()
        # Worker dirs live UNDER the run (results/<Run>/w<k>): the pool is per-run, so a row measured for
        # run A can never be folded into run B. A global results/w<k> pool is what silently re-used rows
        # measured under an older harness/weights after a code change.
        $wRun = Join-Path $Run ('w' + ($w + 1))
        $wTag = 'w' + ($w + 1)
        $wSandbox = Join-Path $SandboxRoot $wTag
        $workerRuns += $wRun
        Write-Host ('[par] worker ' + ($w + 1) + ': cells=' + $wCells.Count + ' run=' + $wRun + ' appdata=' + $wSandbox)
        $jobs += Start-Job -ScriptBlock {
            param($Lib, $SpecFile, $RunName, $Payload, $Sandbox, $Timeout, $WorkerTag)
            $ErrorActionPreference = 'Stop'
            $CfgList = @($Payload.Cfgs)
            $CellList = @($Payload.Cells)
            # Pre-flight gate: the parent states how many cells it sent. If the list arrives short (job
            # argument truncation, a future refactor of the payload, a bad @()-unroll) the run must stop
            # HERE, while it is still obvious, instead of quietly measuring a subset.
            $expect = [int]$Payload.ExpectCells
            if ($CellList.Count -ne $expect) {
                throw ('PARALLEL WORKER ' + $WorkerTag + ': received ' + $CellList.Count + ' cell(s) but the parent sent ' + $expect +
                       ' -- refusing to run a partial worker (possible job-payload truncation)')
            }
            if ($CfgList.Count -eq 0) { throw ('PARALLEL WORKER ' + $WorkerTag + ': received 0 configs') }
            Write-Host ('[par]   ' + $WorkerTag + ': start cfg=' + $CfgList.Count + ' cells=' + $CellList.Count + '/' + $expect)
            . $Lib
            $spec = Read-TrainSpec $SpecFile
            # Use the configs the PARENT already resolved instead of calling Resolve-OneConfig here:
            # that function derives the default weights path from -Run, and a worker's run name is its
            # own dir, which used to make every worker look for RL/weights/cand_w1_<cfg>.json and throw
            # "resolved weights file does not exist" before its first cell.
            $cfgMap = @{}
            foreach ($one in $CfgList) { $cfgMap[[string]$one.name] = $one }
            Write-Host ('[par]   ' + $WorkerTag + ': cfgMap=[' + ($cfgMap.Keys -join ',') + ']')
            $games = 0; $wall = 0.0; $done = 0
            foreach ($cell in $CellList) {
                $cfg = $cfgMap[[string]$cell.Config]
                # A cell whose config is unknown is a PLAN bug, not a reason to skip work silently
                # (the old `continue` here was another way a worker could report success with fewer
                # games than it was given).
                if ($null -eq $cfg) {
                    throw ('PARALLEL WORKER ' + $WorkerTag + ': cell ' + [string]$cell.Config + '/' + [string]$cell.Seed + '/' +
                           [string]$cell.First + ' has no config in the payload (payload configs=' + ($cfgMap.Keys -join ',') + ')')
                }
                $r = Invoke-GodotCell -Cfg $cfg -Seed ([int]$cell.Seed) -First ([string]$cell.First) `
                     -Spec $spec -Run $RunName -AppData $Sandbox -TimeoutSec $Timeout `
                     -Opp ([string]$cell.Opp) -WeightsB ([string]$cell.WBFile) -WBSha ([string]$cell.WBSha) `
                     -BeamOpp ([int]$cell.BeamOpp) -FixedDecks:([bool]$Payload.FixedDecks)
                $done++
                $games += $r.NewGames
                $wall += $r.WallSec
            }
            if ($done -ne $expect) {
                throw ('PARALLEL WORKER ' + $WorkerTag + ': processed ' + $done + ' of ' + $expect + ' assigned cell(s)')
            }
            return [pscustomobject]@{ Worker = $WorkerTag; Games = $games; WallSec = $wall; Cells = $done; Expected = $expect }
        # `-ArgumentList` FLATTENS arrays: passing the cell/config arrays as separate arguments unrolled
        # them, so a worker with ONE cell received it as three positional values ($CellList='10001',
        # $Sandbox='p', $Timeout='e'), its config lookup matched nothing and it reported Games=0 with no
        # error at all (and took the whole parallel arm down with it). [object[]]$x does NOT survive the
        # bind either - wrapping both arrays in ONE hashtable is what actually keeps them intact.
        } -ArgumentList @($libPath, $SpecPath, $wRun, @{ Cfgs = @($cfgList); Cells = @($wCells); ExpectCells = [int]$wCells.Count; FixedDecks = [bool]$FixedDecks }, $wSandbox, $TimeoutSec, ('w' + ($w + 1)))
    }
    Write-Host ('[par] ' + $jobs.Count + ' worker job(s) started; waiting...')
    $plannedCells = [int]$Cells.Count
    $plannedGames = 0
    foreach ($c in $parts) { $plannedGames += ($c.Count * @($Spec.measurement.asides).Count) }
    $deadline = (Get-Date).AddSeconds(($TimeoutSec * 2) + 300)
    # If this fires, cells are simply NOT run. It used to `break` out and merge whatever existed, i.e. the
    # run silently reported exit=0 while ~31% of the plan was never started ("all workers done" was true,
    # the work was not). A timeout is a FAILED run; it must never look like a finished one.
    $deadlineHit = $false
    while ($true) {
        $running = @($jobs | Where-Object { $_.State -eq 'Running' })
        if ($running.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) {
            $deadlineHit = $true
            Write-Host ('[par] !! GLOBAL DEADLINE HIT after ' + [int]((Get-Date) - $t0).TotalSeconds + 's of a ' +
                        (($TimeoutSec * 2) + 300) + 's budget (' + $TimeoutSec + 's x2 + 300s); stopping ' +
                        $running.Count + ' remaining worker(s)')
            foreach ($j in $running) {
                Stop-Job -Job $j -ErrorAction SilentlyContinue
            }
            break
        }
        Write-Host ('[par] ' + $running.Count + '/' + $jobs.Count + ' worker(s) running, elapsed ' + [int]((Get-Date) - $t0).TotalSeconds + 's')
        Start-Sleep -Seconds 30
    }
    $results = @()
    $failed = @()
    foreach ($j in $jobs) {
        $tag = [string]$j.Name
        # Read the errors BEFORE Receive-Job -ErrorAction SilentlyContinue used to throw them away: a
        # worker that died in its first cell reported nothing at all, so parallelism looked like
        # "0 rows written, no reason given". Worker stdout is echoed now, and a failed worker is fatal.
        $werr = @($j.ChildJobs[0].Error)
        $rcv = @(Receive-Job -Job $j -ErrorAction SilentlyContinue -ErrorVariable +werr)
        foreach ($o in $rcv) { Write-Host ('[par]   ' + $tag + ': ' + [string]$o) }
        foreach ($o in $rcv) { if ($o -is [psobject] -and ($o.PSObject.Properties.Name -contains 'Games')) { $results += $o } }
        if ($j.State -eq 'Failed' -or $werr.Count -gt 0) {
            $failed += $tag
            Write-Host ('[par] !! worker ' + $tag + ' FAILED (state=' + $j.State + ')')
            foreach ($e in ($werr | Select-Object -First 5)) { Write-Host ('[par] !!   ' + $e.ToString()) }
            if ($j.JobStateInfo.Reason) { Write-Host ('[par] !!   reason: ' + $j.JobStateInfo.Reason.Message) }
        }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
    $wallAll = ((Get-Date) - $t0).TotalSeconds
    Write-Host ('[par] all workers done in ' + [int]$wallAll + 's')
    # ---- accounting gate: every planned cell must have been STARTED and returned its games ----
    $doneCells = 0; $doneGames = 0
    foreach ($o in $results) { $doneCells += [int]$o.Cells; $doneGames += [int]$o.Games }
    Write-Host ('[par] accounting: cells planned=' + $plannedCells + ' completed=' + $doneCells +
                ' | games planned=' + $plannedGames + ' produced=' + $doneGames)
    if ($results.Count -ne $jobs.Count) {
        throw ('Invoke-ParallelCells: only ' + $results.Count + ' of ' + $jobs.Count + ' worker(s) reported a result; refusing to merge')
    }
    if ($failed.Count -gt 0) {
        throw ('Invoke-ParallelCells: ' + $failed.Count + ' of ' + $jobs.Count + ' worker job(s) failed (' + ($failed -join ',') + '); see the [par] !! lines above. Refusing to merge a partial result.')
    }
    if ($doneCells -ne $plannedCells) {
        $miss = $plannedCells - $doneCells
        $perCfg = @{}
        foreach ($c in $Cells) { $n = [string]$c.Config; if ($perCfg.ContainsKey($n)) { $perCfg[$n]++ } else { $perCfg[$n] = 1 } }
        # Which configs are short: count what actually landed in the worker tables.
        $gotCfg = @{}
        foreach ($wr in $workerRuns) {
            foreach ($r in @(Read-MeasureRows $wr)) {
                $n = [string]$r.config
                if ($gotCfg.ContainsKey($n)) { $gotCfg[$n] += 1 } else { $gotCfg[$n] = 1 }
            }
        }
        $bad = @()
        foreach ($n in ($perCfg.Keys | Sort-Object)) {
            $planned = [int]$perCfg[$n] * @($Spec.measurement.asides).Count
            $got = 0; if ($gotCfg.ContainsKey($n)) { $got = [int]$gotCfg[$n] }
            if ($got -lt $planned) { $bad += ($n + ': ' + $got + '/' + $planned + ' game(s), short ' + ($planned - $got)) }
        }
        $msg = 'TRUNCATED PARALLEL RUN: ' + $doneCells + ' of ' + $plannedCells + ' cell(s) completed (' + $miss + ' missing, ' +
               $doneGames + ' of ' + $plannedGames + ' game(s) produced).'
        if ($deadlineHit) { $msg += ' The global deadline stopped workers before they finished.' }
        $msg += ' Refusing to merge a partial result. Raise -TimeoutSec (deadline = TimeoutSec*2 + 300s) or re-run the same command to resume the missing cells.'
        Write-Host ('[par] !! ' + $msg)
        foreach ($b in $bad) { Write-Host ('[par] !!   short config ' + $b) }
        throw ($msg + ' Short configs: ' + $(if ($bad.Count -gt 0) { $bad -join ' ; ' } else { 'none identified' }))
    }
    if ($doneGames -ne $plannedGames) {
        Write-Host ('[par] !! cell count matches (' + $doneCells + ') but games differ: planned=' + $plannedGames + ' produced=' + $doneGames +
                    ' (a cell can legitimately produce 0 rows when the harness dies on that lineup)')
    }
    if ($failed.Count -gt 0) {
        throw ('Invoke-ParallelCells: ' + $failed.Count + ' of ' + $jobs.Count + ' worker job(s) failed (' + ($failed -join ',') + '); see the [par] !! lines above. Refusing to merge a partial result.')
    }
    return [pscustomobject]@{ Results = $results; WallSec = $wallAll; Workers = $k; WorkerRuns = $workerRuns
                             PlannedCells = $plannedCells; DoneCells = $doneCells; PlannedGames = $plannedGames; DoneGames = $doneGames }
}

function Merge-WorkerResults {
    # Append every worker's measure.csv rows into the main run, then rebuild the main measure.csv from
    # the merged raw log (which dedups by measurement key) and report completeness.
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $false)][string[]]$WorkerRuns = @(),
        # The resolved configs of THIS run. When given, a pooled row is only accepted if its version
        # fingerprint (script hashes, weights sha12, opponent, beams) still matches what this run would
        # measure. This is the gate that stops "reuse a row measured by an older harness/weights".
        [Parameter(Mandatory = $false)][object[]]$Configs = @()
    )
    if ($WorkerRuns.Count -eq 0) {
        # The callers pass the worker run names explicitly (Invoke-ParallelCells returns them); this
        # fallback looks for the same per-run pool, results/<Run>/w<k>.
        $WorkerRuns = @(Get-ChildItem (Get-ResultsDir $Run) -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^w[0-9]+$' } | ForEach-Object { $_.Name })
    }
    $merged = 0
    $skipped = 0
    $fpByConfig = $null
    $lg = $null
    if ($Configs.Count -gt 0) {
        $fpByConfig = New-VersionFingerprints -Spec $Spec -Configs $Configs
        $lg = Get-LeagueConfig -Spec $Spec
    }
    foreach ($wr in $WorkerRuns) {
        $wRows = @(Read-MeasureRows $wr)
        if ($wRows.Count -gt 0) {
            if ($null -ne $fpByConfig) {
                $keep = New-Object System.Collections.Generic.List[object]
                foreach ($r in $wRows) {
                    $cn = [string]$r.config
                    if (-not $fpByConfig.ContainsKey($cn)) {
                        $skipped++
                        if ($skipped -le 20) { Write-Host ('[merge] !! reused-pool row skipped: config ' + $cn + ' is not part of this run config=' + $cn + ' seed=' + [string]$r.seed) }
                        continue
                    }
                    # Which arm did this row play? Recompute it (deterministic) instead of trusting the
                    # pool, then require the row to match THAT arm's fingerprint.
                    $rowOpp = Get-RowField $r 'opp' 'base'
                    $cellOpp = 'base'; $cellWb = ''
                    if ($lg) {
                        $cellOpp = 'base'; $cellWb = ''
                        if (Test-LeagueSelfPlay -Run $Run -Config $cn -Seed ([int]$r.seed) -First ([string]$r.first) -Fraction $lg.fraction) {
                            $cellOpp = 'cand'; $cellWb = [string]$lg.checkpoint_sha12
                        }
                    }
                    $exp = Get-LeagueFingerprint -Fp $fpByConfig[$cn] -Opp $cellOpp -WBSha $cellWb
                    $bad = Get-FingerprintMismatch -Row $r -Expect $exp
                    if (-not $bad -and ($rowOpp -ne $cellOpp)) {
                        $bad = ('opp 不同 (pool=' + $rowOpp + ' vs now=' + $cellOpp + ')')
                    }
                    if ($bad) {
                        # A pooled row measured under different rules/weights/harness/opponent. Do NOT
                        # merge it: silently doing that is what made a post-harness-change re-run report
                        # the pre-change table with exit=0.
                        $skipped++
                        if ($skipped -le 20) {
                            Write-Host ('[merge] !! reused-pool row skipped: ' + $bad + ' config=' + $cn + ' seed=' + [string]$r.seed)
                        }
                        continue
                    }
                    $keep.Add($r)
                }
                if ($skipped -gt 20) { Write-Host ('[merge] !! (' + $skipped + ' mismatching pooled row(s) skipped in total)') }
                $wRows = $keep.ToArray()
            }
            if ($wRows.Count -gt 0) {
                # copy rows verbatim into the main run (config/seed keys keep them unique after repair)
                Add-MeasureRows -Run $Run -Rows $wRows
                $merged += $wRows.Count
            }
        }
        # append the worker's verbatim raw lines so the merged log is the single source of truth, but
        # KEEP a `# ---- ` header in front of EVERY batch: Repair-MeasureCsv reads config/seed/first/
        # e_deck/p_deck from that header, so a single "merged from wX" header for a whole worker
        # silently produced rows with an empty config and empty/0 in every other column.
        $wRaw = Get-RawLogPath $wr
        if (Test-Path -LiteralPath $wRaw) {
            # Keep the `# ---- ` batch headers and drop every OTHER comment: the header is where
            # Repair-MeasureCsv reads config/seed/first/e_deck/p_deck from, so filtering out all
            # '#'-lines (as this used to) threw away exactly the data the merge needed.
            $lines = @([System.IO.File]::ReadAllLines($wRaw, [System.Text.Encoding]::UTF8) |
                       Where-Object { $_.StartsWith('# ---- ') -or (-not $_.StartsWith('#')) })
            $hdr = ('merged from ' + $wr)
            $batch = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $lines) {
                if ($ln.StartsWith('# ---- ')) {
                    if ($batch.Count -gt 0) { Add-RawLines -Run $Run -Lines $batch.ToArray() -Header $hdr; $batch.Clear() }
                    $hdr = ($ln.Substring(7).Trim() + ' merged_from=' + $wr)
                    continue
                }
                $batch.Add($ln)
            }
            if ($batch.Count -gt 0) { Add-RawLines -Run $Run -Lines $batch.ToArray() -Header $hdr }
        }
    }
    Write-Host ('[merge] appended ' + $merged + ' row(s) from ' + $WorkerRuns.Count + ' worker run(s)' +
                $(if ($skipped -gt 0) { ' ; ' + $skipped + ' pooled row(s) SKIPPED as version-mismatched' } else { '' }))
    $n = Repair-MeasureCsv -Run $Run -Spec $Spec
    Write-Host ('[merge] main measure.csv rebuilt with ' + $n + ' unique measurement(s)')
    return $n
}

function New-VersionFingerprint([object]$Spec, [object]$Cfg) {
    <#
      Everything that decides what a measured game MEANS. A row from the worker pool may only be reused
      when every field below is unchanged - the pool is plain files on disk and carries no version of its
      own, so a harness edit or a weight change used to be invisible and the old rows were re-used silently.
        cand  : candidate script hash        (RL/ai/AI_Battle.gd)
        base  : opponent copy hash           (RL/ai/AI_Battle_原版.gd)
        duel  : harness hash                 (RL/harness/对局.gd)
        skil  : skill-parity script hash
        wA    : candidate weights sha12      (this run's cand_<run>_<cfg>.json)
        wFp   : candidate weights SEMANTIC fingerprint (only the keys the AI reads, `_` notes ignored)
        opp   : opponent type                (base | cand)
        wB    : opponent weights sha12       (empty for base)
        bA/bB : the beams actually used
    #>
    $h = Get-ScriptHashes
    $beamOpp = [int](Get-CfgBeamOpp $Cfg)
    return [ordered]@{
        cand = [string]$h.cand
        base = [string]$h.base
        duel = [string]$h.duel
        skil = [string]$h.skil
        wA = [string](Get-Sha256Hex12 ([string]$Cfg.weights_file))
        wFp = [string](Get-WeightsFingerprint ([string]$Cfg.weights_file))
        opp = 'base'
        wB = ''
        bA = [string][int]$Cfg.beam
        bB = [string]$beamOpp
    }
}

function Get-FingerprintMismatch([object]$Row, [object]$Expect) {
    <#
      Compare one pooled row against the expected fingerprint. The row carries its version in its own
      columns (weights_sha12 / beam_opp / opp / wB_sha) and, for the script hashes, in the `scripts[...]`
      tail of its audit string. Returns '' when the row may be reused, else a human-readable reason.
    #>
    if ($null -eq $Expect) { return '' }
    $why = @()
    # candidate weights. ⚠️ 2026-09-22：`cand_<run>_<cfg>.json` 由本脚本生成、里面**带生成时间戳**
    # （`_rl_generated = '… generated by RlTrain.ps1 at <yyyy-MM-dd HH:mm:ss>'`，见本文件 :424-428）
    # ⇒ 它的 sha256 **每次调用都不同**。只比 sha12 的后果是：**任何一次重入都把该 run 已有的行
    # 判成"另一版本"丢掉并全量重测**（实测复现：同一格连跑两次，第 2 次照样重打；日志
    # `2 row(s): weights sha12 不同 (pool=… vs now=…)` → `nothing reusable is left`）。
    # 所以改成：sha12 不同时，再看**语义指纹** `weights_fp`（`Get-WeightsFingerprint` 只算 AI
    # 真读的键、忽略 `_` 开头的注释，跨调用稳定）——语义一致就允许复用。
    $wA = Get-RowField $Row 'weights_sha12'
    $wFp = Get-RowField $Row 'weights_fp'
    $sameSem = ($wFp -and ([string]$Expect.wFp) -and ([string]$wFp -eq [string]$Expect.wFp))
    if (($wA -ne [string]$Expect.wA) -and (-not $sameSem)) { $why += ('weights sha12 不同 (pool=' + $wA + ' vs now=' + [string]$Expect.wA + ')') }
    # script hashes: the frozen set the row was measured under
    $audit = Get-RowField $Row 'audit'
    foreach ($tok in @('base', 'duel', 'skil')) {
        $m = [regex]::Match($audit, ($tok + '=([0-9a-f]{12})'))
        $got = ''
        if ($m.Success) { $got = $m.Groups[1].Value }
        if ($got -and ($got -ne [string]$Expect[$tok])) { $why += ($tok + ' 不同 (pool=' + $got + ' vs now=' + [string]$Expect[$tok] + ')') }
    }
    $opp = Get-RowField $Row 'opp' 'base'
    if (-not $opp) { $opp = 'base' }
    if ($opp -ne [string]$Expect.opp) { $why += ('opp 不同 (pool=' + $opp + ' vs now=' + [string]$Expect.opp + ')') }
    $wb = Get-RowField $Row 'wB_sha'
    if ($wb -ne [string]$Expect.wB) { $why += ('wB_sha 不同 (pool=' + $wb + ' vs now=' + [string]$Expect.wB + ')') }
    $bA = Get-RowField $Row 'beam_opp'
    if ($bA -and ($bA -ne [string]$Expect.bB)) { $why += ('beamB 不同 (pool=' + $bA + ' vs now=' + [string]$Expect.bB + ')') }
    if ($why.Count -eq 0) { return '' }
    return ($why -join ' ; ')
}

function New-VersionFingerprints([object]$Spec, [object[]]$Configs) {
    <# One fingerprint per config: the pool may hold rows of several configs (and of several league arms),
       and each must be checked against its own identity. For league runs the caller then stamps the
       opponent fields per row from the cell identity (Get-LeagueFingerprint). #>
    $out = @{}
    foreach ($c in $Configs) { $out[[string]$c.name] = (New-VersionFingerprint -Spec $Spec -Cfg $c) }
    return $out
}

function Get-LeagueFingerprint([object]$Fp, [string]$Opp, [string]$WBSha) {
    # Stamp the opponent identity onto a config fingerprint so a self-play row only matches self-play.
    $c = [ordered]@{}
    foreach ($k in $Fp.Keys) { $c[$k] = $Fp[$k] }
    $c.opp = $(if ($Opp) { $Opp } else { 'base' })
    $c.wB = $(if ($WBSha) { $WBSha } else { '' })
    return $c
}

function Test-ExistingRowsFingerprint([string]$Run, [object]$Spec, [object[]]$Configs, [object]$League) {
    <#
      The resume index comes from measure.csv, so a table written by an older harness / older weights /
      a different opponent arm would be accepted as "already measured" and the run would report success
      without playing anything. That is exactly the reported symptom: after a harness change p1v3/p1v4
      returned the pre-change table with exit=0. Every existing row is therefore fingerprinted before it
      may count as measured; stale rows are DROPPED (reported, with a count per reason) and their cells
      get re-measured. measure.csv is derived data, so dropping is safe: the raw log keeps the old lines
      and Repair-MeasureCsv rebuilds the table from whatever was actually re-measured. Rows of configs
      this invocation did not ask for are left alone.
    #>
    $p = Join-Path (Get-ResultsDir $Run) 'measure.csv'
    if (-not (Test-Path -LiteralPath $p)) { return }
    $rows = @(Read-MeasureRows $Run)
    if ($rows.Count -eq 0) { return }
    $fpByConfig = New-VersionFingerprints -Spec $Spec -Configs $Configs
    $keep = New-Object System.Collections.Generic.List[object]
    $reason = @{}
    $dropped = 0
    foreach ($r in $rows) {
        $cn = Get-RowField $r 'config'
        if (-not $fpByConfig.ContainsKey($cn)) { $keep.Add($r); continue }
        $exp = $fpByConfig[$cn]
        if ($League -and ($League.fraction -gt 0.0)) {
            $armOpp = 'base'; $armWb = ''
            if (Test-LeagueSelfPlay -Run $Run -Config $cn -Seed ([int](Get-RowField $r 'seed' '0')) -First (Get-RowField $r 'first' '') -Fraction $League.fraction -Scope $LeagueScope) {
                $armOpp = 'cand'; $armWb = [string]$League.checkpoint_sha12
            }
            $exp = Get-LeagueFingerprint -Fp $exp -Opp $armOpp -WBSha $armWb
        } else {
            $exp = Get-LeagueFingerprint -Fp $exp -Opp ([string]$Spec.opponent) -WBSha ''
        }
        $bad = Get-FingerprintMismatch -Row $r -Expect $exp
        if ($bad) {
            $dropped++
            $key = ($bad -split ' ; ')[0]
            if ($reason.ContainsKey($key)) { $reason[$key]++ } else { $reason[$key] = 1 }
            continue
        }
        $keep.Add($r)
    }
    if ($dropped -eq 0) {
        Write-Host ('[run] fingerprint: all ' + $rows.Count + ' existing row(s) match this version/weights/opponent')
        return
    }
    Write-Host ('[run] !! ' + $dropped + ' of ' + $rows.Count + ' existing row(s) do NOT match this run''s version fingerprint -> dropped, will be re-measured:')
    foreach ($k in ($reason.Keys | Sort-Object)) { Write-Host ('[run] !!   ' + $reason[$k] + ' row(s): ' + $k) }
    if ($keep.Count -eq 0) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        Write-Host '[run] !! nothing reusable is left -> the table will be rebuilt from scratch'
        return
    }
    $keep.ToArray() | Select-Object (Get-MeasureColumns) | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8
}

function Test-RunCompleteness {
    # Hard check: every (config, seed, first, seq, opp, wB_sha) the run was asked to cover must be present
    # exactly once. The opponent comes from the same deterministic league rule the planner uses, so a
    # self-play cell that never ran shows up as missing instead of being excused by a base-opponent row.
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string[]]$ConfigNames,
        [Parameter(Mandatory = $true)][int[]]$Seeds
    )
    $lg = Get-LeagueConfig -Spec $Spec
    $rows = @(Read-MeasureRows $Run)
    $seen = @{}
    $dups = @()
    foreach ($r in $rows) {
        $k = Get-TupleKey -Config ([string]$r.config) -Seed $r.seed -First (Get-FirstKey ([string]$r.first)) -AKey 'X' -Seq ([string]$r.seq) `
             -Opp (Get-RowField $r 'opp' 'base') -WBSha (Get-RowField $r 'wB_sha')
        if ($seen.ContainsKey($k)) { $dups += $k } else { $seen[$k] = $true }
    }
    $missing = @()
    foreach ($cn in $ConfigNames) {
        foreach ($sd in $Seeds) {
            foreach ($fs in @($Spec.measurement.firsts)) {
                $opp = 'base'; $wb = ''
                if ($lg -and (Test-LeagueSelfPlay -Run $Run -Config $cn -Seed $sd -First $fs -Fraction $lg.fraction -Scope $LeagueScope)) {
                    $opp = 'cand'; $wb = [string]$lg.checkpoint_sha12
                }
                foreach ($sq in @(1..(@($Spec.measurement.asides).Count))) {
                    $k = Get-TupleKey -Config $cn -Seed $sd -First (Get-FirstKey $fs) -AKey 'X' -Seq $sq -Opp $opp -WBSha $wb
                    if (-not $seen.ContainsKey($k)) { $missing += $k }
                }
            }
        }
    }
    return [pscustomobject]@{ Rows = $rows.Count; Duplicates = $dups.Count; Missing = $missing.Count; MissingKeys = $missing; DuplicateKeys = $dups }
}

# ============================ run engine ============================

function Start-MeasureRun {
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][object[]]$Configs,
        [Parameter(Mandatory = $true)][int[]]$Seeds,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 3600,
        [Parameter(Mandatory = $false)][switch]$FixedDecks,
        [Parameter(Mandatory = $false)][int]$Workers = 1,
        [Parameter(Mandatory = $false)][string]$SpecPath = '',
        [Parameter(Mandatory = $false)][switch]$AllowHashChange,
        # League split-scope. The default scope is the run name, so two different runs would assign
        # different opponents to the same cell; `-Task equiv` passes ONE scope to both arms so they
        # measure the same cells against the same opponents and stay comparable.
        [Parameter(Mandatory = $false)][string]$LeagueScope = ''
    )
    if (-not $SpecPath) { $SpecPath = Join-Path $PSScriptRoot 'train_spec.json' }
    # -FixedDecks now works WITH parallel workers. The old restriction (Workers>1 is not supported
    # together with -FixedDecks) would force every "one fixed lineup, only the ratios change" run to be
    # serial, which is exactly the run the joint search needs and would be far too slow. The decks live
    # in the spec, every worker reads that same spec, and -FixedDecks is forwarded in the job payload.
    $dir = Get-ResultsDir $Run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Hard guard first: refuse to add rows measured under a different version of the rules/candidate.
    [void](Assert-ScriptHashes -Run $Run -AllowHashChange:$AllowHashChange)
    $lockPath = Enter-RunLock -Run $Run
    try {
    $fpSeen = @{}
    foreach ($c in $Configs) {
        $fp = Get-WeightsFingerprint $c.weights_file
        $c | Add-Member -NotePropertyName weights_fp -NotePropertyValue $fp -Force
        $c | Add-Member -NotePropertyName beam_opp -NotePropertyValue ([int](Get-CfgBeamOpp $c)) -Force
        $c | Add-Member -NotePropertyName meta -NotePropertyValue (Get-WeightsMeta -Path $c.weights_file -Beam ([int]$c.beam) -BeamOpp ([int](Get-CfgBeamOpp $c))) -Force
        if ($fpSeen.ContainsKey($fp)) {
            Write-Host ('[cfg] WARNING ' + $c.name + ' has the same weight fingerprint as ' + $fpSeen[$fp] + ' (fp=' + $fp + ') -> the two configs are indistinguishable')
        } else { $fpSeen[$fp] = $c.name }
        Write-Host ('[cfg] ' + $c.name + ' file=' + (Split-Path -Leaf $c.weights_file) + ' fp=' + $fp +
                    ' sha12=' + $c.meta.sha12 + ' beamA=' + [int]$c.beam + ' beamB=' + [int](Get-CfgBeamOpp $c) +
                    ' | ' + (Get-AuditString $c.meta))
    }
    # ---- league (self-play mixing) ----
    # Resolved BEFORE the table fingerprint check, because which arm a cell plays is part of the
    # fingerprint (a base-opponent row must not satisfy a self-play cell).
    $league = Get-LeagueConfig -Spec $Spec
    if ($league -and ($league.fraction -gt 0.0)) { Assert-LeagueCheckpoint -League $league }
    # GATE: one opponent per (seed, first) across every config of this run, otherwise the paired
    # comparison this run is FOR would silently mix parameter and opponent effects.
    Assert-LeagueArmConsistency -Run $Run -Spec $Spec -Configs $Configs -Seeds $Seeds -LeagueScope $LeagueScope
    # Version gate on what is ALREADY in the table, before it can count as "measured". Without this the
    # resume index happily accepted rows measured by another harness / another weights file / another
    # opponent arm, and the run reported success while playing nothing.
    if (-not $Force) { Test-ExistingRowsFingerprint -Run $Run -Spec $Spec -Configs $Configs -League $league }
    $rowsNow = @(Read-MeasureRows $Run)
    $rawLogPath0 = Get-RawLogPath $Run
    if ($rowsNow.Count -eq 0 -and (Test-Path -LiteralPath $rawLogPath0)) {
        # measure.csv is derived data and must agree with the append-only raw log. If the table was
        # wiped/truncated while the log still holds an older invocation's lines, repairing from that log
        # resurrects rows that no longer exist in the table - which is how the parallel arm of -Task
        # equiv ended up with ~10 rows for 8 games. Empty table + non-empty log is an inconsistent
        # state, so reset the derived side.
        Write-Host '[run] measure.csv is empty but raw_lines.log is not -> resetting the derived log'
        Remove-Item -LiteralPath $rawLogPath0 -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path (Get-ResultsDir $Run) 'summary.csv') -Force -ErrorAction SilentlyContinue
    }
    $existing = Get-MeasureKeys $rowsNow
    Write-Host ('[run] resume index: ' + $existing.Count + ' measured tuple(s) already present')
    if ($league) {
        if ($league.fraction -le 0.0) {
            Write-Host ('[league] disabled (self_play_fraction=0) -> every cell uses opp=' + [string]$Spec.opponent)
        } else {
            # Report the split that the planner WILL produce, by running the same deterministic test the
            # planner runs - so the printed numbers are the real plan, not an estimate.
            $nSelf = 0; $nBase = 0
            foreach ($c in $Configs) {
                foreach ($sd in $Seeds) {
                    foreach ($fs in @($Spec.measurement.firsts)) {
                        if (Test-LeagueSelfPlay -Run $Run -Config ([string]$c.name) -Seed $sd -First $fs -Fraction $league.fraction -Scope $LeagueScope) { $nSelf++ } else { $nBase++ }
                    }
                }
            }
            Write-Host ('[league] self-play cells=' + $nSelf + '  base cells=' + $nBase +
                        '  fraction=' + $league.fraction +
                        '  checkpoint=' + $league.checkpoint_name + ' sha12=' + $league.checkpoint_sha12)
            Write-Host ('[league] assignment rule: sha256(run|config|seed|first) top-32-bits / 2^32 < fraction -> self-play; deterministic, so the same cells are self-play every generation')
        }
    } else {
        Write-Host ('[league] no league block in the spec -> every cell uses opp=' + [string]$Spec.opponent)
    }
    $totalGames = 0; $ranBatches = 0; $wallTotal = 0.0
    if ($Workers -gt 1) {
        # ---- parallel path: independent worker jobs, one sandbox each, merged afterwards ----
        # A truncated parallel run (deadline, crash, Ctrl-C) leaves finished cells in results/<Run>/w<k>/.
        # Those are folded back in FIRST (so only the truly missing cells are planned), but each row must
        # still match this run's version fingerprint - a pooled row measured under another harness,
        # another weights file, another opponent or another beam is SKIPPED and named, never reused.
        if (-not $Force) {
            $preRuns = @(Get-ChildItem (Get-ResultsDir $Run) -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match '^w[0-9]+$' } | ForEach-Object { $_.Name })
            $preRows = 0
            foreach ($wr in $preRuns) { $preRows += @(Read-MeasureRows $wr).Count }
            if ($preRows -gt 0) {
                Write-Host ('[run] pool: ' + $preRows + ' row(s) already in ' + (Get-ResultsDir $Run) + '\w* -> fingerprint-checked before reuse (-Force would ignore them)')
                [void](Merge-WorkerResults -Run $Run -Spec $Spec -WorkerRuns $preRuns -Configs $Configs)
                $existing = Get-MeasureKeys @(Read-MeasureRows $Run)
                Write-Host ('[run] resume index after pool merge: ' + $existing.Count + ' measured tuple(s)')
            }
        }
        $cells = @(Get-CellList -Spec $Spec -Configs $Configs -Seeds $Seeds -Run $Run -Force:$Force -LeagueScope $LeagueScope)
        Write-Host ('[run] parallel mode: workers=' + $Workers + ' cells=' + $cells.Count)
        if ($cells.Count -eq 0) {
            Write-Host '[run] nothing to do (all cells already measured)'
        } else {
            $pr = Invoke-ParallelCells -Spec $Spec -SpecPath $SpecPath -Configs $Configs -Cells $cells `
                  -Run $Run -Workers $Workers -TimeoutSec $TimeoutSec
            $ranBatches = $cells.Count
            $wallTotal = $pr.WallSec
            [void](Merge-WorkerResults -Run $Run -Spec $Spec -WorkerRuns @($pr.WorkerRuns) -Configs $Configs)
            $cnames = @($Configs | ForEach-Object { [string]$_.name })
            $chk = Test-RunCompleteness -Run $Run -Spec $Spec -ConfigNames $cnames -Seeds $Seeds
            Write-Host ('[run] completeness: rows=' + $chk.Rows + ' duplicates=' + $chk.Duplicates + ' missing=' + $chk.Missing)
            # HARD GATE after the merge: every requested (config, seed, first, seq) must exist exactly
            # once. This is the end-to-end version of the cell accounting inside Invoke-ParallelCells:
            # it catches a short table no matter which layer lost the work. Warnings are not enough -
            # p1night was reported as a normal exit=0 run with 462 of 672 games and 6 configs at 0 rows.
            if ($chk.Missing -gt 0 -or $chk.Duplicates -gt 0) {
                $perCfg = @{}
                foreach ($r in @(Read-MeasureRows $Run)) {
                    $n = [string]$r.config
                    if ($perCfg.ContainsKey($n)) { $perCfg[$n]++ } else { $perCfg[$n] = 1 }
                }
                $perCfgNeed = @{}
                foreach ($cn in $cnames) { $perCfgNeed[$cn] = $Seeds.Count * @($Spec.measurement.firsts).Count * @($Spec.measurement.asides).Count }
                Write-Host ('[run] !! planned cells=' + $pr.PlannedCells + ' completed=' + $pr.DoneCells +
                            ' | planned games=' + $pr.PlannedGames + ' produced=' + $pr.DoneGames)
                foreach ($cn in $cnames) {
                    $got = 0; if ($perCfg.ContainsKey($cn)) { $got = [int]$perCfg[$cn] }
                    $need = [int]$perCfgNeed[$cn]
                    if ($got -lt $need) { Write-Host ('[run] !!   config ' + $cn + ': ' + $got + '/' + $need + ' game(s) -- short ' + ($need - $got) + $(if ($got -eq 0) { ' (NEVER RAN)' } else { '' })) }
                }
                throw ('INCOMPLETE RUN "' + $Run + '": ' + $chk.Missing + ' missing and ' + $chk.Duplicates + ' duplicate measurement(s) after the merge (' +
                       $chk.Rows + ' row(s) present). Refusing to report a successful run. Re-run the same command to fill the gap' +
                       $(if ($chk.Missing -gt 0) { ' (the first missing keys: ' + (($chk.MissingKeys | Select-Object -First 6) -join ' , ') + ')' } else { '' }) + '.')
            }
            if ($chk.Duplicates -gt 0) {
                Write-Host ('[run] WARNING duplicate keys after repair: ' + (($chk.DuplicateKeys | Select-Object -First 8) -join ' , '))
            }
            $totalGames = $chk.Rows
        }
    } else {
    foreach ($c in $Configs) {
        foreach ($sd in $Seeds) {
            foreach ($fs in @($Spec.measurement.firsts)) {
                $need = $false
                # Identity = (config, seed, first, seq, opp, wB_sha). NOTE: the harness prints `a_side`
                # as the GAME INDEX within the batch (always 1 then 0), regardless of which side the
                # candidate actually played, so `a_side` must never be part of the identity.
                # The opponent IS part of it: the same cell against the checkpoint and against the
                # fixed copy are two different measurements.
                $sOpp = 'base'; $sWb = ''; $sWbFile = ''; $sBeamB = [int](Get-CfgBeamOpp $c)
                if ($league -and (Test-LeagueSelfPlay -Run $Run -Config ([string]$c.name) -Seed $sd -First $fs -Fraction $league.fraction -Scope $LeagueScope)) {
                    $sOpp = 'cand'; $sWb = [string]$league.checkpoint_sha12; $sWbFile = [string]$league.checkpoint
                    $sBeamB = [int]$c.beam   # mirror match: the checkpoint plays at the candidate's beam
                }
                $wantSeq = @(1..(@($Spec.measurement.asides).Count))
                foreach ($sq in $wantSeq) {
                    $key = Get-TupleKey -Config ([string]$c.name) -Seed $sd -First (Get-FirstKey $fs) -AKey 'X' -Seq $sq -Opp $sOpp -WBSha $sWb
                    if ($Force -or (-not $existing.ContainsKey($key))) { $need = $true }
                }
                Write-Host ('[run] probe config=[' + $c.name + '] seed=[' + ([string]$sd) + '] first=[' + $fs + '] opp=' + $sOpp + ' games=' + $wantSeq.Count + ' -> need=' + $need)
                if (-not $need) { continue }
                $info = Get-SeedLineupSummary -Spec $Spec -Seed $sd
                $ed = $Spec.decks.enemy; $pd = $Spec.decks.player
                if (-not $FixedDecks) { $ed = $info.enemy_deck; $pd = $info.player_deck }
                $base = Join-Path $dir ('b_' + $c.name + '_s' + $sd + '_f' + $fs)
                $InvToken = New-InvToken
                $wBArg = '-'; if ($sWbFile) { $wBArg = $sWbFile }
                $r = Invoke-GodotBatch -Seeds @([int]$sd) -First $fs -EDeck $ed -PDeck $pd `
                     -WeightsA $c.weights_file -WeightsB $wBArg -BeamA ([int]$c.beam) -BeamB $sBeamB `
                     -Opp $sOpp -LogBase $base -TimeoutSec $TimeoutSec -InvToken $InvToken
                $ranBatches++; $wallTotal += $r.WallSec
                $parsed = Read-RowsFromText $r.Stdout
                $verbatim = @($r.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('R|') })
                Add-RawLines -Run $Run -Lines $verbatim -Header ('batch=' + (Split-Path -Leaf $base) + ' config=' + $c.name + ' seed=' + $sd + ' first=' + $fs + ' exit=' + $r.ExitCode + ' wall_s=' + (Format-Num $r.WallSec 1) + ' e_deck=' + $ed + ' p_deck=' + $pd + ' audit=[' + (Get-AuditString $c.meta $sOpp $sWb $sBeamB) + ']')
                if ($parsed.m.Count -eq 0) {
                    Write-Host ('[run] !! batch ' + (Split-Path -Leaf $base) + ' produced 0 game rows (exit=' + $r.ExitCode + ')')
                    continue
                }
                # Compact from the append-only log right away: a batch id can repeat (re-run, -Force)
                # and counting the same (config, seed, first, seq) twice would inflate N.
                [void](Repair-MeasureCsv -Run $Run -Spec $Spec)
                Remove-MeasureRowsForSeed -Run $Run -Config $c.name -Seed $sd -First $fs
                $newRows = @()
                $seq = 0
                foreach ($m in $parsed.m) {
                    if ([int]$m.seed -ne $sd) { continue }
                    $seq++
                    $ptsA = Get-Num $m.ptsA
                    $ptsB = Get-Num $m.ptsB
                    $newRows += [pscustomobject][ordered]@{
                        run = $Run; config = $c.name; weights_file = (Split-Path -Leaf $c.weights_file)
                        weights_fp = $c.weights_fp; seed = $sd; round = $info.round; first = (Get-FirstKey ([string]$m.first))
                        a_side = [string]$m.a_side; lineup_used = $info.lineup_used; lineup_side = $info.lineup_side
                        res = [string]$m.res; killsA = [string]$m.killsA; killsB = [string]$m.killsB
                        rounds = [string]$m.rounds; ptsA = (Format-Num $ptsA 2); ptsB = (Format-Num $ptsB 2)
                        dmgA = [string]$m.dmgA; dmgB = [string]$m.dmgB
                        hpA = [string]$m.hpA; hpB = [string]$m.hpB; over = [string]$m.over
                        subA = [string]$m.subA; subB = [string]$m.subB
                        batch_out = (Split-Path -Leaf $r.OutPath); batch_wall_s = (Format-Num $r.WallSec 1)
                        seq = [string]$seq; line_no = [string]$m._line_no
                        weights_sha12 = [string]$c.meta.sha12
                        # $sBeamB, not the config default: a self-play cell runs the mirror match at the
                        # candidate beam, and an audit column that disagrees with the launched command
                        # is worse than no column.
                        beam_opp = [string]$sBeamB; opp = $sOpp; wB_sha = $sWb; inv = [string]$InvToken
                        audit = (Get-AuditString $c.meta $sOpp $sWb $sBeamB)
                    }
                }
                Add-MeasureRows -Run $Run -Rows $newRows
                $totalGames += $newRows.Count
                Write-Host ('[run] ' + $c.name + ' seed=' + $sd + ' first=' + $fs + ' opp=' + $sOpp + ' lineup=' + $info.lineup_used + '(' + $info.lineup_side + ') -> ' + $newRows.Count + ' game(s)')
                if ($parsed.summary.Count -gt 0) {
                    $s = $parsed.summary[0]
                    Write-Host ('[run]   harness SUMMARY games=' + $s.games + ' w=' + $s.w + ' l=' + $s.l + ' d=' + $s.d + ' search_ms_max=' + $s.search_ms_max + ' wall_s=' + $s.wall_s)
                }
            }
        }
    }
    }
    Write-Host ('[run] batches=' + $ranBatches + ' new_games=' + $totalGames + ' godot_wall=' + (Format-Num $wallTotal 1) + 's')
    # Serial end-of-run gate, same rule as the parallel path: every requested tuple exactly once.
    # A 0-row batch only printed a `!!` line and continued, so a run could end "successfully" with
    # configs that never produced a single game.
    $chkAll = Test-RunCompleteness -Run $Run -Spec $Spec -ConfigNames @($Configs | ForEach-Object { [string]$_.name }) -Seeds $Seeds
    Write-Host ('[run] completeness: rows=' + $chkAll.Rows + ' duplicates=' + $chkAll.Duplicates + ' missing=' + $chkAll.Missing)
    if ($chkAll.Missing -gt 0 -or $chkAll.Duplicates -gt 0) {
        $need = $Seeds.Count * @($Spec.measurement.firsts).Count * @($Spec.measurement.asides).Count
        $perCfg = @{}
        foreach ($r in @(Read-MeasureRows $Run)) {
            $n = [string]$r.config
            if ($perCfg.ContainsKey($n)) { $perCfg[$n]++ } else { $perCfg[$n] = 1 }
        }
        foreach ($cn in @($Configs | ForEach-Object { [string]$_.name })) {
            $got = 0; if ($perCfg.ContainsKey($cn)) { $got = [int]$perCfg[$cn] }
            if ($got -lt $need) { Write-Host ('[run] !!   config ' + $cn + ': ' + $got + '/' + $need + ' game(s) -- short ' + ($need - $got) + $(if ($got -eq 0) { ' (NEVER RAN)' } else { '' })) }
        }
        throw ('INCOMPLETE RUN "' + $Run + '": ' + $chkAll.Missing + ' missing and ' + $chkAll.Duplicates + ' duplicate measurement(s) (' +
               $chkAll.Rows + ' row(s)). Refusing to report a successful run; re-run the same command to fill the gap.')
    }
    $result = [pscustomobject]@{ Batches = $ranBatches; NewGames = $totalGames; GodotWallSec = $wallTotal }
    } finally {
        Exit-RunLock -LockPath $lockPath
    }
    return $result
}
function Get-ConfigStats([string]$Run, [string]$Config, [string]$SeedSet, [object]$Spec) {
    $rows = @(Read-MeasureRows $Run) | Where-Object { [string]$_.config -eq $Config }
    $seeds = @($Spec.seeds.$SeedSet)
    $rows = @($rows | Where-Object { $seeds -contains [int]$_.seed })
    $statRows = @($rows | ForEach-Object {
        [pscustomobject]@{ res = $_.res; diff = (Get-Num $_.ptsA) - (Get-Num $_.ptsB) }
    })
    $st = Get-Stats -Rows $statRows
    $st | Add-Member -NotePropertyName config -NotePropertyValue $Config -Force
    $st | Add-Member -NotePropertyName run -NotePropertyValue $Run -Force
    $st | Add-Member -NotePropertyName seed_set -NotePropertyValue $SeedSet -Force
    return $st
}

function Get-StatsRow([object]$St) {
    return ('| ' + $St.config + ' | ' + $St.n + ' | ' + $St.w + ' | ' + $St.l + ' | ' + $St.d + ' | ' +
            (Format-Num $St.winrate_raw 4) + ' | ' + (Format-Num $St.rate 4) + ' | **' + (Format-Num $St.rate_lo 4) + '** | ' +
            (Format-Num $St.rate_hi 4) + ' | ' + (Format-Num $St.pts_per_game 2) + ' | ' +
            (Format-Num $St.pts_sd 2) + ' | ' + (Format-Num $St.pts_lo95 2) + ' |')
}

function Get-StatsTable([string]$Run, [string]$SeedSet, [object]$Spec, [string[]]$ConfigNames) {
    $lines = @()
    $lines += '| config | N | W | L | D | win_raw | rate_half | rate_lo95 | rate_hi95 | pts/game | pts_sd | pts_lo95 |'
    $lines += '|---|---|---|---|---|---|---|---|---|---|---|---|'
    foreach ($cn in $ConfigNames) {
        $st = Get-ConfigStats -Run $Run -Config $cn -SeedSet $SeedSet -Spec $Spec
        $lines += (Get-StatsRow $st)
    }
    return $lines
}

function Write-SummaryCsv([string]$Run, [object]$Spec, [string[]]$ConfigNames) {
    $lines = @('run,config,seed_set,n,w,l,d,win_raw,rate_half,rate_lo95,rate_hi95,pts_per_game,pts_sd,pts_lo95,weights_fp')
    foreach ($cn in $ConfigNames) {
        foreach ($ss in @('train', 'holdout')) {
            $st = Get-ConfigStats -Run $Run -Config $cn -SeedSet $ss -Spec $Spec
            if ($st.n -eq 0) { continue }
            $fp = ''
            $c0 = @($Spec.configs | Where-Object { [string]$_.name -eq $cn })
            if ($c0.Count -eq 1 -and ($c0[0].PSObject.Properties.Name -contains 'weights')) { $fp = Get-WeightsFingerprint (Join-Path $script:RepoRoot $c0[0].weights) }
            $lines += (@($Run, $cn, $ss, $st.n, $st.w, $st.l, $st.d, (Format-Num $st.winrate_raw 6), (Format-Num $st.rate 6),
                          (Format-Num $st.rate_lo 6), (Format-Num $st.rate_hi 6), (Format-Num $st.pts_per_game 4),
                          (Format-Num $st.pts_sd 4), (Format-Num $st.pts_lo95 4), $fp) -join ',')
        }
    }
    Write-TextUtf8 -Path (Join-Path (Get-ResultsDir $Run) 'summary.csv') -Lines $lines
}

function Get-RawGameBlock([string]$Run, [string]$Config, [int]$Seed) {
    $rows = @(Read-MeasureRows $Run) | Where-Object { ([string]$_.config -eq $Config) -and ([int]$_.seed -eq $Seed) }
    $lines = @()
    if ($rows.Count -eq 0) { $lines += '(no rows)'; return $lines }
    $lines += '```'
    foreach ($r in $rows) {
        $lines += ('R|m|seed=' + $r.seed + '|a_side=' + $r.a_side + '|first=' + $r.first + '|res=' + $r.res +
                   '|killsA=' + $r.killsA + '|killsB=' + $r.killsB + '|rounds=' + $r.rounds +
                   '|ptsA=' + $r.ptsA + '|ptsB=' + $r.ptsB + '|dmgA=' + $r.dmgA + '|dmgB=' + $r.dmgB +
                   '|hpA=' + $r.hpA + '|hpB=' + $r.hpB + '|over=' + $r.over + '|subA=' + $r.subA + '|subB=' + $r.subB)
    }
    $lines += '```'
    return $lines
}

function Get-BeamBlock([object]$Spec, [object[]]$Configs) {
    # Which beams each config ACTUALLY used. A run may mix per-config beam/beam_opp overrides, so the
    # spec defaults alone do not describe the table - and for a beam sweep this is the whole point.
    $lines = @()
    $lines += '| config | beamA (candidate) | beamB (opponent) |'
    $lines += '|---|---|---|'
    $bos = @{}
    foreach ($c in $Configs) {
        $bo = [int](Get-CfgBeamOpp $c)
        $bos[$bo] = $true
        $lines += ('| `' + [string]$c.name + '` | ' + [int]$c.beam + ' | ' + $bo + ' |')
    }
    if ($bos.Count -gt 1) {
        $lines += ''
        $lines += ('- NOTE: this run mixes ' + $bos.Count + ' different opponent beams (' + (($bos.Keys | Sort-Object) -join '/') +
                    '), so league-wide win rates here are NOT a clean theta comparison.')
    }
    return $lines
}

function Get-ParamsBlock([object]$Spec) {
    $lines = @()
    $lines += '| parameter | value |'
    $lines += '|---|---|'
    $lines += ('| opponent | `opp=' + $Spec.opponent + '` = the read-only RL/ai copy of src/BattleAI.gd, difficulty=2 -> beam 800 / jitter 0 unless the config sets beam_opp |')
    $lines += ('| beamA / beamB (spec defaults) | ' + $Spec.beam.candidate + ' / ' + $Spec.beam.opponent + ' (per-config `beam` / `beam_opp` may override; see the beam table above) |')
    $lines += ('| fixed decks (fallback) | enemy `' + $Spec.decks.enemy + '`, player `' + $Spec.decks.player + '` |')
    $lines += ('| first modes | `' + (($Spec.measurement.firsts) -join ',') + '` |')
    $lines += ('| a_side | `' + (($Spec.measurement.asides) -join ',') + '` |')
    $lines += ('| train seeds | ' + $Spec.seeds.train.Count + ' seeds: ' + $Spec.seeds.train[0] + '..' + $Spec.seeds.train[$Spec.seeds.train.Count - 1] + ' |')
    $lines += ('| holdout seeds | ' + $Spec.seeds.holdout.Count + ' seeds: ' + $Spec.seeds.holdout[0] + '..' + $Spec.seeds.holdout[$Spec.seeds.holdout.Count - 1] + ' |')
    $lines += ('| seed intersection | ' + $Spec._seed_intersection + ' (must be 0) |')
    $lines += ''
    return $lines
}

# ============================ paired comparison (sensitivity sweep) ============================

function Get-ConfigPairedDiff {
    <#
      Paired comparison of two configs on the game tuples they BOTH cover.
      Pairing unit = (seed, first, seq). NOT a_side: the harness prints a_side as the game index
      inside the batch, so keying on it silently drops pairs (observed: 8 -> 6 pairs).
      Returns per-tuple diffs plus a t-style CI on the mean difference.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][string]$Control,
        [Parameter(Mandatory = $true)][string]$Treatment,
        [Parameter(Mandatory = $false)][double]$T975 = 2.2622   # t(0.975, df=9); refined from the sample size below
    )
    $rows = @(Read-MeasureRows $Run)
    $pick = @{}
    foreach ($r in $rows) {
        $cn = [string]$r.config
        if ($cn -ne $Control -and $cn -ne $Treatment) { continue }
        $k = ('{0}|{1}|{2}' -f $r.seed, (Get-FirstKey ([string]$r.first)), [string]$r.seq)
        if (-not $pick.ContainsKey($k)) { $pick[$k] = @{} }
        $pick[$k][$cn] = $r
    }
    $diffs = New-Object System.Collections.Generic.List[double]
    $ctrlWins = 0; $treatWins = 0; $pairs = 0
    $cW = 0; $cL = 0; $cD = 0; $tW = 0; $tL = 0; $tD = 0
    foreach ($k in $pick.Keys) {
        $e = $pick[$k]
        if (-not ($e.ContainsKey($Control) -and $e.ContainsKey($Treatment))) { continue }
        $pairs++
        $cr = $e[$Control]; $tr = $e[$Treatment]
        $cd = (Get-Num $cr.ptsA) - (Get-Num $cr.ptsB)
        $td = (Get-Num $tr.ptsA) - (Get-Num $tr.ptsB)
        $diffs.Add($td - $cd)
        foreach ($pair in @(@($cr, 'c'), @($tr, 't'))) {
            $res = [string]$pair[0].res
            if ($pair[1] -eq 'c') {
                if ($res -eq 'W') { $cW++ } elseif ($res -eq 'L') { $cL++ } else { $cD++ }
            } else {
                if ($res -eq 'W') { $tW++ } elseif ($res -eq 'L') { $tL++ } else { $tD++ }
            }
        }
        $cwi = 0.0; $twi = 0.0
        if ([string]$cr.res -eq 'W') { $cwi = 1.0 } elseif ([string]$cr.res -eq 'D') { $cwi = 0.5 }
        if ([string]$tr.res -eq 'W') { $twi = 1.0 } elseif ([string]$tr.res -eq 'D') { $twi = 0.5 }
        $ctrlWins += $cwi
        $treatWins += $twi
    }
    $out = [ordered]@{
        control = $Control; treatment = $Treatment; pairs = $pairs
        ctrl_w = $cW; ctrl_l = $cL; ctrl_d = $cD
        treat_w = $tW; treat_l = $tL; treat_d = $tD
        ctrl_rate = [double]::NaN; treat_rate = [double]::NaN
        d_rate = [double]::NaN; d_pts = [double]::NaN; d_pts_sd = [double]::NaN
        d_pts_se = [double]::NaN; d_pts_lo = [double]::NaN; d_pts_hi = [double]::NaN
        excludes_zero = $false
    }
    if ($pairs -eq 0) { return [pscustomobject]$out }
    $out.ctrl_rate = $ctrlWins / $pairs
    $out.treat_rate = $treatWins / $pairs
    $out.d_rate = $out.treat_rate - $out.ctrl_rate
    $sum = 0.0
    foreach ($dv in $diffs) { $sum += $dv }
    $mean = $sum / $pairs
    $out.d_pts = $mean
    if ($pairs -gt 1) {
        $var = 0.0
        foreach ($dv in $diffs) { $var += ($dv - $mean) * ($dv - $mean) }
        $var = $var / ($pairs - 1)
        $out.d_pts_sd = [Math]::Sqrt($var)
        $out.d_pts_se = $out.d_pts_sd / [Math]::Sqrt([double]$pairs)
        $tcrit = Get-TCrit -Df ($pairs - 1)
        $out.d_pts_lo = $mean - $tcrit * $out.d_pts_se
        $out.d_pts_hi = $mean + $tcrit * $out.d_pts_se
        $out.excludes_zero = (($out.d_pts_lo -gt 0.0) -or ($out.d_pts_hi -lt 0.0))
    }
    return [pscustomobject]$out
}

function Get-TCrit([int]$Df) {
    # Two-sided 97.5% t quantile by table + interpolation (avoids needing Math.NET).
    $table = @(
        @{ df = 1; t = 12.706 }, @{ df = 2; t = 4.303 }, @{ df = 3; t = 3.182 }, @{ df = 4; t = 2.776 },
        @{ df = 5; t = 2.571 }, @{ df = 6; t = 2.447 }, @{ df = 7; t = 2.365 }, @{ df = 8; t = 2.306 },
        @{ df = 9; t = 2.262 }, @{ df = 10; t = 2.228 }, @{ df = 12; t = 2.179 }, @{ df = 15; t = 2.131 },
        @{ df = 20; t = 2.086 }, @{ df = 25; t = 2.060 }, @{ df = 30; t = 2.042 }, @{ df = 40; t = 2.021 },
        @{ df = 60; t = 2.000 }, @{ df = 120; t = 1.980 }
    )
    if ($Df -le 0) { return 12.706 }
    foreach ($row in $table) { if ($row.df -ge $Df) { return [double]$row.t } }
    return 1.960
}

function Get-SensitivityTable {
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][string]$Control,
        [Parameter(Mandatory = $true)][string[]]$Treatments,
        [Parameter(Mandatory = $false)][string]$FloorRun = '',
        [Parameter(Mandatory = $false)][string]$FloorControl = '',
        [Parameter(Mandatory = $false)][string]$FloorTreatment = ''
    )
    $noiseSd = [double]::NaN
    $floorNote = 'not measured'
    if ($FloorRun -and $FloorControl -and $FloorTreatment) {
        $fd = Get-ConfigPairedDiff -Run $FloorRun -Control $FloorControl -Treatment $FloorTreatment
        if ($fd.pairs -gt 1) {
            $noiseSd = $fd.d_pts_sd
            $floorNote = ('same weights on a different 8-seed block: d_pts=' + (Format-Num $fd.d_pts 2) +
                          ' sd=' + (Format-Num $fd.d_pts_sd 2) + ' -> |d| below ~' + (Format-Num (2.0 * $fd.d_pts_sd) 1) + ' is noise')
        }
    }
    $lines = @()
    $lines += '| treatment | pairs | ctrl_rate | treat_rate | d_rate | d_pts | d_pts_sd | d_pts_95CI | sig |'
    $lines += '|---|---|---|---|---|---|---|---|---|'
    $warn = @()
    $allRows = @(Read-MeasureRows $Run)
    # Opponent-mix check: the paired delta is only interpretable if control and treatment met the same
    # opponents on the paired games. With league mixing this is not automatic, so it is checked and
    # reported per treatment instead of assumed.
    $mixOf = {
        param($rows)
        $m = @{}
        foreach ($r in $rows) {
            $o = Get-RowField $r 'opp' 'base'
            if (-not $o) { $o = 'base' }
            if ($m.ContainsKey($o)) { $m[$o]++ } else { $m[$o] = 1 }
        }
        return $m
    }
    $ctlRows = @($allRows | Where-Object { [string]$_.config -eq $Control })
    $ctlMix = & $mixOf $ctlRows
    $ctlMixStr = (($ctlMix.Keys | Sort-Object | ForEach-Object { $_ + ' ' + [Math]::Round(100.0 * $ctlMix[$_] / [Math]::Max(1, $ctlRows.Count)) + '%' }) -join '/')
    foreach ($tn in $Treatments) {
        $d = Get-ConfigPairedDiff -Run $Run -Control $Control -Treatment $tn
        $tRows = @($allRows | Where-Object { [string]$_.config -eq $tn })
        $tMix = & $mixOf $tRows
        $tMixStr = (($tMix.Keys | Sort-Object | ForEach-Object { $_ + ' ' + [Math]::Round(100.0 * $tMix[$_] / [Math]::Max(1, $tRows.Count)) + '%' }) -join '/')
        if ($ctlMix.Count -gt 0 -and $tMix.Count -gt 0) {
            # Compare the MIX, not just the set of opponent types: a control at 70% self-play and a
            # treatment at 55% would slip past a set comparison while still not being the same conditions.
            $mixDiff = 0.0
            $keys = @(@($ctlMix.Keys) + @($tMix.Keys) | Sort-Object -Unique)
            foreach ($k in $keys) {
                $a = 0.0; if ($ctlMix.ContainsKey($k)) { $a = 100.0 * $ctlMix[$k] / [Math]::Max(1, $ctlRows.Count) }
                $b = 0.0; if ($tMix.ContainsKey($k)) { $b = 100.0 * $tMix[$k] / [Math]::Max(1, $tRows.Count) }
                $mixDiff = [Math]::Max($mixDiff, [Math]::Abs($a - $b))
            }
            $setDiffers = (($ctlMix.Keys | Sort-Object) -join ',') -ne (($tMix.Keys | Sort-Object) -join ',')
            if ($setDiffers -or $mixDiff -ge 10.0) {
                $warn += ('!! opponent mix differs (control: ' + $ctlMixStr + ' ; ' + $tn + ': ' + $tMixStr + ' ; max share gap ' +
                          [Math]::Round($mixDiff) + 'pp) -> the paired delta for ' + $tn + ' mixes parameter and opponent effects; re-measure with league.enabled=false or one fixed opponent')
            }
        }
        if ($d.pairs -eq 0) {
            $lines += ('| ' + $tn + ' | 0 | - | - | - | - | - | - | (no paired games) |')
            # Make it loud: "no paired games" is almost never a genuine zero effect, it means the
            # treatment has no rows at all (never ran, or the run was truncated). p1night was spotted
            # only because the table carried six silent empty rows.
            $why = 'has NO rows in this run at all -> it never ran, or the run was truncated'
            if ($tRows.Count -gt 0) { $why = ('has ' + $tRows.Count + ' row(s) but none on a tuple the control also covers') }
            $warn += ('!! treatment ' + $tn + ' 没有任何配对局 (' + $why + ') -> its effect is UNMEASURED, not zero')
            continue
        }
        $ci = ('[' + (Format-Num $d.d_pts_lo 2) + ', ' + (Format-Num $d.d_pts_hi 2) + ']')
        $sig = 'no'
        if ($d.excludes_zero) { $sig = 'YES' }
        if ($d.excludes_zero -and -not [double]::IsNaN($noiseSd)) {
            if ([Math]::Abs($d.d_pts) -ge 2.0 * $noiseSd) { $sig = 'YES+ (above noise floor)' } else { $sig = 'CI only (within noise floor)' }
        }
        $lines += ('| ' + $tn + ' | ' + $d.pairs + ' | ' + (Format-Num $d.ctrl_rate 4) + ' | ' + (Format-Num $d.treat_rate 4) +
                   ' | ' + (Format-Num $d.d_rate 4) + ' | ' + (Format-Num $d.d_pts 2) + ' | ' + (Format-Num $d.d_pts_sd 2) +
                   ' | ' + $ci + ' | ' + $sig + ' |')
    }
    $lines += ''
    $lines += ('noise floor: ' + $floorNote)
    if ($warn.Count -gt 0) {
        $lines += ''
        $lines += ('!! ' + $warn.Count + ' WARNING(s) -- this table is only as trustworthy as the conditions below:')
        foreach ($w in $warn) { $lines += ('- ' + $w) }
    }
    return $lines
}
