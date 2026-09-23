# beam对拍.ps1 —— 【2026-09-22 晚·用户点名】「同队伍、同权重、只差 beam」的镜像自对弈对拍。
#
# 为什么要单独写一个（两条现成路都量不出这件事）：
#   · `难度体检` 走 `opp=base` ⇒ 陪练是**困难档副本**（权重 = 引擎默认，不是噩梦）⇒ 不是"噩夢打噩梦"；
#   · `Train.ps1` 的 league 自对弈**强制镜像同宽**（`beamB = beamA`，见 RlTrain.ps1:2068 那段注释）⇒ 量不出"只差 beam"。
#   ⇒ 本脚本直接按走查台的 CLI 口径调 `res://RL/harness/对局.tscn`：
#     `opp=cand` ⇒ **两边都跑 fork、各自注入一份权重、各自一个 beam**（`对局.gd:218-229`）。
#
# 口径（与 `难度体检` 保持可比）：
#   · 双方权重 = **同一个文件**（默认 `RL\weights\噩梦.json`）；双方代码 = fork（同一份、逐字节同源）
#   · 臂：`ctl`（双方都 = `-BeamCtl`）/ `arm`（候选 = `-BeamArm`、陪练 = `-BeamCtl`）⇒ **唯一变量 = 候选自己的宽度**
#   · 每个种子 4 局（先手 p/e × a_side 敌/我；与 Train.ps1 的 `firsts=p,e asides=e` 同构，但两侧都取）
#   · 两臂**同格配对**：(队伍, 种子, 先手, a_side) ⇒ Δpts = `ptsA(arm) − ptsA(ctl)`（ptsA = 候选方得分）
#   · 主判读 = 生产侧 `a_side=1`（与 `难度体检` 同口径）；另附"全 4 局"口径
#   · 附带"行为差异率"：同格里 `rounds` 不同的比例（宽度变了、出招到底有没有跟着变）
#
# 用法：& RL\train\beam对拍.ps1                      （默认 6 队 × 4 种子 × 2 臂 = 192 局）
#       & RL\train\beam对拍.ps1 -BeamArm 800 -Seeds 6 -Tag beam2
[CmdletBinding()]
param(
    [string[]]$Decks = @(
        'hero_13,hero_12,hero_18',   # 近战前排
        'hero_24,hero_09,hero_20',   # 远程多
        'hero_42,hero_03,hero_17',   # 矿工/毒蛇/烛火
        'hero_48,hero_14,hero_25',   # 装甲堡垒/古拉/战锤
        'hero_46,hero_11,hero_08',   # 宿魂/塔盾/德鲁伊
        'hero_06,hero_08,hero_43'    # 续航/光环（最慢的一队）
    ),
    [int]$Seeds = 4,
    [int]$SeedStart = 80,
    [int]$Workers = 6,
    [int]$TimeoutSec = 300,
    [string]$Weights = 'RL\weights\噩梦.json',
    [int]$BeamCtl = 200,
    [int]$BeamArm = 400,
    [string]$Tag = 'beam1'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)      # RL\train -> 项目根
$runner = Join-Path $PSScriptRoot '跑Godot隔离.ps1'
$results = Join-Path $PSScriptRoot 'results'
if (-not (Test-Path -LiteralPath $results)) { New-Item -ItemType Directory -Force -Path $results | Out-Null }
$wAbs = if ([System.IO.Path]::IsPathRooted($Weights)) { $Weights } else { Join-Path $root $Weights }
if (-not (Test-Path -LiteralPath $wAbs)) { throw ('权重文件不存在: ' + $wAbs) }
$wSha = (Get-FileHash $wAbs -Algorithm SHA256).Hash.Substring(0, 12).ToLower()

