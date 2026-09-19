# RL/train/通用性测试.ps1 —— 第三步：把"每套阵容各自选出的最优比例"丢进随机对局，看哪个最通用
#
# 流程里的位置：
#   1) 固定一套阵容 → 联合搜索.ps1 -Decks "P|E" 找出这套阵容的最优比例
#   2) 换一套阵容 → 再来一次 → 又得一个最优比例
#   3) 本脚本：把这些比例（每套阵容的冠军 + 基线）放到**随机阵容、随机先手、可混合对手**的对局里
#      跑同样的一批 seed（配对），输出每个比例的 Δpts / Δ胜率 + 95% CI，按"跨阵容平均优势"排名。
#
# 为什么必须随机阵容：每套阵容各自调出来的比例会过拟合到那套阵容。只有换到没见过的阵容上还赢，
# 才说明这个"比例"本身是通用的。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File RL\train\通用性测试.ps1 `
#     -Candidates "RL/weights/joint_best_L1.json,RL/weights/joint_best_L2.json,RL/weights/噩梦.json" `
#     -BaselineIndex 2 -Seeds 24 -Workers 4
param(
  [Parameter(Mandatory = $true)][string]$Candidates,   # 逗号分隔的权重文件（相对项目根或绝对）
  [int]$BaselineIndex = 1,                             # 1-based：哪一个候选当基线（默认第一个）
  [int]$Seeds = 24,
  [int]$Workers = 4,
  [int]$Beam = 100,                                    # 搜索期便宜档；验收请显式给 400
  [int]$TimeoutSec = 10800,
  [string]$Run = '',                                   # 结果目录名，空则自动生成
  [switch]$WithLeague,                                 # 默认固定对手(base)；加此开关才用 spec 的 league
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Continue'
$t0 = Get-Date
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path (Join-Path $RepoRoot 'RL\train\train_spec.json'))) { $RepoRoot = 'D:\Game creating\战旗' }
$train    = Join-Path $RepoRoot 'RL\train\Train.ps1'
$baseSpec = Join-Path $RepoRoot 'RL\train\train_spec.json'
$logDir   = Join-Path $RepoRoot 'RL\reports'          # 绝对路径：相对路径会按子进程 CWD 解析
$stamp    = (Get-Date).ToString('yyyyMMdd_HHmmss')
if (-not $Run) { $Run = 'gen' + $stamp }
$outMd    = [System.IO.Path]::GetFullPath((Join-Path $logDir ('泛化_' + $stamp + '.md')))
$genSpec  = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ('RL\train\spec_gen_' + $stamp + '.json')))

