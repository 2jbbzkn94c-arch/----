# RL/watch_run.ps1 —— 训练/测量任务的"边跑边看"看门狗（2026-09-14 加）
#
# 为什么要它：以前我都是"跑几小时 → 结束才检查"，结果经常是跑完才发现数据不可用
# （缺 cell、复用了旧版本的行、被 deadline 掐掉）。这个脚本在任务**运行期间**每分钟
# 做一次不变量检查，一有异常立刻喊出来并（可选）把这次的 Godot 全部掐掉，避免白跑两小时。
#
# 用法（配合任何 -Task run 一起跑）：
#   $env:APPDATA="$env:TEMP\dsh_x"; $env:ZB_NO_MIRROR='1'
#   Start-Job 内或另一个 pwsh 里：& RL\watch_run.ps1 -Run p1v5 -Configs p1_base,p1_ff_hi -GamesPerConfig 32 -MaxMinutes 240
#   -Run        训练器 -Run 的名字（看 results\<Run> 与 results\w*）
#   -Configs    这次要跑的 config 名（用来核对每个 config 的行数）
#   -GamesPerConfig 每个 config 计划局数（默认 32）
#   -AlarmAction Stop|Report   出问题时：掐掉 Godot（默认）还是只报告
#
# 检查项（每条都对应我实际踩过的坑）：
#   1. 日志里出现 FATAL / TRUNCATED / GLOBAL DEADLINE / "produced 0 game rows" / "short config"
#   2. 某个 config 长时间 0 行（>8 分钟）→ 它压根没被调度（丢 cell 的典型症状）
#   3. 完成 cell 数 < 已过时间应有的下限（进度停滞）
#   4. worker 池里出现重复测量键（同一 config+seed+first+aside+seq 出现两次 → 复用/污染）
#   5. 行数带上限：超过 计划局数 × 1.05 说明混进了别的 run 的行
param(
  [Parameter(Mandatory=$true)][string]$Run,
  [string[]]$Configs = @(),
  [int]$GamesPerConfig = 32,
  [int]$MaxMinutes = 240,
  [ValidateSet('Stop','Report')][string]$AlarmAction = 'Stop',
  [int]$IntervalSec = 60,
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
if (-not (Test-Path (Join-Path $RepoRoot 'RL\train\results'))) { $RepoRoot = 'D:\Game creating\战旗' }
# -File 调用时 -Configs a,b 会是一整个字符串 → 在这里拆开（否则计划局数会算错）
if ($Configs.Count -eq 1 -and $Configs[0] -match ',') { $Configs = @($Configs[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$results = Join-Path $RepoRoot 'RL\train\results'
$runDir  = Join-Path $results $Run
$log     = Join-Path $RepoRoot ('RL\reports\_watch_' + $Run + '.log')
function Say($m) { $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m; Write-Host $line; Add-Content -Path $log -Value $line -Encoding UTF8 }
Say ('看门狗启动 run=' + $Run + ' configs=' + $Configs.Count + ' 每config=' + $GamesPerConfig + ' 局 上限=' + $MaxMinutes + ' 分钟 动作=' + $AlarmAction)
$t0 = Get-Date
$planned = $Configs.Count * $GamesPerConfig
 = @()
$lastRows = -1
$lastChange = 0
while ($true) {
  Start-Sleep -Seconds $IntervalSec
  $mins = [int]((Get-Date) - $t0).TotalMinutes
  if ($mins -gt $MaxMinutes) { Say ('超过上限 ' + $MaxMinutes + ' 分钟，看门狗退出（run 继续）'); break }

  # ---- 1) 日志异常 ----
  $outFile = Join-Path $env:TEMP ($Run + '.out')
  $bad = @()
  if (Test-Path $outFile) {
    $hits = Get-Content $outFile -Encoding UTF8 -ErrorAction SilentlyContinue |
            Select-String 'FATAL|TRUNCATED|GLOBAL DEADLINE|produced 0 game rows|short config|!! worker'
    if ($hits) { $bad += ('日志异常 x' + @($hits).Count + '：' + (@($hits)[-1].Line.Trim().Substring(0,[Math]::Min(90,(@($hits)[-1].Line.Trim().Length))))) }
  }

  # ---- 2/3/5) 行数与每个 config 的覆盖 ----
  $all = @()
  $poolRoot = if (Test-Path (Join-Path $runDir 'w1')) { $runDir } else { $results }
  Get-ChildItem $poolRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'w*' } | ForEach-Object {
    $m = Join-Path $_.FullName 'measure.csv'
    if (Test-Path $m) { $all += (Import-Csv $m -Encoding UTF8) }
  }
  $rowsNow = $all.Count
  $perCfg = @{}
  foreach ($c in $Configs) { $perCfg[$c] = @($all | Where-Object { $_.config -eq $c }).Count }
    $zero = @($Configs | Where-Object { $perCfg[$_] -eq 0 -and $mins -ge 25 })
  if ($zero.Count -gt 0) { Say ('提醒（不掐）：这些 config 至今 0 行：' + ($zero -join ',')) }
  if ($rowsNow -gt [int]($planned * 1.05) -and $planned -gt 0) { $bad += ('行数 ' + $rowsNow + ' 超过计划 ' + $planned + ' 的 5% → 可能混进了别的 run 的行') }

  # ---- 4) 重复键 ----
  $dup = 0
  if ($rowsNow -gt 0) {
    $keys = $all | ForEach-Object { $_.config + '|' + $_.seed + '|' + $_.first + '|' + $_.a_side + '|' + $_.seq }
    $dup = @($keys | Group-Object | Where-Object { $_.Count -gt 1 }).Count
    if ($dup -gt 0) { $bad += ('发现重复测量键 ' + $dup + ' 组 → 复用/污染') }
  }

  # ---- 进度与 ETA ----
  $rate = 0.0; if ($mins -gt 0) { $rate = [Math]::Round($rowsNow / [double]$mins, 1) }
  $eta = 'n/a'; if ($rate -gt 0 -and $planned -gt 0) { $eta = [string][int](($planned - $rowsNow) / $rate) + ' 分钟' }
  $worst = ''
  if ($Configs.Count -gt 0) {
    $w = $Configs | Sort-Object { $perCfg[$_] } | Select-Object -First 1
    $worst = '最少: ' + $w + '=' + $perCfg[$w] + '/' + $GamesPerConfig
  }
  $status = 't=' + $mins + 'min 行=' + $rowsNow + '/' + $planned + ' (' + $rate + '/min, ETA ' + $eta + ') ' + $worst + ' 重复=' + $dup
  if ($bad.Count -eq 0) { Say ('OK  ' + $status) }
  else {
    Say ('!! 异常 ' + $status)
    foreach ($b in $bad) { Say ('   · ' + $b) }
    Say ('   结论：这一轮数据不可信，别等它跑完。')
    if ($AlarmAction -eq 'Stop') {
      $g = Get-Process godot* -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' }
      if ($g) { Say ('   掐掉 ' + @($g).Count + ' 个无窗口 Godot（只掐我自己的）'); $g | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
      break
    }
  }
}
Say '看门狗结束'