# ---- 任务表：每个 (队伍, 种子, 臂) 一个进程（该进程内 4 局）----
$tasks = New-Object System.Collections.Generic.List[object]
foreach ($deck in $Decks) {
    foreach ($i in 0..([Math]::Max($Seeds - 1, 0))) {
        $sd = $SeedStart + $i
        $tasks.Add([pscustomobject]@{ deck = $deck; seed = $sd; arm = 'ctl'; beamA = $BeamCtl; beamB = $BeamCtl })
        $tasks.Add([pscustomobject]@{ deck = $deck; seed = $sd; arm = 'arm'; beamA = $BeamArm; beamB = $BeamCtl })
    }
}
$nGames = $tasks.Count * 4
Write-Host ('[beam对拍] 臂: ctl(双方 ' + $BeamCtl + ') vs arm(候选 ' + $BeamArm + ' / 陪练 ' + $BeamCtl + ')')
Write-Host ('[beam对拍] 权重: ' + $Weights + ' (sha12 ' + $wSha + ') | 双方代码 = fork (opp=cand) | 任务=' + $tasks.Count + ' 进程 = ' + $nGames + ' 局 | workers=' + $Workers)
Write-Host ('[beam对拍] tag=' + $Tag + ' | 每进程超时=' + $TimeoutSec + 's')

