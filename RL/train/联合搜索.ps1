# RL/train/联合搜索.ps1 —— 全部参数"联合调到最优比例"的搜索器（2026-09-14 加）
#
# 与"坐标上升（一次一个参数）"的区别：这里每一代**同时扰动全部可搜键**，用同一批种子配对评估，
# 逐轮淘汰（racing）控制成本，留下最好的比例；能吃到参数之间的交互项。
#
# 为什么搜"比例"而不是绝对值：实测 KILL_BONUS 35→17.5 与 35→70 的 32 局**逐局完全相同**
# → AI 的决策只取决于相对权重，绝对尺度几乎无影响。所以这里每个候选都是"整组比例"。
#
# 方法论：(1+λ) 进化策略 + racing
#   每代：λ 个候选（对数正态扰动 σ）+ 控制组（当前最优比例）
#         阶段1：全部候选 × 6 seeds(24局)  → 留前 4
#         阶段2：前 4 × 16 seeds(64局)     → 留前 2
#         阶段3：前 2 × 48 seeds(192局)    → 出冠军
#   冠军若优于控制组（Δpts>0），就把 best 更新成它；连续 -Patience 代不进步就停。
#   搜索期用便宜档（-SearchBeam，默认 100：实测 beam 100 与 800 强度无可分辨差别、单局便宜 2~3 倍）；
#   最后验收必须回到正式档（beam 400）+ 留出集面板，不吃便宜档红利。
#
# 用法（固定阵容模式 = 用户要的"一条固定阵容打到底，只调参数比例"）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File RL\train\联合搜索.ps1 `
#     -Generations 12 -Workers 4 -Decks "hero_13,hero_12,hero_23|hero_06,hero_17,hero_26" -LineupTag L1
#   不带 -Decks 时沿用主 spec 的 seed 轮转阵容（每局换阵容，配对仍然有效，但那不是"固定阵容"模式）。
param(
  [int]$Generations = 12,
  [double]$Sigma = 0.20,
  [int]$Workers = 8,
  [int]$SearchBeam = 100,
  [int]$Patience = 3,
  [double]$Stage1Seeds = 6, [double]$Stage2Seeds = 16, [double]$Stage3Seeds = 48,
  [string]$Run = 'joint',
  [string]$RepoRoot = '',
  # 固定阵容：'P,E'（玩家方 3 个英雄 | 敌方 3 个英雄）。给了就写进生成的 spec 的 decks.enemy/decks.player
  # 并用 -FixedDecks 跑，这样一套阵容打到底，只有参数比例在变。
  [string]$Decks = '',
  # 阵容标签，只用于日志/文件命名（哪套阵容的第几代）。空则从 -Decks 自动生成短标签。
  [string]$LineupTag = '',
  # 把 best 起点换成指定权重文件（默认 RL/weights/joint_best.json）。每套阵容建议各自的起点。
  [string]$BestWeights = ''
)
$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path (Join-Path $RepoRoot 'RL\train\train_spec.json'))) { $RepoRoot = 'D:\Game creating\战旗' }
$train  = Join-Path $RepoRoot 'RL\train\Train.ps1'
$baseSpec = Join-Path $RepoRoot 'RL\train\train_spec.json'
$baseW  = Join-Path $RepoRoot 'RL\weights\噩梦.json'
# 固定阵容模式：每套阵容独立的 best 文件，互不覆盖（L1 的冠军不能被 L2 的搜索冲掉）
if ($BestWeights) { $bestW = $BestWeights }
elseif ($Decks) { $bestW = Join-Path $RepoRoot ('RL\weights\joint_best_' + ($(if ($LineupTag) { $LineupTag } else { 'lineup' })) + '.json') }
else { $bestW = Join-Path $RepoRoot 'RL\weights\joint_best.json' }
$logDir = Join-Path $RepoRoot 'RL\reports'
# 日志名也按阵容分开，否则两套阵容的日志会混在一起看
if ($Decks -and -not $LineupTag) {
  $LineupTag = (($Decks -replace '[^A-Za-z0-9_]+', '') ).Substring(0, [Math]::Min(12, (($Decks -replace '[^A-Za-z0-9_]+', '')).Length))
}
$log = Join-Path $logDir ($(if ($LineupTag) { '联合搜索_' + $LineupTag + '_日志.md' } else { '联合搜索_日志.md' }))
# 固定阵容：解析 -Decks 'P|E'，校验每侧 3 个 hero_NN
$deckP = ''; $deckE = ''
if ($Decks) {
  $parts = $Decks -split '\|'
  if ($parts.Count -ne 2) { throw ('联合搜索: -Decks 必须是 ''玩家3个|敌方3个'' 形式，收到: ' + $Decks) }
  $deckP = $parts[0].Trim(); $deckE = $parts[1].Trim()
  foreach ($pair in @(@('player', $deckP), @('enemy', $deckE))) {
    $hs = @($pair[1] -split ',')
    if ($hs.Count -ne 3) { throw ('联合搜索: ' + $pair[0] + ' 阵容必须是 3 个英雄，收到 ' + $hs.Count + ' 个: ' + $pair[1]) }
    foreach ($h in $hs) { if ($h.Trim() -notmatch '^hero_[0-9]{2}$') { throw ('联合搜索: 非法英雄 id: ' + $h.Trim()) } }
  }
}
# 可搜的键（BEAM/JITTER 不参与：前者是算力、后者是噪声；HERO_VALUE 之后按族分批加入）
# （KILL_BONUS 2026-09-15 起也不参与：实测无用，噩梦档由权重钉死 0）
$KEYS = @('FOCUS_FIRE_WEIGHT','GOLD_TAKE_VALUE','GOLD_TAKE_VALUE_LOW','GOLD_LOW_ATK',
          'BUFF_TAKE_WEIGHT','THREAT_MOVE_DISCOUNT','OBSTACLE_DETOUR_WEIGHT','ENGAGE_PULL_PER_CELL','MAX_MOVE_OPTIONS')
