# RL/train/多阵容搜索.ps1 —— "哪个比例最通用"由数据直接回答（2026-09-14 加）
#
# 与 联合搜索.ps1 的区别：
#   联合搜索：固定 1 套阵容跑进化，每套阵容各出一个冠军，最后再猜哪个冠军通用。
#   本脚本  ：每轮让【同一批比例候选】在【多套固定阵容】上各打一遍，"通用性"直接由
#             "这个比例在 8 套阵容上的平均 Δpts"回答，不需要先各自选冠军。
#
# 一轮的流程：
#   1) 从英雄池确定性抽 L 套阵容（每套 6 个不重复英雄 → 我方 3 + 敌方 3），本轮内不变，写进日志可复现。
#   2) 采样 K 个"整组比例"候选（对数正态扰动 σ，围绕上一轮最优/默认比例，确定性 RNG）+ 1 个控制组（默认比例）。
#   3) 每套阵容：生成该阵容专用 spec（decks 写死、league.enabled=false、beam=beam_opp=便宜档），
#      用 -FixedDecks 把 (控制组 + 存活候选) 在同一批 seeds 上跑一遍（配对）；分级 racing
#      24 局 → 淘汰一半 → 64 局 → 只留最好的 2~3 个打 192 局。
#   4) 聚合：每个候选在其所到之处的每套阵容上算 Δpts（对控制组、逐局配对）→ 均值 + 95% CI 排名。
#   5) 累积到 RL/reports/多阵容_比例池.csv；本轮最优比例写 RL/weights/multi_best_<Tag>.json。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File RL\train\多阵容搜索.ps1 -Rounds 3 -Tag M1
#
# 闸门（全部响亮失败，绝不静默）：
#   1) 同 run 内同一 (seed, first) 的所有臂同对手  —— RlTrain 的 Assert-LeagueArmConsistency
#   2) 固定阵容断言：每批 R|cfg| 的 edeck/pdeck 必须等于该阵容
#   3) 配对完整性：每个候选在每套阵容上必须有同样的 seed 集合，缺则点名 throw
#   4) 子进程真错误回显（$LASTEXITCODE + 原始输出）
#   5) 全部绝对路径（不依赖子进程 CWD）
param(
  [int]$Rounds = 1,
  [int]$Candidates = 16,
  [double]$Sigma = 0.20,
  [int]$LineupCount = 8,
  [int]$Workers = 8,
  [int]$Stage1Seeds = 6,
  [int]$Stage2Seeds = 16,
  [int]$Stage3Seeds = 48,
  [int]$SearchBeam = 100,
  [string]$Tag = 'M1',
  [int]$Seed0 = 20260914,
  [string]$BaseWeights = 'RL/weights/噩梦.json',
  [int]$TimeoutSec = 10800,
  [int]$Patience = 0,          # >0 时：连续这么多轮最佳均值不提升就停
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path (Join-Path $RepoRoot 'RL\train\train_spec.json'))) { $RepoRoot = 'D:\Game creating\战旗' }
$train    = Join-Path $RepoRoot 'RL\train\Train.ps1'
$baseSpec = Join-Path $RepoRoot 'RL\train\train_spec.json'
$logDir   = Join-Path $RepoRoot 'RL\reports'
$log      = [System.IO.Path]::GetFullPath((Join-Path $logDir ('多阵容搜索_' + $Tag + '_日志.md')))
$poolCsv  = [System.IO.Path]::GetFullPath((Join-Path $logDir '多阵容_比例池.csv'))
$bestW    = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ('RL\weights\multi_best_' + $Tag + '.json')))
$baseW    = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $BaseWeights))
if (-not (Test-Path -LiteralPath $baseW)) { throw ('多阵容搜索: 起始权重不存在: ' + $baseW) }
# 库函数（Read-TrainSpec / Get-HeroUniverse / Get-ConfigPairedDiff / Get-RawLogPath）都在 RlTrain.ps1 里。
# 不 dot-source 的话这些名字全都不存在：英雄池会是 0 个 → 抽样除零，而报错点离真正原因很远。
. (Join-Path $RepoRoot 'RL\train\RlTrain.ps1')