# ---- 均分给 N 个 worker（每个 worker 串行跑自己那批）----
$jobs = @()
for ($w = 0; $w -lt $Workers; $w++) {
    $chunk = @($tasks | Where-Object { ($tasks.IndexOf($_)) % $Workers -eq $w })
    if ($chunk.Count -eq 0) { continue }
    $wi = $w + 1
    # ⚠️ 任务表**序列化成文本**再传（`-ArgumentList (, $chunk)` 会把数组多包一层 ⇒ worker 里
    #   `$t.deck` 变成"整个 chunk 的 deck 枚举"、结果全串味；字符串传参没有这类拍平/包装陷阱）。
    $chunkText = (@($chunk | ForEach-Object { $_.deck + '|' + $_.seed + '|' + $_.arm + '|' + $_.beamA + '|' + $_.beamB }) -join "`n")
    $jobs += Start-Job -ScriptBlock {
        param($chunkText, $root, $runner, $wAbs, $TimeoutSec, $wi, $tag)
        # ⚠️ 结果一律落成磁盘上的文本（不返回带 [int] 属性的对象）：实测 `Receive-Job` 反序列化会抛
        #   `无法将值"8083…"转换为类型 System.Int32`。父进程按同一命名规则自己读。
        $lines = New-Object System.Collections.Generic.List[string]
        $notes = New-Object System.Collections.Generic.List[string]
        foreach ($tline in ($chunkText -split "`n")) {
            if (-not $tline -or $tline.Trim() -eq '') { continue }
            $f5 = $tline.Split('|')
            $deck = $f5[0]; $seed = $f5[1]; $arm = $f5[2]; $bA = $f5[3]; $bB = $f5[4]
            $ga = @('--headless', '--path', $root, '--scene', 'res://RL/harness/对局.tscn', '--',
                    '1', $seed, $deck, $deck, $wAbs, $wAbs, $bA, $bB, 'cand', 'both')
            $out = & $runner -Tag ('bm' + $wi) -TimeoutSec $TimeoutSec -Args $ga 2>&1 | Out-String
            $n = 0
            foreach ($line in ($out -split "`r?`n")) {
                $m = [regex]::Match($line, 'R\|m\|seed=(\d+)\|a_side=(\d+)\|first=(\d+)\|res=([WLD])\|killsA=(\d+)\|killsB=(\d+)\|rounds=(\d+)\|ptsA=(-?[\d.]+)\|ptsB=(-?[\d.]+)')
                if (-not $m.Success) { continue }
                $n++
                $lines.Add(($deck + '|' + $m.Groups[1].Value + '|' + $arm + '|' + $bA + '|' + $bB + '|' +
                            $m.Groups[2].Value + '|' + $m.Groups[3].Value + '|' + $m.Groups[4].Value + '|' +
                            $m.Groups[5].Value + '|' + $m.Groups[6].Value + '|' + $m.Groups[7].Value + '|' +
                            $m.Groups[8].Value + '|' + $m.Groups[9].Value))
            }
            if ($n -lt 4) {
                $tail = (($out -split "`r?`n") | Where-Object { $_ -match 'TIMEOUT|SCRIPT ERROR|R\|ERROR' } | Select-Object -First 2) -join ' / '
                $notes.Add('[缺局] deck=' + $deck + ' seed=' + $seed + ' arm=' + $arm + ' rows=' + $n + '/4 :: ' + $tail)
            }
        }
        $f = Join-Path $env:TEMP ('beam_' + $tag + '_w' + $wi + '.csv')
        [System.IO.File]::WriteAllLines($f, $lines, (New-Object System.Text.UTF8Encoding($false)))
        $nf = Join-Path $env:TEMP ('beam_' + $tag + '_w' + $wi + '.notes.txt')
        [System.IO.File]::WriteAllLines($nf, $notes, (New-Object System.Text.UTF8Encoding($false)))
        return 'done'
    } -ArgumentList $chunkText, $root, $runner, $wAbs, $TimeoutSec, $wi, $Tag
}
Write-Host ('[beam对拍] ' + $jobs.Count + ' 个 worker 已启动；等待…')
$rawRows = @(); $notes = @()
foreach ($j in $jobs) { $null = Receive-Job -Job $j -Wait -AutoRemoveJob }   # 只做同步，结果从磁盘读
# ⚠️ 结果路径由父进程按同一规则自己算（不依赖 Receive-Job 的序列化，见 worker 里的说明）
for ($w = 1; $w -le $Workers; $w++) {
    $csvF = Join-Path $env:TEMP ('beam_' + $Tag + '_w' + $w + '.csv')
    $notesF = Join-Path $env:TEMP ('beam_' + $Tag + '_w' + $w + '.notes.txt')
    if ((Test-Path -LiteralPath $csvF) -and ((Get-Item -LiteralPath $csvF).Length -gt 0)) {
        $rawRows += @(Import-Csv -LiteralPath $csvF -Delimiter '|' -Header deck, seed, arm, beamA, beamB, a_side, first, res, killsA, killsB, rounds, ptsA, ptsB)
    }
    if (Test-Path -LiteralPath $notesF) {
        $notes += @(Get-Content -LiteralPath $notesF -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne '' })
    }
}
$rows = @($rawRows | ForEach-Object {
        [pscustomobject]@{
            deck   = [string]$_.deck; seed = [int]$_.seed; arm = [string]$_.arm
            beamA  = [int]$_.beamA;   beamB = [int]$_.beamB
            a_side = [int]$_.a_side; first = [int]$_.first; res = [string]$_.res
            killsA = [int]$_.killsA; killsB = [int]$_.killsB; rounds = [int]$_.rounds
            ptsA   = [double]$_.ptsA; ptsB = [double]$_.ptsB
        }
    })
if ($notes.Count -gt 0) {
    Write-Host ('[beam对拍] ⚠️ ' + $notes.Count + ' 条缺局记录（这些格不计入配对）：')
    $notes | ForEach-Object { Write-Host ('  ' + $_) }
}

$csv = Join-Path $results ('beam_' + $Tag + '.csv')
$rows | Sort-Object deck, seed, first, a_side, arm | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host ('[beam对拍] 逐局明细 -> ' + $csv + '  (' + $rows.Count + ' 行)')
if ($rows.Count -eq 0) { throw '一局都没跑出来，先看上面的缺局记录' }