function Say($m) { $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m; Write-Host $line; Add-Content -Path $log -Value $line -Encoding UTF8 }
function Get-Theta([string]$path) {
  $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $h = @{}; foreach ($k in $KEYS) { $h[$k] = [double]$j.$k }
  return $h
}
function Theta-Json($h) { ($KEYS | ForEach-Object { '"' + $_ + '": ' + ([Math]::Round($h[$_], 4)).ToString([System.Globalization.CultureInfo]::InvariantCulture) }) -join ', ' }

if (-not (Test-Path $bestW)) {
  # 初始化必须真的成功：Copy-Item 的失败在 $ErrorActionPreference='Continue' 下是【非终止】错误，
  # 会被静默吞掉，然后整个搜索跑在一份不存在的/旧的起点上（整轮结果作废而日志看不出来）。
  try {
    Copy-Item -LiteralPath $baseW -Destination $bestW -ErrorAction Stop
  } catch {
    Say ('✗ 初始化 best 失败: ' + $_.Exception.Message)
    throw ('联合搜索: 无法把 ' + $baseW + ' 复制成 ' + $bestW + '；拒绝在错误的起点上开跑')
  }
  if (-not (Test-Path $bestW)) { throw ('联合搜索: 复制后 ' + $bestW + ' 仍不存在，拒绝开跑') }
  # 逐字节核对起点，并把 sha 写进日志（以后一眼能看出这轮从哪份比例出发）
  $shaA = (Get-FileHash -Algorithm SHA256 -LiteralPath $baseW).Hash.Substring(0,12).ToLower()
  $shaB = (Get-FileHash -Algorithm SHA256 -LiteralPath $bestW).Hash.Substring(0,12).ToLower()
  if ($shaA -ne $shaB) { throw ('联合搜索: 起点副本内容不一致 (base=' + $shaA + ' best=' + $shaB + ')') }
  Say ('初始化 best = 噩梦.json 的比例副本 → ' + $bestW + ' (sha12=' + $shaB + '，与源文件一致)')
} else {
  Say ('沿用已有 best: ' + $bestW + ' (sha12=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $bestW).Hash.Substring(0,12).ToLower() + ')')
}
$bestTheta = Get-Theta $bestW
Say ('起点比例: ' + (Theta-Json $bestTheta))
Say ('配置: 代数上限=' + $Generations + ' σ=' + $Sigma + ' 并发=' + $Workers + ' 搜索档beam=' + $SearchBeam + ' 耐心=' + $Patience)