# 可搜的比例键（BEAM/JITTER 不参与：算力与噪声；KILL_BONUS 2026-09-15 起也不参与：实测无用，噩梦档钉死 0）
$KEYS = @('FOCUS_FIRE_WEIGHT','GOLD_TAKE_VALUE','GOLD_TAKE_VALUE_LOW','GOLD_LOW_ATK',
          'BUFF_TAKE_WEIGHT','THREAT_MOVE_DISCOUNT','OBSTACLE_DETOUR_WEIGHT','ENGAGE_PULL_PER_CELL','MAX_MOVE_OPTIONS')

function Say($m) {
  $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
function Get-ThetaFixed([string]$path) {
  $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $h = @{}; foreach ($k in $KEYS) { $h[$k] = [double]$j.$k }
  return $h
}
function Theta-Json($h) {
  ($KEYS | ForEach-Object { '"' + $_ + '": ' + ([Math]::Round([double]$h[$_], 4)).ToString([System.Globalization.CultureInfo]::InvariantCulture) }) -join ', '
}
function Get-ComboFingerprint($h) { (($KEYS | ForEach-Object { $_.ToString() + '=' + ([Math]::Round([double]$h[$_], 4)).ToString([System.Globalization.CultureInfo]::InvariantCulture) }) -join '|') }

# ---------- 确定性阵容抽样：一次抽 6 个不重复英雄，前 3 给我方、后 3 给敌方 ----------
# 参数名必须避开【本脚本里会被赋成数组的变量】：PowerShell 变量名大小写不敏感，声明 [int]$Count 时调用方写 `-Count $N -Pool $pool` 会因
# 所以 [int]$Lineups 和后面的 $lineups = @() 是同一个变量 → [int]$Lineups 会去转换一个数组，

# ---------- 读一个 run 里两个 config 的逐局配对 ----------
function Get-PairedPoints([string]$Run, [string]$Control, [string]$Treat) {
  $d = Get-ConfigPairedDiff -Run $Run -Control $Control -Treatment $Treat
  return [pscustomobject]@{ pairs = [int]$d.pairs; dpts = [double]$d.d_pts; sd = [double]$d.d_pts_sd }
}

# ---------- 跑一个子进程并回显真错误 ----------
function Invoke-Train([string]$ArgLine, [string]$Label, [string]$LogFile) {
  $full = "& '$train' " + $ArgLine + ' *>> "' + $LogFile + '"'
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $full
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Say ('  ✗ ' + $Label + ' 失败 exit=' + $code + '，原始输出（末尾 30 行）:')
    foreach ($l in @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 30)) { Say ('      | ' + [string]$l) }
    throw ('多阵容搜索: ' + $Label + ' 失败（exit=' + $code + '）')
  }
  return @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
}

# ---------- 固定阵容断言 ----------
function Assert-LineupFixed([string]$Run, [string[]]$ExpectP, [string[]]$ExpectE, [string]$Label) {
  $p = Get-RawLogPath $Run
  if (-not (Test-Path -LiteralPath $p)) { throw ('多阵容搜索: ' + $Label + ' 没有 raw log，无法核对阵容: ' + $p) }
  $expP = '["' + ($ExpectP -join '", "') + '"]'
  $expE = '["' + ($ExpectE -join '", "') + '"]'
  $bad = 0; $n = 0
  foreach ($ln in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) {
    if (-not $ln.StartsWith('R|cfg|')) { continue }
    $n++
    $mp = [regex]::Match($ln, 'edeck=(\[[^\]]*\])')
    $mq = [regex]::Match($ln, 'pdeck=(\[[^\]]*\])')
    if (-not $mp.Success -or -not $mq.Success) { throw ('多阵容搜索: ' + $Label + ' 的 R|cfg| 行缺 edeck/pdeck: ' + $ln) }
    if ($mp.Groups[1].Value -ne $expE -or $mq.Groups[1].Value -ne $expP) {
      $bad++
      if ($bad -le 3) { Say ('  ✗ ' + $Label + ' 阵容不符: 期望 E=' + $expE + ' P=' + $expP + ' 实际 E=' + $mp.Groups[1].Value + ' P=' + $mq.Groups[1].Value) }
    }
  }
  if ($n -eq 0) { throw ('多阵容搜索: ' + $Label + ' 没有 R|cfg| 行，无法核对阵容') }
  if ($bad -gt 0) { throw ('多阵容搜索: FIXED LINEUP VIOLATION —— ' + $bad + '/' + $n + ' 批次的阵容不等于本套固定阵容（' + $Label + '）') }
  Say ('  ✓ 阵容固定断言通过（' + $Label + '，' + $n + ' 批全部 E=' + $expE + ' P=' + $expP + '）')
}