# ---- 汇总 ----
function Show-Table([string]$title, [object[]]$sel) {
    Write-Host ''
    Write-Host ('== ' + $title + ' ==')
    foreach ($armName in @('ctl', 'arm')) {
        $a = @($sel | Where-Object { $_.arm -eq $armName })
        if ($a.Count -eq 0) { continue }
        $w = @($a | Where-Object { $_.res -eq 'W' }).Count
        $l = @($a | Where-Object { $_.res -eq 'L' }).Count
        $dn = @($a | Where-Object { $_.res -eq 'D' }).Count
        $pm = ($a | Measure-Object -Property ptsA -Average).Average
        $rate = if (($w + $l) -gt 0) { $w / [double]($w + $l) } else { 0.0 }
        Write-Host ('  {0,-4} 局={1,3}  W/L/D={2,3}/{3,3}/{4,2}  A方胜率={5:N4}  ptsA均值={6,7:N2}' -f $armName, $a.Count, $w, $l, $dn, $rate, $pm)
    }
    $ctl = @($sel | Where-Object { $_.arm -eq 'ctl' })
    $arm = @($sel | Where-Object { $_.arm -eq 'arm' })
    $dl = @(); $fw = 0; $fl = 0; $rdiff = 0
    foreach ($c in $ctl) {
        $o = @($arm | Where-Object { $_.deck -eq $c.deck -and $_.seed -eq $c.seed -and $_.first -eq $c.first -and $_.a_side -eq $c.a_side })
        if ($o.Count -eq 0) { continue }
        $o = $o[0]
        $dl += ($o.ptsA - $c.ptsA)
        if ($o.res -eq 'W' -and $c.res -ne 'W') { $fw++ }
        if ($o.res -ne 'W' -and $c.res -eq 'W') { $fl++ }
        if ($o.rounds -ne $c.rounds) { $rdiff++ }
    }
    if ($dl.Count -gt 0) {
        $dm = ($dl | Measure-Object -Average).Average
        $lo = 0.0; $hi = 0.0
        if ($dl.Count -gt 1) {
            $sd = [math]::Sqrt((($dl | ForEach-Object { [math]::Pow($_ - $dm, 2) }) | Measure-Object -Sum).Sum / ($dl.Count - 1))
            $se = $sd / [math]::Sqrt($dl.Count)
            $lo = $dm - 1.96 * $se; $hi = $dm + 1.96 * $se
        }
        Write-Host ('  Δpts(arm−ctl) = {0,7:N2}  95%CI=[{1:N2},{2:N2}]  翻盘 {3}胜/{4}负  配对n={5}  回合数有变 {6}/{5} ({7:N0}%)' -f `
                $dm, $lo, $hi, $fw, $fl, $dl.Count, $rdiff, (100.0 * $rdiff / $dl.Count))
    }
}
Show-Table ('生产侧 a_side=1') @($rows | Where-Object { $_.a_side -eq 1 })
Show-Table ('全 4 局（两侧都算）') $rows

Write-Host ''
Write-Host '== 分队 Δpts（生产侧，8 配对/队）=='
foreach ($deck in $Decks) {
    $sel = @($rows | Where-Object { $_.deck -eq $deck -and $_.a_side -eq 1 })
    $dl = @()
    foreach ($c in @($sel | Where-Object { $_.arm -eq 'ctl' })) {
        $o = @($sel | Where-Object { $_.arm -eq 'arm' -and $_.seed -eq $c.seed -and $_.first -eq $c.first })
        if ($o.Count -gt 0) { $dl += ($o[0].ptsA - $c.ptsA) }
    }
    if ($dl.Count -gt 0) {
        Write-Host ('  {0,-26} Δpts={1,7:N2}  n={2}' -f $deck, (($dl | Measure-Object -Average).Average), $dl.Count)
    }
}
Write-Host ''
Write-Host '[判读] Δpts 的 CI 不跨 0 才算"宽度真的换到了分"；跨 0 ⇒ 与历史读数一致（beam 100~1200 无差别）。'
Write-Host '[口径] ptsA = 候选方（A 侧）得分；res 也是 A 侧视角。镜像对局 ⇒ 两臂的 A 方胜率可直接对比。'
