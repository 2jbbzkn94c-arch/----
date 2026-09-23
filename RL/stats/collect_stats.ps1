<#
  RL\stats\collect_stats.ps1 -- batch runner + CSV merger for the match-stats tool.

  WHAT IT DOES
    Runs N real matches of RL\stats\<scene> (headless Godot) in up to 2 parallel
    workers, then merges every worker's CSVs into RL\reports\stats\:
        matches_<tag>_<MMDD_HHMMSS>.csv  +  fixed-name mirror matches.csv
        units_<tag>_<MMDD_HHMMSS>.csv    +  fixed-name mirror units.csv
    and finally prints one summary line per match.

  USAGE
    powershell -NoProfile -File RL\stats\collect_stats.ps1 -Mode 3v3 -Games 10 -Seed 7 -Beam 50
    powershell -NoProfile -File RL\stats\collect_stats.ps1 -Mode 5v5 -Games 20 -Seed 100 -Workers 2
    powershell -NoProfile -File RL\stats\collect_stats.ps1 -Games 10 -WeightsB base -Beam 800
    (double-click wrapper: test bat\<bat> -- forwards every argument to this script)

  PARAMETERS
    -Mode 3v3|5v5 (3v3)   -Games N (10)      -Seed S (7)        -Beam N (50)
    -Workers W (4, capped at 2)              -Tag T ('' -> mode name)
    -Speed N (20, Engine.time_scale only)    -WeightsA / -WeightsB ('' -> nightmare weights,
                                             'base' -> stock hard AI)   [NOT -WA/-WB: those
                                             collide with PowerShell's "wa" alias]
    -Godot <exe>  -Project <root>  -TimeoutSec N (3600)  -KeepParts

  CONCURRENCY RULES (do not relax)
    * -Workers defaults to 4 but the EFFECTIVE parallelism is capped at 2
      ($conc = min(Workers, 2)): this box also runs other Godot verification
      sweeps, and 5+ sharing one .godot cache crash silently.
    * Every worker gets its OWN APPDATA/LOCALAPPDATA sandbox, so each Godot
      resolves an isolated user:// directory.
    * Every worker sets ZB_NO_MIRROR=1, so no two workers ever write the same
      fixed-name file; the merger below is the only writer of those.

  NOTES
    * Godot stdout is NOT capturable by PowerShell: every worker is launched as
      `cmd /c "<godot>" ... > <log> 2>&1` and the log file is what we read.
    * Workers are started with Start-Process from THIS process -- deliberately NOT with
      Start-Job: inside a job, `Get-CimInstance` (needed to find the Godot child pid)
      dies with "Cannot process the element of node type 'Text'" and the whole job fails
      (silently, killing its own child). Per-worker APPDATA is set in this process right
      before each Start-Process (children inherit a copy of the environment) and restored
      immediately after, so no child process ever inherits another worker's sandbox.
    * A worker's own CSV is written incrementally (one write per finished match), so a
      crash late in a batch still leaves the finished matches on disk.
    * Only processes this script started are ever killed, and only after -TimeoutSec.
    * This file is deliberately pure ASCII (cmd/PowerShell read scripts as ANSI);
      Chinese path segments are built from code points, same trick as
      Data\Hero\Source\verify_heroes.ps1.
#>

[CmdletBinding()]
param(
	[ValidateSet('3v3', '5v5')][string]$Mode = '3v3',
	[int]$Games = 10,
	[int]$Seed = 7,
	[int]$Beam = 50,
	[int]$Workers = 4,
	[string]$Tag = '',
	[double]$Speed = 20,
	# NOT -WA / -WB: PowerShell has a built-in alias "wa" (WarningAction), and a parameter
	# called WA collides with it -> "The parameter 'WA' cannot be specified because it conflicts
	# with the parameter alias of the same name" and the WHOLE script fails to bind.
	[string]$WeightsA = '',
	[string]$WeightsB = '',
	[string]$Godot = '',
	[string]$Project = '',
	[int]$TimeoutSec = 3600,
	[switch]$KeepParts
)

$ErrorActionPreference = 'Continue'
$script:ExitCode = 0

function Say([string]$msg) { Write-Host $msg }

function Get-Codepoints([int[]]$cps) {
	$sb = New-Object System.Text.StringBuilder
	foreach ($c in $cps) { [void]$sb.Append([char]$c) }
	return $sb.ToString()
}

# scene base name = "dui ju tong ji" (match statistics), weights = "e meng" (nightmare)
$script:SceneBase = Get-Codepoints @(0x5BF9, 0x5C40, 0x7EDF, 0x8BA1)
$script:ScenePath = 'res://RL/stats/' + $script:SceneBase + '.tscn'
$script:Nightmare = 'res://RL/weights/' + (Get-Codepoints @(0x5669, 0x68A6)) + '.json'

function Get-ProjectRoot {
	if ($Project -ne '') { return (Resolve-Path -LiteralPath $Project).Path }
	if (Test-Path (Join-Path (Get-Location).Path 'project.godot')) { return (Get-Location).Path }
	$p = $PSScriptRoot
	if ($p) {
		$up = Split-Path (Split-Path $p -Parent) -Parent
		if (Test-Path (Join-Path $up 'project.godot')) { return $up }
		$up2 = Split-Path $p -Parent
		if (Test-Path (Join-Path $up2 'project.godot')) { return $up2 }
	}
	throw 'cannot locate project root (no project.godot near the script or the working dir)'
}

function Get-GodotExe {
	if ($Godot -ne '') {
		if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot exe not found: $Godot" }
		return $Godot
	}
	$cands = @(
		(Join-Path $env:USERPROFILE 'Desktop\Godot_v4.7.1-stable_win64.exe'),
		(Join-Path $env:USERPROFILE 'Desktop\Godot_v4.7.1-stable_win64_console.exe')
	)
	foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw 'Godot 4.7.1 exe not found: pass -Godot <abs path>'
}

# ---------------------------------------------------------------- merge helpers

function Read-Utf8([string]$path) {
	if (-not (Test-Path -LiteralPath $path)) { return '' }
	return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8Bom([string]$path, [string]$text) {
	$enc = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($path, $text, $enc)
}

# Merge every `<kind>_*.csv` under the parts dir into one CSV: header of the first
# file + all data rows of every file, CRLF, UTF-8 WITH BOM (Excel-friendly).
function Merge-Csv([string]$kind, [string]$partsDir, [string]$outDir, [string]$tag, [string]$stamp) {
	$files = @(Get-ChildItem -LiteralPath $partsDir -Recurse -Filter ($kind + '_*.csv') -File -ErrorAction SilentlyContinue | Sort-Object FullName)
	if ($files.Count -eq 0) { return $null }
	$header = $null
	$rows = New-Object System.Collections.ArrayList
	foreach ($f in $files) {
		$lines = (Read-Utf8 $f.FullName) -split "`r?`n"
		for ($i = 0; $i -lt $lines.Count; $i++) {
			$ln = $lines[$i]
			if ($ln.Trim() -eq '') { continue }
			if ($i -eq 0) { if ($null -eq $header) { $header = $ln }; continue }
			[void]$rows.Add($ln)
		}
	}
	if ($null -eq $header) { return $null }
	$stamped = Join-Path $outDir ($kind + '_' + $tag + '_' + $stamp + '.csv')
	$fixed = Join-Path $outDir ($kind + '.csv')
	$body = $header + "`r`n"
	if ($rows.Count -gt 0) { $body += (($rows -join "`r`n") + "`r`n") }
	Write-Utf8Bom $stamped $body
	Write-Utf8Bom $fixed $body
	return [pscustomobject]@{ Stamped = $stamped; Fixed = $fixed; Rows = $rows.Count; Header = $header }
}

# ---------------------------------------------------------------- main

$root = Get-ProjectRoot
$godotExe = Get-GodotExe
$conc = [Math]::Min([Math]::Max($Workers, 1), 2)          # hard cap = 2 (see header)
$tagName = $Tag
if ($tagName -eq '') { $tagName = $Mode }
$tagName = ($tagName -replace '[^0-9A-Za-z_\-]', '_')
$stamp = Get-Date -Format 'MMdd_HHmmss'
$statsDir = Join-Path $root 'RL\reports\stats'
$partsDir = Join-Path $statsDir ('parts\' + $tagName + '_' + $stamp)
$logDir = Join-Path $partsDir 'logs'
New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$wAArg = ''
if ($WeightsA -ne '') { $wAArg = ' --wA ' + $WeightsA } else { $wAArg = ' --wA ' + $script:Nightmare }
$wBArg = ''
if ($WeightsB -ne '') { $wBArg = ' --wB ' + $WeightsB } else { $wBArg = ' --wB ' + $script:Nightmare }

Say '=== collect_stats ==='
Say ('  project   : ' + $root)
Say ('  godot     : ' + $godotExe)
Say ('  scene     : ' + $script:ScenePath)
Say ('  config    : mode=' + $Mode + ' games=' + $Games + ' seed=' + $Seed + ' beam=' + $Beam + ' speed=' + $Speed + ' workers=' + $Workers + ' -> concurrent=' + $conc)
Say ('  weights   : wA=' + $wAArg.Trim() + '  wB=' + $wBArg.Trim())
Say ('  stats dir : ' + $statsDir)
Say ('  parts dir : ' + $partsDir)

$per = [int][Math]::Ceiling($Games / [double]$conc)
$jobs = New-Object System.Collections.ArrayList
$t0 = Get-Date
for ($w = 0; $w -lt $conc; $w++) {
	$n = [Math]::Min($per, $Games - ($w * $per))
	if ($n -le 0) { continue }
	$s0 = $Seed + ($w * $per)
	$part = Join-Path $partsDir ('w' + $w)
	New-Item -ItemType Directory -Force -Path $part | Out-Null
	$log = Join-Path $logDir ('w' + $w + '.out')
	$sandbox = Join-Path $env:TEMP ('dsh_stats_' + $tagName + '_w' + $w)
	$userArgs = $script:ScenePath + ' -- --mode ' + $Mode + ' --games ' + $n + ' --seed ' + $s0 +
		' --first both --beam ' + $Beam + ' --speed ' + $Speed + $wAArg + $wBArg +
		' --out "' + $part + '" --tag ' + $tagName
	# NOTE the two cmd quirks this line works around (both bit us for real):
	#  1) `cmd /c` STRIPS the first and last quote when the command line starts with a quote,
	#     so the raw `"<exe>" args > "log" 2>&1` becomes garbage ("The filename, directory name,
	#     or volume label syntax is incorrect"). Wrapping the whole thing in one more pair of
	#     quotes (see $innerQ below) is the fix.
	#  2) Start-Process -PassThru's .ExitCode stays EMPTY even after WaitForExit() here, so the
	#     worker's exit code is captured by cmd itself: /v:on + `echo EXITCODE=!ERRORLEVEL!`
	#     appended to the same log file (delayed expansion, otherwise %ERRORLEVEL% is expanded
	#     before the command runs).
	$inner = '"' + $godotExe + '" --headless --path "' + $root + '" ' + $userArgs + ' > "' + $log + '" 2>&1' +
		' & echo EXITCODE=!ERRORLEVEL! >> "' + $log + '"'
	$innerQ = '"' + $inner + '"'
	Say ('  [worker ' + $w + '] seeds ' + $s0 + '..' + ($s0 + $n - 1) + ' (' + $n + ' games)')
	# Per-worker environment: set here, then Start-Process (the child gets a COPY of the
	# environment at spawn), then restore immediately -- so worker 1 never inherits worker 0's
	# sandbox even though both run in parallel.
	$keepAppData = $env:APPDATA
	$keepLocalAppData = $env:LOCALAPPDATA
	$keepMirror = $env:ZB_NO_MIRROR
	if (-not (Test-Path -LiteralPath $sandbox)) { New-Item -ItemType Directory -Force -Path $sandbox | Out-Null }
	$env:APPDATA = $sandbox
	$env:LOCALAPPDATA = $sandbox
	$env:ZB_NO_MIRROR = '1'
	$proc = Start-Process -FilePath (Get-Command cmd).Source -ArgumentList '/v:on', '/c', $innerQ -NoNewWindow -PassThru
	$env:APPDATA = $keepAppData
	$env:LOCALAPPDATA = $keepLocalAppData
	if ($null -ne $keepMirror) { $env:ZB_NO_MIRROR = $keepMirror } else { Remove-Item Env:ZB_NO_MIRROR -ErrorAction SilentlyContinue }
	[void]$jobs.Add([pscustomobject]@{ Index = $w; Proc = $proc; Log = $log; Seed0 = $s0; Games = $n })
}

$results = @()
foreach ($entry in $jobs) {
	$done = $entry.Proc.WaitForExit($TimeoutSec * 1000)     # .NET: returns bool, ms
	$exit = -1
	if ($done) {
		# exit code comes from the log (cmd appended "EXITCODE=<n>"); R|END is the fallback
		# success signal (a Godot run that finished its whole batch always prints it).
		$txt = Read-Utf8 $entry.Log
		$mm = [regex]::Match($txt, 'EXITCODE=(-?\d+)')
		if ($mm.Success) { $exit = [int]$mm.Groups[1].Value }
		elseif ($txt -match 'R\|END') { $exit = 0 }
	} else {
		Say ('  [worker ' + $entry.Index + '] TIMEOUT after ' + $TimeoutSec + 's -> stopping only this worker''s own processes')
		$cmdPid = [int]$entry.Proc.Id
		foreach ($k in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $cmdPid) -ErrorAction SilentlyContinue)) {
			if ($k.Name -like 'Godot*') { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
		}
		Stop-Process -Id $cmdPid -Force -ErrorAction SilentlyContinue
	}
	$results += [pscustomobject]@{ Index = $entry.Index; Exit = $exit; Log = $entry.Log }
	if ($exit -ne 0) { $script:ExitCode = 1 }
}
$wall = ((Get-Date) - $t0).TotalSeconds

Say ''
Say '=== worker results ==='
foreach ($r in $results) {
	$errs = 0
	$parse = 0
	if (Test-Path -LiteralPath $r.Log) {
		$txt = Read-Utf8 $r.Log
		$errs = ([regex]::Matches($txt, 'SCRIPT ERROR')).Count
		$parse = ([regex]::Matches($txt, 'Parse Error')).Count
	}
	Say ('  [worker ' + $r.Index + '] exit=' + $r.Exit + ' script_errors=' + $errs + ' parse_errors=' + $parse + ' log=' + $r.Log)
	if ($errs -gt 0 -or $parse -gt 0) { $script:ExitCode = 1 }
}

$mMerged = Merge-Csv 'matches' $partsDir $statsDir $tagName $stamp
$uMerged = Merge-Csv 'units' $partsDir $statsDir $tagName $stamp
Say ''
Say '=== merged output ==='
if ($mMerged) {
	Say ('  matches : ' + $mMerged.Rows + ' rows -> ' + $mMerged.Stamped)
	Say ('            fixed-name mirror -> ' + $mMerged.Fixed)
} else {
	Say '  matches : NO ROWS (every worker failed?)'
	$script:ExitCode = 1
}
if ($uMerged) {
	Say ('  units   : ' + $uMerged.Rows + ' rows -> ' + $uMerged.Stamped)
	Say ('            fixed-name mirror -> ' + $uMerged.Fixed)
} else {
	Say '  units   : NO ROWS'
	$script:ExitCode = 1
}

# ---------------------------------------------------------------- per-match summary
if ($mMerged) {
	$text = Read-Utf8 $mMerged.Stamped
	$objs = @($text | ConvertFrom-Csv)
	Say ''
	Say '=== per-match summary ==='
	$wp = 0; $we = 0; $wd = 0; $halfSum = 0; $wallSum = 0.0
	$i = 0
	foreach ($o in $objs) {
		$i++
		if ($o.winner -eq 'P') { $wp++ } elseif ($o.winner -eq 'E') { $we++ } else { $wd++ }
		$halfSum += [int]$o.half_rounds
		$wallSum += ([double]$o.wall_ms / 1000.0)
		Say ('  #' + $i.ToString('00') + ' seed=' + $o.seed + ' ' + $o.mode + ' first=' + $o.first_side +
			' winner=' + $o.winner + ' (' + $o.end_reason + ')' +
			' half=' + $o.half_rounds + ' wall=' + ([Math]::Round([double]$o.wall_ms / 1000.0, 1)).ToString() + 's' +
			' dmg P/E=' + $o.P_total_dmg + '/' + $o.E_total_dmg +
			' heal P/E=' + $o.P_total_heal + '/' + $o.E_total_heal +
			' kills P/E=' + $o.P_kills + '/' + $o.E_kills +
			' gold P/E=' + $o.P_gold + '/' + $o.E_gold +
			' alive P/E=' + $o.P_alive_end + '/' + $o.E_alive_end +
			' subs P/E=[' + $o.P_sub_enter_rounds + ']/[' + $o.E_sub_enter_rounds + ']')
		Say ('      P: ' + $o.P_lineup)
		Say ('      E: ' + $o.E_lineup)
	}
	Say ''
	Say ('  totals: games=' + $objs.Count + ' P_win=' + $wp + ' E_win=' + $we + ' draw=' + $wd +
		' avg_half=' + [Math]::Round($halfSum / [double][Math]::Max($objs.Count, 1), 2) +
		' avg_wall=' + [Math]::Round($wallSum / [double][Math]::Max($objs.Count, 1), 1) + 's' +
		' batch_wall=' + [Math]::Round($wall, 1) + 's')
}

if (-not $KeepParts) {
	Say ''
	Say ('  raw per-worker CSVs + logs kept under: ' + $partsDir + '   (delete when done)')
}
Say ''
Say ('exit code = ' + $script:ExitCode)
exit $script:ExitCode