# ============================ 主流程 ============================
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$spec = Read-TrainSpec $baseSpec
$pool = @(Get-HeroUniverse -Spec $spec)
$defaultTheta = Get-ThetaFixed $baseW
Say ('===== 多阵容搜索 Tag=' + $Tag + ' =====')
Say ('  英雄池: ' + $pool.Count + ' 个（' + $pool[0] + '..' + $pool[-1] + '）')
Say ('  参数: 轮数=' + $Rounds + ' 候选=' + $Candidates + ' σ=' + $Sigma + ' 阵容=' + $LineupCount +
     ' 并发=' + $Workers + ' 分级seeds=' + $Stage1Seeds + '/' + $Stage2Seeds + '/' + $Stage3Seeds +
     ' 搜索档beam=' + $SearchBeam + ' 阵容种子=' + $Seed0)
Say ('  起点比例: ' + (Theta-Json $defaultTheta))

# 累积池
if (-not (Test-Path -LiteralPath $poolCsv)) {
  Add-Content -LiteralPath $poolCsv -Value 'tag,round,candidate,combo,mean_dpts,ci_lo,ci_hi,lineups_used,min_dpts,max_dpts' -Encoding UTF8
}
if (-not (Test-Path -LiteralPath $bestW)) {
  try { Copy-Item -LiteralPath $baseW -Destination $bestW -ErrorAction Stop } catch { throw ('多阵容搜索: 无法初始化 ' + $bestW + ': ' + $_.Exception.Message) }
  Say ('  初始化 multi_best = ' + $BaseWeights + ' 副本 → ' + $bestW)
}
$bestTheta = Get-ThetaFixed $bestW
$bestMean = [double]::NegativeInfinity
$noImprove = 0

$stageDefs = @(
  @{ n = 1; seeds = [int]$Stage1Seeds; keep = [Math]::Max(2, [int][Math]::Ceiling($Candidates / 2.0)) },
  @{ n = 2; seeds = [int]$Stage2Seeds; keep = [Math]::Min(3, [int][Math]::Max(2, [int][Math]::Ceiling($Candidates / 4.0))) },
  @{ n = 3; seeds = [int]$Stage3Seeds; keep = 1 }
)