$rng = New-Object System.Random 20260914
$noImprove = 0
for ($g = 1; $g -le $Generations; $g++) {
  if ($noImprove -ge $Patience) { Say ('连续 ' + $Patience + ' 代无提升 → 停止'); break }
  Say ('===== 第 ' + $g + ' 代 开始 =====')
  # 1) 采样 λ=8 个候选（对数正态扰动，确定性：固定 rng 序列）
  $cands = @()
  for ($i = 1; $i -le 8; $i++) {
    $h = @{}; foreach ($k in $KEYS) {
      $u1 = [Math]::Max($rng.NextDouble(), 1e-9); $u2 = $rng.NextDouble()
      $z = [Math]::Sqrt(-2 * [Math]::Log($u1)) * [Math]::Cos(2 * [Math]::PI * $u2)
      $h[$k] = $bestTheta[$k] * [Math]::Exp($z * $Sigma) }
    $cands += ,@{ name = ('g' + $g + '_c' + $i); theta = $h } }
  # 2) 写一份"当代专用"的 spec（不动主 spec）：控制组 + 8 候选
  $raw = [System.IO.File]::ReadAllText($baseSpec, [System.Text.Encoding]::UTF8)
  $lines = @()
  $lines += '    { "name": "g' + $g + '_best", "note": "control: current best ratio", "theta": { ' + (Theta-Json $bestTheta) + ' }, "beam": ' + $SearchBeam + ', "beam_opp": ' + $SearchBeam + ' },'
  foreach ($c in $cands) { $lines += '    { "name": "' + $c.name + '", "note": "gen ' + $g + ' candidate", "theta": { ' + (Theta-Json $c.theta) + ' }, "beam": ' + $SearchBeam + ', "beam_opp": ' + $SearchBeam + ' },' }
  $anchor = '"configs": ['
  $idx = $raw.IndexOf($anchor); if ($idx -lt 0) { Say '✗ 找不到 configs 锚点，退出'; break }
  $idx = $idx + $anchor.Length
  $specName = 'spec_joint'
  if ($LineupTag) { $specName = 'spec_lineup' + $LineupTag }
  $genSpec = Join-Path $RepoRoot ('RL\train\' + $specName + '_g' + $g + '.json')
  $body = $raw.Substring(0, $idx) + "`r`n" + ($lines -join "`r`n") + $raw.Substring($idx)

  # 固定阵容 / 固定对手：直接改生成的副本里的两个节点，主 spec 一个字节都不动。
  # 为什么必须关掉 league：那一代的配对比较要求"同一 (seed,first) 上所有候选面对完全同一个对手"，
  # 70/30 混池会让这一点不成立（也是用户抓到的那个真 bug 的现场）。
  # 用正则替换 JSON 值，而不是 ConvertFrom-Json→改→ConvertTo-Json：后者会把整个 spec 重排、丢注释，
  # 生成的 spec 就跟主 spec 不再逐行可比了。
  $fixed = @()
  if ($Decks) {
    $body = [regex]::Replace($body, '("enemy"\s*:\s*")[^"]*(")', ('${1}' + $deckE + '${2}'), 1)
    $body = [regex]::Replace($body, '("player"\s*:\s*")[^"]*(")', ('${1}' + $deckP + '${2}'), 1)
    # league 块里第一个 "enabled": true 改成 false（非贪婪、只换第一个）
    $body = [regex]::Replace($body, '("enabled"\s*:\s*)true', '${1}false', 1)
    $fixed += 'decks 固定 enemy=' + $deckE + ' player=' + $deckP + ' + league.enabled=false + 跑 -FixedDecks'
  }
  [System.IO.File]::WriteAllText($genSpec, $body, [System.Text.UTF8Encoding]::new($true))
  try { $gj = Get-Content $genSpec -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Say ('✗ 生成的 spec JSON 坏了: ' + $_.Exception.Message); break }
  # 校验替换真的生效了（静默替换失败=整代白跑）
  if ($Decks) {
    if ([string]$gj.decks.enemy -ne $deckE) { Say ('✗ 生成的 spec decks.enemy 没改成 ' + $deckE + '（实际 ' + $gj.decks.enemy + '），停止这一代'); break }
    if ([string]$gj.decks.player -ne $deckP) { Say ('✗ 生成的 spec decks.player 没改成 ' + $deckP + '（实际 ' + $gj.decks.player + '），停止这一代'); break }
    if ($gj.league -and $gj.league.enabled) { Say '✗ 生成的 spec league.enabled 仍是 true（固定对手模式要求 false），停止这一代'; break }
  }
  Say ('  spec: ' + (Split-Path -Leaf $genSpec) + '  阵容/对手: ' + $(if ($fixed.Count -gt 0) { $fixed -join '; ' } else { '主 spec 的 seed 轮转阵容（未固定）' }))

  # 3) 分阶段 racing
  $stage = @(@{ n = 1; seeds = [int]$Stage1Seeds; keep = 4 }, @{ n = 2; seeds = [int]$Stage2Seeds; keep = 2 }, @{ n = 3; seeds = [int]$Stage3Seeds; keep = 1 })
  $alive = @($cands | ForEach-Object { $_.name })
  $champ = $null; $champDelta = 0.0
  foreach ($s in $stage) {
    $names = @('g' + $g + '_best') + $alive
    $cfgArg = $names -join ','
    $rname = $Run + '_g' + $g + 's' + $s.n
    Say ('  阶段' + $s.n + '：' + $names.Count + ' 个臂 × ' + $s.seeds + ' seeds（' + ($s.seeds * 4) + ' 局/臂）')
    $runOut = Join-Path $env:TEMP ('joint_g' + $g + 's' + $s.n + '.out')
    $fdArg = ''
    if ($Decks) { $fdArg = ' -FixedDecks' }   # 固定阵容必须配 -FixedDecks，否则仍按 seed 轮转阵容
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$train' -Task run -Run $rname -Spec '$genSpec' -Configs $cfgArg -SeedSet train -MaxSeeds $($s.seeds) -Workers $Workers -TimeoutSec 10800$fdArg" *>> $runOut
    $runExit = $LASTEXITCODE
    if ($runExit -ne 0) {
      # 训练器现在对"没跑完/跑错了"是响亮失败（截断、指纹不匹配、闸门），所以这里必须把原文带出来，
      # 否则又变成"只报现象不报原因"。
      Say ('  ✗ 阶段' + $s.n + ' run 失败（exit=' + $runExit + '），完整输出: ' + $runOut)
      foreach ($l in @(Get-Content -Encoding UTF8 $runOut -ErrorAction SilentlyContinue | Select-Object -Last 25)) { Say ('      | ' + [string]$l) }
      Say '  ✗ 停止这一代'
      break
    }
    # -OutMd 必须是【绝对路径】。Train.ps1 的 Write-TextUtf8 用 [System.IO.File]::WriteAllLines，
    # 相对路径按【调用进程的 CWD】解析 —— 而本脚本用 `& powershell.exe` 起子进程，CWD 继承自用户
    # 启动环境，不保证是项目根。实测在 CWD=C:\ 时 `-OutMd 'RL/reports/x.md'` 会变成往 C:\RL 写，
    # 直接 FATAL: UnauthorizedAccessException: Access to the path 'RL' is denied，exit=1。
    $md = [System.IO.Path]::GetFullPath((Join-Path $logDir ('joint_g' + $g + 's' + $s.n + '.md')))
    # 先删旧文件：否则上一轮留下的同名表会让"没产出"检查误判为成功
    if (Test-Path -LiteralPath $md) { Remove-Item -LiteralPath $md -Force -ErrorAction SilentlyContinue }
    $cmpOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$train' -Task compare -Run $rname -Spec '$genSpec' -Configs $cfgArg -OutMd '$md'" 2>&1
    $cmpExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $md)) {
      # 报【真实原因】，不要再只说"没有产出比较表"：把 compare 的 stdout+stderr 与退出码原样打出来。
      Say ('  ✗ 阶段' + $s.n + ' compare 失败（exit=' + $cmpExit + '），没有产出 ' + $md)
      Say ('  ✗ compare 原始输出（stdout+stderr）:')
      foreach ($l in @($cmpOut)) { Say ('      | ' + [string]$l) }
      if (-not $cmpOut -or @($cmpOut).Count -eq 0) { Say '      | (空 —— 子进程没吐任何东西)' }
      Say ('  ✗ 停止这一代（不要再往下跑阶段' + ($s.n + 1) + '浪费对局）')
      break
    }
    if ($cmpExit -ne 0) {
      # 表在但退出码非 0：说明 compare 后半段出了别的错，表可能不完整，必须让用户看到
      Say ('  ! 阶段' + $s.n + ' compare exit=' + $cmpExit + ' 但表已生成，原始输出如下（表可能不完整）:')
      foreach ($l in @($cmpOut)) { Say ('      | ' + [string]$l) }
    }
    $rows = @(Get-Content $md -Encoding UTF8 | Where-Object { $_ -match '^\| g' + $g + '_c' })
    # 按【表头】定位 d_pts 列，不硬编码下标：Train.ps1 的 SensitivityTable 以后加列（它已经加过
    # beam_opp/opp/wB_sha/inv），硬编码 $p[6] 会静默取到错的数——又是一次"静默错"。
    $hdrLine = @(Get-Content $md -Encoding UTF8 | Where-Object { $_ -match '^\|\s*treatment\s*\|' })[0]
    $dIdx = 6
    if ($hdrLine) {
      $hc = @(($hdrLine -split '\|') | ForEach-Object { $_.Trim() })
      for ($ci = 0; $ci -lt $hc.Count; $ci++) { if ($hc[$ci] -eq 'd_pts') { $dIdx = $ci; break } }
    } else { Say '  ! 表里找不到 treatment 表头行，d_pts 列回退到下标 6' }
    $ranked = @()
    foreach ($r in $rows) {
      $p = $r -split '\|'
      if ($p.Count -le $dIdx) { Say ('  ! 跳过列数不足的行: ' + $r); continue }
      $dv = 0.0
      if (-not [double]::TryParse($p[$dIdx].Trim(), [ref]$dv)) { Say ('  ! 跳过 d_pts 非数字的行: ' + $r); continue }
      $ranked += ,@{ name = $p[1].Trim(); dpts = $dv } }
    if ($ranked.Count -eq 0) { Say ('  ✗ 阶段' + $s.n + ' 比较表里没有可解析的候选行，停止这一代'); break }
    $ranked = @($ranked | Sort-Object { -$_.dpts })
    Say ('  阶段' + $s.n + ' 排名: ' + (($ranked | ForEach-Object { $_.name + ' ' + $_.dpts }) -join ' | '))
    $alive = @($ranked | Select-Object -First $s.keep | ForEach-Object { $_.name })
    if ($s.n -eq 3 -and $alive.Count -ge 1) {
      $win = $ranked[0]
      $champ = $win.name; $champDelta = $win.dpts
      Say ('  🏆 冠军 ' + $champ + '  Δpts=' + $champDelta + '（控制组 g' + $g + '_best，' + $ranked.Count + ' 个候选参与排序）')
    } }
  # 4) 冠军若优于控制组 → 更新 best
  if ($champ -and $champDelta -gt 0) {
    $c = $cands | Where-Object { $_.name -eq $champ }
    $j = Get-Content $bestW -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $KEYS) { $j.$k = [Math]::Round($c.theta[$k], 4) }
    ($j | ConvertTo-Json -Depth 6) | Set-Content $bestW -Encoding UTF8
    $bestTheta = Get-Theta $bestW
    $noImprove = 0
    Say ('  ✔ 第 ' + $g + ' 代提升：' + $champ + '（Δpts ' + $champDelta + '）→ best 已更新为 ' + (Theta-Json $bestTheta))
  } else {
    $noImprove++
    # "冠军" 此时只是【候选里最好的那个】，它仍然输给控制组（Δpts<=0），所以 best 不动。
    # 说清楚，免得日志里一个负 Δpts 的"冠军"看起来像 bug。
    $what = $(if ($champ) { '候选里最好的 ' + $champ + ' Δpts ' + $champDelta + ' ≤ 0，控制组仍是最优' } else { '这一代没跑出冠军' })
    Say ('  ✗ 第 ' + $g + ' 代没有提升（' + $what + '）→ 无进步计数 ' + $noImprove + '/' + $Patience) }
}
Say ('搜索结束。最优比例在 ' + $bestW + ' —— 下一步：用正式档(beam 400) + 留出集面板做验收，别用搜索期的便宜档结论')