function Say($m) { Write-Host $m }
function Get-H12([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.Substring(0,12).ToLower() }

# ---- 候选清单 ----
$candList = @()
$i = 0
foreach ($c in ($Candidates -split ',')) {
  $p = $c.Trim()
  if (-not $p) { continue }
  if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
  if (-not (Test-Path -LiteralPath $p)) { throw ('通用性测试: 候选权重文件不存在: ' + $p) }
  $i++
  $candList += [pscustomobject]@{ idx = $i; file = $p; name = ('u' + $i + '_' + [System.IO.Path]::GetFileNameWithoutExtension($p)); sha12 = (Get-H12 $p) }
}
if ($candList.Count -lt 2) { throw '通用性测试: 至少需要 2 个候选（基线 + 至少一个待测比例）' }
if ($BaselineIndex -lt 1 -or $BaselineIndex -gt $candList.Count) { throw ('通用性测试: -BaselineIndex 越界（1..' + $candList.Count + '）') }
$baseCand = $candList[$BaselineIndex - 1]
Say ('===== 通用性测试 run=' + $Run + ' =====')
Say ('  基线: ' + $baseCand.name + ' (' + [System.IO.Path]::GetFileName($baseCand.file) + ' sha12=' + $baseCand.sha12 + ')')
Say ('  候选: ' + (($candList | ForEach-Object { $_.name }) -join ', '))
Say ('  随机阵容 + 随机先手 + 对手=' + $(if ($WithLeague) { 'league 混池' } else { '固定 base 档 beam=' + $Beam }) + '；seeds=' + $Seeds + ' 并发=' + $Workers)

# ---- 生成一份"随机阵容 + 指定候选 + 固定对手"的 spec ----
$raw = [System.IO.File]::ReadAllText($baseSpec, [System.Text.Encoding]::UTF8)
$cfgLines = @()
foreach ($c in $candList) {
  $cfgLines += ('    { "name": "' + $c.name + '", "note": "generality candidate ' + $c.idx + ' sha12=' + $c.sha12 + '", "weights": "' +
                (($c.file.Substring($RepoRoot.Length).TrimStart('\')) -replace '\\', '/') + '", "theta": {}, "beam": ' + $Beam + ', "beam_opp": ' + $Beam + ' },')
}
$anchor = '"configs": ['
$idx = $raw.IndexOf($anchor)
if ($idx -lt 0) { throw '通用性测试: 主 spec 里找不到 "configs": [ 锚点' }
$idx = $idx + $anchor.Length
$body = $raw.Substring(0, $idx) + "`r`n" + ($cfgLines -join "`r`n") + $raw.Substring($idx)
if (-not $WithLeague) {
  # 固定对手：关掉 league，全部 cell 都 opp=base（同一 (seed,first) 所有候选面对同一个对手）
  $body2 = [regex]::Replace($body, '("enabled"\s*:\s*)true', '${1}false', 1)
  if ($body2 -eq $body) { Say '  ! 未能把 league.enabled 改成 false（spec 里可能没这个键），继续但请自行确认' }
  $body = $body2
}
[System.IO.File]::WriteAllText($genSpec, $body, [System.Text.UTF8Encoding]::new($true))
$gj = Get-Content $genSpec -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $WithLeague -and $gj.league -and $gj.league.enabled) { throw '通用性测试: 生成的 spec league.enabled 仍为 true，拒绝跑"固定对手"的泛化测试' }
Say ('  生成的 spec: ' + $genSpec)
Say ('  对手: ' + $(if ($gj.league -and $gj.league.enabled) { 'league 混池(' + $gj.league.self_play_fraction + ')' } else { '全部 opp=base beamB=' + $Beam }))

# ---- 真跑 ----
$cfgArg = ($candList | ForEach-Object { $_.name }) -join ','
$runLog = Join-Path $env:TEMP ('gen_' + $stamp + '.out')
Say ('  跑对局: -Task run -Run ' + $Run + ' ...')
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$train' -Task run -Run $Run -Spec '$genSpec' -Configs '$cfgArg' -SeedSet train -MaxSeeds $Seeds -Workers $Workers -TimeoutSec $TimeoutSec" *>> $runLog
$runExit = $LASTEXITCODE
if ($runExit -ne 0) {
  Say ('  ✗ run 失败 exit=' + $runExit + '，输出: ' + $runLog)
  foreach ($l in @(Get-Content -Encoding UTF8 $runLog -ErrorAction SilentlyContinue | Select-Object -Last 30)) { Say ('      | ' + [string]$l) }
  throw '通用性测试: run 阶段失败，见上面的原始输出'
}
foreach ($l in @(Get-Content -Encoding UTF8 $runLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'completeness|accounting|league\]' })) { Say ('      | ' + [string]$l) }

# ---- 比较表（基线为控制组） ----
# `-Task compare` 的约定是【-Configs 的第一个 = 控制组】，所以候选顺序必须重排成"基线在前"，
# 否则表里的 ctrl_rate/d_pts 是拿错的基线算出来的（本脚本早先只把 -BaselineIndex 用在打印上）。
$cmpOrder = @($baseCand) + @($candList | Where-Object { $_.idx -ne $baseCand.idx })
$cmpArg = ($cmpOrder | ForEach-Object { $_.name }) -join ','
Say ('  compare 控制组 = ' + $baseCand.name + '（-Configs 顺序: ' + $cmpArg + '）')
if (Test-Path -LiteralPath $outMd) { Remove-Item -LiteralPath $outMd -Force -ErrorAction SilentlyContinue }
$cmpOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$train' -Task compare -Run $Run -Spec '$genSpec' -Configs '$cmpArg' -OutMd '$outMd'" 2>&1
$cmpExit = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $outMd)) {
  Say ('  ✗ compare 失败 exit=' + $cmpExit + '，没有产出 ' + $outMd)
  foreach ($l in @($cmpOut)) { Say ('      | ' + [string]$l) }
  throw '通用性测试: compare 阶段失败（原始输出见上）'
}
Say ('  比较表: ' + $outMd)
Say ''
foreach ($l in @(Get-Content -Encoding UTF8 $outMd)) { Say $l }
Say ''
Say ('  总墙钟 ' + [int](((Get-Date) - $t0).TotalSeconds) + 's；下一步：换更多阵容重复第1~2步，把这个脚本的候选清单扩大再跑一次')