for ($r = 1; $r -le $Rounds; $r++) {
  Say ('===== 第 ' + $r + ' 轮 开始 =====')
  # 1) 本轮阵容（确定性、可复现）
  # 本轮固定阵容（确定性抽样）。注意：承载结果的变量叫 $lineups，参数叫 $LineupCount ——
  # PowerShell 大小写不敏感，若参数也叫 $Lineups 就会和数组结果撞成同一个变量。
  $lineups = @()
  $shaLU = [System.Security.Cryptography.SHA256]::Create()
  try {
    for ($li = 1; $li -le [int]$LineupCount; $li++) {
      $taken = @{}; $six = @(); $tries = 0
      while ($six.Count -lt 6 -and $tries -lt 2000) {
        $tries++
        $seedStr = "multi|$Seed0|R$r|L$li|$($six.Count)|$tries"
        $hb = $shaLU.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedStr))
        $hv = ([uint32]$hb[0] * 16777216) + ([uint32]$hb[1] * 65536) + ([uint32]$hb[2] * 256) + [uint32]$hb[3]
        $hh = $pool[[int]($hv % [uint32]$pool.Count)]
        if (-not $taken.ContainsKey($hh)) { $taken[$hh] = $true; $six += $hh }
      }
      if ($six.Count -ne 6) { throw ("多阵容搜索: 阵容抽样失败 R$r L$li") }
      $sb = $shaLU.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("multi|$Seed0|R$r|L$li|split"))
      $swap = (([uint32]$sb[0] * 256) + [uint32]$sb[1]) % 2
      $lp = @($six[0..2]); $le = @($six[3..5])
      if ($swap -eq 1) { $lp = @($six[3..5]); $le = @($six[0..2]) }
      $lineups += [pscustomobject]@{ idx = $li; player = $lp; enemy = $le }
    }
  } finally { $shaLU.Dispose() }
  foreach ($lu in $lineups) {
    Say ('  L' + $lu.idx + '  我方=[' + ($lu.player -join ',') + ']  敌方=[' + ($lu.enemy -join ',') + ']')
  }
  # 2) 候选（确定性 RNG：每轮独立种子，可复现）
  $rng = New-Object System.Random ($Seed0 + $r * 1000)
  $cands = @()
  for ($i = 1; $i -le $Candidates; $i++) {
    $h = @{}
    foreach ($k in $KEYS) {
      $u1 = [Math]::Max($rng.NextDouble(), 1e-9); $u2 = $rng.NextDouble()
      $z = [Math]::Sqrt(-2 * [Math]::Log($u1)) * [Math]::Cos(2 * [Math]::PI * $u2)
      $h[$k] = [double]$bestTheta[$k] * [Math]::Exp($z * $Sigma)
    }
    $cands += [pscustomobject]@{ name = ('r' + $r + '_c' + $i); theta = $h }
  }
  $cName = 'r' + $r + '_best'
  Say ('  候选 ' + $cands.Count + ' 个 + 控制组 ' + $cName + '（围绕' + $(if ($bestMean -eq [double]::NegativeInfinity) { '默认比例' } else { '上一轮最优' }) + '）')

  # 3) 每套阵容跑一遍，保存每个候选在该阵容上的 Δpts
  $perLineup = @{}     # 阵容 idx -> @{ 候选名 -> Δpts }
  $perLineupPairs = @{}
  $alive = @($cands | ForEach-Object { $_.name })
  foreach ($st in $stageDefs) {
    $useNames = @($cName) + $alive
    if ($alive.Count -eq 0) { break }
    Say ('  --- 轮' + $r + ' 阶段' + $st.n + '（' + $st.seeds + ' seeds = ' + ($st.seeds * 4) + ' 局/臂）---')
    foreach ($lu in $lineups) {
      $luTag = $Tag + '_R' + $r + '_L' + $lu.idx
      $runName = $luTag + '_s' + $st.n
      $specPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ('RL\train\spec_multi_' + $Tag + '_R' + $r + '_L' + $lu.idx + '.json')))
      # 该阵容专用 spec：decks 写死 + league 关掉（固定对手）+ 便宜档
      $raw = [System.IO.File]::ReadAllText($baseSpec, [System.Text.Encoding]::UTF8)
      $cfgLines = @()
      $cfgLines += ('    { "name": "' + $cName + '", "note": "round ' + $r + ' control", "theta": { ' + (Theta-Json $defaultTheta) + ' }, "beam": ' + $SearchBeam + ', "beam_opp": ' + $SearchBeam + ' },')
      foreach ($c in $cands) {
        if ($useNames -notcontains $c.name) { continue }
        $cfgLines += ('    { "name": "' + $c.name + '", "note": "round ' + $r + ' candidate", "theta": { ' + (Theta-Json $c.theta) + ' }, "beam": ' + $SearchBeam + ', "beam_opp": ' + $SearchBeam + ' },')
      }
      $anchor = '"configs": ['
      $ix = $raw.IndexOf($anchor)
      if ($ix -lt 0) { throw '多阵容搜索: 主 spec 找不到 "configs": [ 锚点' }
      $ix = $ix + $anchor.Length
      $body = $raw.Substring(0, $ix) + "`r`n" + ($cfgLines -join "`r`n") + $raw.Substring($ix)
      $body = [regex]::Replace($body, '("enemy"\s*:\s*")[^"]*(")', ('${1}' + ($lu.enemy -join ',') + '${2}'), 1)
      $body = [regex]::Replace($body, '("player"\s*:\s*")[^"]*(")', ('${1}' + ($lu.player -join ',') + '${2}'), 1)
      $body = [regex]::Replace($body, '("enabled"\s*:\s*)true', '${1}false', 1)
      [System.IO.File]::WriteAllText($specPath, $body, [System.Text.UTF8Encoding]::new($true))
      $gj = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$gj.decks.enemy -ne ($lu.enemy -join ',')) { throw ('多阵容搜索: 生成的 spec decks.enemy 不等于 L' + $lu.idx + '（实际 ' + $gj.decks.enemy + '）') }
      if ([string]$gj.decks.player -ne ($lu.player -join ',')) { throw ('多阵容搜索: 生成的 spec decks.player 不等于 L' + $lu.idx + '（实际 ' + $gj.decks.player + '）') }
      if ($gj.league -and $gj.league.enabled) { throw ('多阵容搜索: L' + $lu.idx + ' 的 spec league.enabled 仍是 true（固定对手模式要求 false）') }

      $cfgArg = $useNames -join ','
      $outLog = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP ('multi_' + $luTag + '_s' + $st.n + '.out')))
      Say ('    L' + $lu.idx + ' 阶段' + $st.n + ' → run=' + $runName + ' 臂=' + $useNames.Count)
      $lines = Invoke-Train -ArgLine ("-Task run -Run '" + $runName + "' -Spec '" + $specPath + "' -Configs '" + $cfgArg + "' -SeedSet train -MaxSeeds " + $st.seeds + ' -Workers ' + $Workers + ' -TimeoutSec ' + $TimeoutSec + ' -FixedDecks') -Label ('轮' + $r + ' L' + $lu.idx + ' 阶段' + $st.n + ' run') -LogFile $outLog
      foreach ($l in @($lines | Where-Object { $_ -match 'arm consistency|completeness|accounting' })) { Say ('      | ' + $l) }
      Assert-LineupFixed -Run $runName -ExpectP $lu.player -ExpectE $lu.enemy -Label ('轮' + $r + ' L' + $lu.idx)

      # 该阵容上每个存活候选的 Δpts（对控制组，逐局配对）
      if (-not $perLineup.ContainsKey($lu.idx)) { $perLineup[$lu.idx] = @{}; $perLineupPairs[$lu.idx] = @{} }
      foreach ($n2 in $useNames) {
        if ($n2 -eq $cName) { continue }
        $pd = Get-PairedPoints -Run $runName -Control $cName -Treat $n2
        $perLineup[$lu.idx][$n2] = $pd.dpts
        $perLineupPairs[$lu.idx][$n2] = $pd.pairs
      }
    }
    # 淘汰：按"已测得阵容上的平均 Δpts"保留前 keep 名
    $score = @{}
    foreach ($n2 in $alive) {
      $vals = @()
      foreach ($lu in $lineups) { if ($perLineup[$lu.idx].ContainsKey($n2)) { $vals += [double]$perLineup[$lu.idx][$n2] } }
      if ($vals.Count -gt 0) { $score[$n2] = ($vals | Measure-Object -Average).Average } else { $score[$n2] = [double]::NegativeInfinity }
    }
    $alive = @($alive | Sort-Object { -$score[$_] } | Select-Object -First $st.keep)
    Say ('    阶段' + $st.n + ' 存活: ' + (($alive | ForEach-Object { $_ + '(' + [Math]::Round($score[$_],2) + ')' }) -join ' | '))
  }

  # 4) 聚合：每个候选在每套阵容上的 Δpts → 均值 + 95% CI（t 近似用 1.96，n 小则用 t 表）
  #    配对完整性闸门：每个候选在每套阵容上必须有相同的 seed 集合（= 相同的 pairs 数），缺则点名。
  $finalists = @($cands | Where-Object { $_.name -in $alive } | ForEach-Object { $_.name })
  if ($finalists.Count -eq 0) { $finalists = @($perLineup[1].Keys) }
  $missing = @()
  foreach ($n2 in $finalists) {
    $pc = @()
    foreach ($lu in $lineups) { if ($perLineupPairs[$lu.idx].ContainsKey($n2)) { $pc += [int]$perLineupPairs[$lu.idx][$n2] } else { $pc += -1 } }
    if (@($pc | Where-Object { $_ -le 0 }).Count -gt 0) { $missing += ($n2 + '（各阵容 pairs=' + ($pc -join '/') + '）'); continue }
    if (@($pc | Sort-Object -Unique).Count -gt 1) { $missing += ($n2 + ' 配对局数不一致（各阵容 pairs=' + ($pc -join '/') + '）') }
  }
  if ($missing.Count -gt 0) {
    $msg = 'PAIRED INTEGRITY FAILURE: 以下候选在各阵容上的配对局数不一致或有缺失，聚合会拿不同 seed 集合平均（不可比）：' + ($missing -join ' ; ')
    Say ('  ✗ ' + $msg)
    throw $msg
  }
  Say ('  ✓ 配对完整性：' + $finalists.Count + ' 个候选 × ' + $lineups.Count + ' 套阵容，配对局数一致')

  $agg = @()
  foreach ($n2 in $finalists) {
    $vals = @(); foreach ($lu in $lineups) { $vals += [double]$perLineup[$lu.idx][$n2] }
    $m = ($vals | Measure-Object -Average).Average
    $sd = 0.0
    if ($vals.Count -gt 1) { $sd = [Math]::Sqrt((($vals | ForEach-Object { [Math]::Pow($_ - $m, 2) }) | Measure-Object -Sum).Sum / ($vals.Count - 1)) }
    # 小样本用 t 临界值（95% CI）
    $tCrit = @{ 1 = 12.706; 2 = 4.303; 3 = 3.182; 4 = 2.776; 5 = 2.571; 6 = 2.447; 7 = 2.365; 8 = 2.306; 9 = 2.262; 10 = 2.228 }[[Math]::Min(10, [Math]::Max(1, $vals.Count))]
    $half = 0.0
    if ($vals.Count -gt 1) { $half = $tCrit * $sd / [Math]::Sqrt([double]$vals.Count) }
    $agg += [pscustomobject]@{ name = $n2; mean = $m; ciLo = ($m - $half); ciHi = ($m + $half); sd = $sd
                              min = ($vals | Measure-Object -Minimum).Minimum; max = ($vals | Measure-Object -Maximum).Maximum
                              vals = $vals }
  }
  $agg = @($agg | Sort-Object { -$_.mean })
  Say ('  ==== 轮' + $r + ' 聚合排名（跨 ' + $lineups.Count + ' 套阵容）====')
  foreach ($a in $agg) {
    Say ('    ' + $a.name.PadRight(10) + ' 均值Δpts=' + (Format-Num $a.mean 3).PadLeft(8) + '  95%CI=[' + (Format-Num $a.ciLo 3) + ', ' + (Format-Num $a.ciHi 3) + ']  min/max=' + (Format-Num $a.min 2) + '/' + (Format-Num $a.max 2))
  }

  # 5) 报告 md + 累积池
  $md = [System.IO.Path]::GetFullPath((Join-Path $logDir ('多阵容_' + $Tag + '_R' + $r + '.md')))
  $ml = @()
  $ml += ('# 多阵容搜索 轮 ' + $r + '（Tag=' + $Tag + '）')
  $ml += ''
  $ml += ('生成于 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '；阵容种子 Seed0=' + $Seed0 + '；控制组 = 默认比例')
  $ml += ''
  $ml += '## 本轮固定阵容'
  $ml += ''
  $ml += '| 阵容 | 我方 | 敌方 |'
  $ml += '|---|---|---|'
  foreach ($lu in $lineups) { $ml += ('| L' + $lu.idx + ' | `' + ($lu.player -join ',') + '` | `' + ($lu.enemy -join ',') + '` |') }
  $ml += ''
  $ml += '## Δpts 矩阵（行=候选，列=阵容；对控制组逐局配对）'
  $ml += ''
  $ml += ('| 候选 | ' + (($lineups | ForEach-Object { 'L' + $_.idx }) -join ' | ') + ' | 均值 | 95% CI |')
  $ml += ('|---' + ('|---' * $lineups.Count) + '|---|---|')
  foreach ($a in $agg) {
    $cells = @(); foreach ($lu in $lineups) { $cells += (Format-Num ([double]$perLineup[$lu.idx][$a.name]) 3) }
    $ml += ('| ' + $a.name + ' | ' + ($cells -join ' | ') + ' | **' + (Format-Num $a.mean 3) + '** | [' + (Format-Num $a.ciLo 3) + ', ' + (Format-Num $a.ciHi 3) + '] |')
  }
  $ml += ''
  $ml += ('- 每个候选的配对局数：' + (@($lineups | ForEach-Object { 'L' + $_.idx + '=' + $perLineupPairs[$_.idx][$agg[0].name] }) -join ' '))
  $ml += ('- 冠军（本轮最优比例）：**' + $agg[0].name + '** 均值Δpts=' + (Format-Num $agg[0].mean 3) + ' CI=[' + (Format-Num $agg[0].ciLo 3) + ', ' + (Format-Num $agg[0].ciHi 3) + ']')
  [System.IO.File]::WriteAllLines($md, $ml, (New-Object System.Text.UTF8Encoding($false)))
  Say ('  报告: ' + $md)

  foreach ($a in $agg) {
    $candObj = @($cands | Where-Object { $_.name -eq $a.name })[0]
    $combo = ''
    if ($candObj) { $combo = Get-ComboFingerprint $candObj.theta }
    $row = $Tag + ',' + $r + ',' + $a.name + ',"' + $combo + '",' + (Format-Num $a.mean 4) + ',' + (Format-Num $a.ciLo 4) + ',' + (Format-Num $a.ciHi 4) + ',' +
           $lineups.Count + ',' + (Format-Num $a.min 4) + ',' + (Format-Num $a.max 4)
    Add-Content -LiteralPath $poolCsv -Value $row -Encoding UTF8
  }
  Say ('  比例池: ' + $poolCsv + '（追加 ' + $agg.Count + ' 行）')

  # 本轮最优写入 multi_best（只有真的比历史最好更好才写）
  $top = $agg[0]
  if ($top.mean -gt $bestMean) {
    $co = @($cands | Where-Object { $_.name -eq $top.name })[0]
    if ($co) {
      $j = Get-Content -LiteralPath $bestW -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in $KEYS) { $j.$k = [Math]::Round([double]$co.theta[$k], 4) }
      ($j | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bestW -Encoding UTF8
      $bestMean = $top.mean
      $noImprove = 0
      Say ('  ✔ 轮' + $r + ' 新的历史最优: ' + $top.name + ' 均值Δpts=' + (Format-Num $top.mean 3) + ' → ' + $bestW)
      try { Copy-Item -LiteralPath $bestW -Destination ([System.IO.Path]::GetFullPath((Join-Path $logDir ('多阵容_' + $Tag + '_R' + $r + '_best.json')))) -Force } catch { }
    }
  } else {
    $noImprove++
    Say ('  ✗ 轮' + $r + ' 没有超过历史最优（本轮最好 ' + $top.name + ' 均值=' + (Format-Num $top.mean 3) + ' vs 历史 ' + (Format-Num $bestMean 3) + '）→ 无进步 ' + $noImprove + '/' + $Patience)
  }
  if ($Patience -gt 0 -and $noImprove -ge $Patience) { Say ('连续 ' + $Patience + ' 轮无提升 → 停止'); break }
}

Say ('===== 全部轮次结束 =====')
Say ('  历史最优比例: ' + $bestW)
Say ('  比例池（用于挑 top-k 做留出集验收）: ' + $poolCsv)
Say ('  提醒: 验收必须用正式档 beam 400 + 留出集面板（困难档 800/100、上一代自己、镜像自对弈），')
Say ('        并把"每局从 top-k 随机取一个"的混合物当成一个整体测，不要只看单比例。')
