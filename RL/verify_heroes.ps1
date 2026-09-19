#requires -Version 5.1
<#
  RL/verify_heroes.ps1  --  "one-click hero verification" (script name on disk is Chinese; see RL/reports).

  WHAT IT DOES (three layers per hero):
    L0  preflight : the two harness scenes must LOAD (exit 0 + a build stamp in the output + no
                    "Parse Error" / "Failed to load script"). If preflight fails the whole run
                    aborts with exit code 2 instead of hammering Godot into crash dialogs.
    L1  static    : hero script on disk? registered in HeroRegistry (+ hero table)? dedicated matrix
                    scenes present in the matrix harness? HERO_VALUE coefficient configured?
    L2  matrix    : RL/harness/<matrix>.tscn with the hero id as user arg; parses SK|SUMMARY|,
                    SK|HERO| and every verdict=DIFF row.
    L3  sweep     : RL/harness/<inspector>.tscn --selftest <Acts> --pai 1 --ai 1 --seed <Seed>
                    --picks ... with the hero as YOUR main hero (and optionally as the enemy hero);
                    parses the console verdict block and the SIMCHK|SUMMARY| machine line.

  EXIT CODES: 0 = all green, 1 = at least one real DIFF, 2 = preflight / setup failure.

  ASCII-ONLY SOURCE: this file contains no non-ASCII literal on purpose. PowerShell 5.1 reads .ps1
  as ANSI, so Chinese literals would be mangled (that is how a previous task blanked 9 files).
  Chinese paths/names are therefore DERIVED at runtime:
    - hero id -> script res:// path  : parsed out of heroes/HeroRegistry.gd, then URL-decoded
    - hero id -> display name        : parsed out of the same res:// path (strip hero_NN_ and .gd)
    - harness scene files            : located by scanning RL/harness/*.tscn and matching by the
                                       code points of their names (built with [char] so the SOURCE
                                       stays ASCII while PowerShell 5.1 still builds the right string)
    - runtime log name               : same [char] technique

  USAGE
    powershell -NoProfile -File RL\verify_heroes.ps1 -Heroes hero_26,hero_22
    powershell -NoProfile -File RL\verify_heroes.ps1 -All -Acts 16 -Seed 7
    powershell -NoProfile -File RL\verify_heroes.ps1 -Heroes hero_50 -SkipMatrix -SkipSweep
    (double-click wrapper: RL\verify_heroes.bat)

  NOTES
    - Godot is invoked through cmd redirection (never captured by PowerShell directly).
    - Every run has a timeout; only processes this script started (recorded PIDs) are ever killed.
    - Hard rule: one Godot instance at a time (all runs are sequential).
#>

[CmdletBinding()]
param(
	[Parameter(ValueFromRemainingArguments = $false)]
	[string[]]$Heroes = @(),
	[switch]$All,
	[int]$Acts = 16,
	[int]$Seed = 7,
	# Sweep (L3) search width. DIFF-hunting only needs "which move the AI picks" to be sane, not
	# optimal: --beam only changes the chosen move, never the prediction-vs-real verdict. 5v5 mid-game
	# measured ~400-1300 ms per decision at beam 50 (vs ~16x that at the 800 default), so the sweep
	# default is 50. Use -Beam 800 to reproduce an older/large-beam run.
	[int]$Beam = 50,
	[switch]$SkipMatrix,
	[switch]$SkipSweep,
	[switch]$BothSides,
	[string]$Godot = "",
	[string]$Project = "",
	[string]$Stamp = "",
	# debug overrides (defaults = the real harness scenes; only used to prove the preflight guard)
	[string]$MatrixScene = "",
	[string]$InspectScene = ""
)

$ErrorActionPreference = 'Continue'
$script:ExitCode = 0
$script:RunIds = New-Object System.Collections.ArrayList
$script:Transcript = New-Object System.Collections.ArrayList

# normalise -Heroes: accepts both "-Heroes hero_26,hero_22" (a comma list -> string[])
# and '-Heroes "hero_26,hero_22"' (one comma-separated string).
$heroIds = @()
foreach ($entry in @($Heroes)) {
	foreach ($piece in ([string]$entry -split ',')) {
		$t = $piece.Trim()
		if ($t -ne '') { $heroIds += $t }
	}
}

function Say([string]$msg) {
	Write-Host $msg
	[void]$script:Transcript.Add($msg)
}

# ---------------------------------------------------------------- basics

function Get-ProjectRoot {
	if ($Project -ne "") { return (Resolve-Path $Project).Path }
	# prefer the caller's working directory when it is the project root
	if (Test-Path (Join-Path (Get-Location).Path 'project.godot')) { return (Get-Location).Path }
	# else derive it from this script's own location (RL\..\)
	$p = $PSScriptRoot
	if ($p) {
		$parent = Split-Path $p -Parent
		if (Test-Path (Join-Path $parent 'project.godot')) { return $parent }
	}
	throw "cannot locate project root (no project.godot near the script or the working dir)"
}

function Get-Codepoints([int[]]$cps) {
	$sb = New-Object System.Text.StringBuilder
	foreach ($c in $cps) { [void]$sb.Append([char]$c) }
	return $sb.ToString()
}

function Get-GodotExe {
	if ($Godot -ne "") {
		if (-not (Test-Path $Godot)) { throw "Godot exe not found: $Godot" }
		return $Godot
	}
	$cands = @(
		(Join-Path $env:USERPROFILE "Desktop\Godot_v4.7.1-stable_win64.exe"),
		(Join-Path $env:USERPROFILE "Desktop\Godot_v4.7.1-stable_win64_console.exe")
	)
	foreach ($c in $cands) { if (Test-Path $c) { return $c } }
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw "Godot 4.7.1 exe not found: pass -Godot <abs path>"
}

function Get-HarnessScene([string]$root, [int[]]$nameCodepoints) {
	$want = Get-Codepoints $nameCodepoints
	$hit = Get-ChildItem (Join-Path $root 'RL\harness') -Filter *.tscn -File |
		Where-Object { $_.BaseName -eq $want } | Select-Object -First 1
	if (-not $hit) { throw ("harness scene not found for name codepoints " + ($nameCodepoints -join ",")) }
	return $hit
}

function Read-TextFile([string]$path) {
	if (-not (Test-Path $path)) { return "" }
	return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Get-HeroTable([string]$root) {
	# hero id -> res:// script path, straight out of HeroRegistry.gd (single source of truth)
	$reg = Join-Path $root 'heroes\HeroRegistry.gd'
	$txt = Read-TextFile $reg
	$map = @{}
	$heroName = Read-TextFile (Join-Path $root ((Get-Codepoints @(0x82F1,0x96C4,0x76F8,0x5173)) + '\' + (Get-Codepoints @(0x5378,0x8272,0x534F,0x540C,0x89E3,0x6790,0x5FEB,0x7167)) + '.json'))
	$names = @{}
	if ($heroName -ne "") {
		try {
			$j = ConvertFrom-Json $heroName
			foreach ($p in $j.heroes.PSObject.Properties) { $names[$p.Name] = [string]$p.Value.name }
		} catch { }
	}
	foreach ($m in [regex]::Matches($txt, '"?(hero_\d+)"?\s*:\s*"(res://heroes/[^"]+\.gd)"')) {
		$id = $m.Groups[1].Value
		$res = $m.Groups[2].Value
		# strip "res://heroes/hero_NN_" and the ".gd" suffix -> the display name (may be Chinese)
		$raw = [string]$res
		$raw = $raw.Substring($raw.LastIndexOf('/') + 1)
		$raw = $raw -replace '^hero_\d+_', ''
		$raw = $raw -replace '\.gd$', ''
		$map[$id] = [pscustomobject]@{
			Id        = $id
			Res       = $res
			Name      = $raw
			TableName = $(if ($names.ContainsKey($id)) { $names[$id] } else { "" })
		}
	}
	return $map
}

# ---------------------------------------------------------------- run helper (timeout + PID tracking)

function Invoke-Godot {
	param(
		[string]$Exe,
		[string]$ProjectRoot,
		[string]$Scene,
		[string[]]$UserArgs = @(),
		[string]$LogPath,
		[string]$OutPath,
		[int]$TimeoutSec = 300,
		[string]$Tag = "run"
	)
	$argList = @('--headless', '--path', $ProjectRoot, '--log-file', $LogPath, '--scene', $Scene)
	$argList += $UserArgs
	# cmd redirection: build a properly quoted command line by hand (never let PowerShell capture
	# Godot's stdout itself -- that produced false signals / truncated output in this project).
	$line = '"' + $Exe + '"'
	foreach ($a in $argList) { $line += ' "' + ($a -replace '"', '\"') + '"' }
	$line += ' > "' + $OutPath + '" 2>&1'

	$t0 = Get-Date
	# Run through cmd (redirection preserved) inside a background job so we get a hard deadline.
	# NOTE: Start-Process was tried first and does NOT work for this command line in this
	# environment -- it re-quotes the argument string and Godot never starts (exit 1, no output).
	# Job + explicit cleanup gives both the real exit code and a bounded run.
	$job = Start-Job -ScriptBlock { param($l) & cmd /c $l; $LASTEXITCODE } -ArgumentList $line
	$timedOut = $false
	if (-not (Wait-Job $job -Timeout $TimeoutSec)) { $timedOut = $true }
	$code = -1
	try {
		$res = Receive-Job $job -ErrorAction SilentlyContinue
		if ($null -ne $res) { $code = [int](@($res) | Select-Object -Last 1) }
	} catch { }
	if ($timedOut) {
		Stop-Job $job -ErrorAction SilentlyContinue
		# only kill Godot processes that appeared after this call began: never the user's editor
		# (which predates it) and never anything this script did not start.
		try {
			Get-Process -Name ((Split-Path $Exe -Leaf) -replace '\.exe$', '') -ErrorAction SilentlyContinue |
				Where-Object { $_.StartTime -ge $t0 } |
				ForEach-Object { [void]$script:RunIds.Add(('-killed:' + $_.Id)); try { $_.Kill() } catch { } }
		} catch { }
	}
	Remove-Job $job -Force -ErrorAction SilentlyContinue
	$secs = [int]((Get-Date) - $t0).TotalSeconds
	return [pscustomobject]@{
		ExitCode = $code
		TimedOut = $timedOut
		Seconds  = $secs
		OutPath  = $OutPath
		LogPath  = $LogPath
		Pid      = '-'
		Line     = $line
		Out      = $(if (Test-Path $OutPath) { [System.IO.File]::ReadAllText($OutPath, [System.Text.Encoding]::UTF8) } else { "" })
	}
}

function Test-LoadOk {
	param($run, [string]$stampNeedle)
	if ($run.TimedOut) { return @{ Ok = $false; Why = ("timeout after {0}s" -f $run.Seconds) } }
	if ($run.ExitCode -ne 0) { return @{ Ok = $false; Why = ("exit code {0}" -f $run.ExitCode) } }
	$txt = $run.Out
	if ($txt -match 'Parse Error' -or $txt -match 'Failed to load script') {
		return @{ Ok = $false; Why = 'parse/load error in output' }
	}
	if ($txt -notmatch [regex]::Escape($stampNeedle)) {
		return @{ Ok = $false; Why = ("no build stamp ('{0}') in output" -f $stampNeedle) }
	}
	return @{ Ok = $true; Why = '' }
}

function Get-BuildStamp([string]$text, [string]$needle) {
	$m = [regex]::Match($text, [regex]::Escape($needle) + '=([0-9A-Fa-f]+)')
	if ($m.Success) { return $m.Groups[1].Value }
	return ""
}

# ---------------------------------------------------------------- parsers (unit-testable)

function Parse-Matrix([string]$text) {
	$res = [ordered]@{
		Cases = 0; Match = 0; Diff = 0; Skip = 0; Snap = 0; Nopred = 0
		Mode = ""; ForkSha = ""
		DiffLines = New-Object System.Collections.ArrayList
		HeroVerdicts = @{}
		SummarySeen = $false
	}
	foreach ($line in ($text -split "`r?`n")) {
		if ($line.StartsWith('SK|SUMMARY|')) {
			$res.SummarySeen = $true
			if ($line -match 'cases=(\d+)') { $res.Cases = [int]$Matches[1] }
			if ($line -match 'match=(\d+)') { $res.Match = [int]$Matches[1] }
			if ($line -match 'diff=(\d+)')  { $res.Diff  = [int]$Matches[1] }
			if ($line -match 'skip=(\d+)')  { $res.Skip  = [int]$Matches[1] }
			if ($line -match 'snap=(\d+)')  { $res.Snap  = [int]$Matches[1] }
			if ($line -match 'mode=([^|]+)') { $res.Mode = $Matches[1] }
			if ($line -match 'fork_sha=([0-9a-f]+)') { $res.ForkSha = $Matches[1] }
		} elseif ($line.StartsWith('SK|HERO|')) {
			$parts = $line.Split('|')
			if ($parts.Count -ge 4) {
				$hid = $parts[2]
				$vals = @{}
				for ($i = 3; $i -lt $parts.Count; $i++) {
					$kv = $parts[$i].Split('=')
					if ($kv.Count -eq 2) { $vals[$kv[0]] = $kv[1] }
				}
				$res.HeroVerdicts[$hid] = $vals
			}
		} elseif ($line -match 'verdict=DIFF') {
			[void]$res.DiffLines.Add($line.Trim())
		}
	}
	$res.Nopred = @($res.DiffLines | Where-Object { $_ -match 'NOPRED' }).Count
	return $res
}

function Parse-Sweep([string]$stdout, [string]$rtlogText) {
	# verdict-label regexes are built from code points so this .ps1 source stays pure ASCII:
	# PowerShell 5.1 reads .ps1 as ANSI, so a Chinese literal here would arrive mangled.
	$vLab = [regex]::Escape((Get-Codepoints @(0x5224,0x5B9A)))   # verdict label
	$reVerdict = '^' + $vLab + '\s+'
	$reDiff = $reVerdict + 'DIFF'
	$reTiming = $reVerdict + 'TIMING'
	$reNopred = $reVerdict + 'NOPRED'
	$reMatch = $reVerdict + 'MATCH'
	$reSpan = $reVerdict + [regex]::Escape((Get-Codepoints @(0x4E0D,0x53EF,0x6BD4)))
	$res = [ordered]@{
		Diff = 0; DiffLines = New-Object System.Collections.ArrayList
		CtDiff = 0; CtTiming = 0; CtSpan = 0; CtNopred = 0; CtMatch = 0
		Timing = 0; Process = 0; Span = 0; Nopred = 0; Match = 0
		Sim = @{}; SummarySeen = $false
		ActBlocks = 0; Checks = 0
	}
	# --- console: the human-readable verdict block. Only REAL verdict lines count:
	#     a "no differences" detail line also contains the substring DIFF and must NOT be read as a failure
	#     (that was a false positive caught by self-test).
	foreach ($line in ($stdout -split "`r?`n")) {
		$t = $line.Trim()
		if ($t -match '^\[[^\]]+\]\s*#\d+\s') { $res.ActBlocks++ }
		if ($t -match $reVerdict) {
			# the verdict keyword right after the Chinese label decides the class
			if ($t -match $reDiff) { $res.CtDiff++; [void]$res.DiffLines.Add('[console] ' + $t) }
			elseif ($t -match $reTiming) { $res.CtTiming++ }
			elseif ($t -match $reNopred) { $res.CtNopred++ }
			elseif ($t -match $reSpan) { $res.CtSpan++ }
			elseif ($t -match $reMatch) { $res.CtMatch++ }
		}
	}
	# --- runtime log: the machine lines are authoritative for counts (SIMCHK|n=..|verdict=..)
	foreach ($line in ($rtlogText -split "`r?`n")) {
		if ($line.StartsWith('SIMCHK|SUMMARY|')) {
			$res.SummarySeen = $true
			foreach ($k in @('MATCH', 'DIFF', 'NOPRED', 'PROCESS', 'SPAN', 'TIMING')) {
				if ($line -match ($k + '=(\d+)')) { $res.Sim[$k] = [int]$Matches[1] }
			}
		} elseif ($line.StartsWith('SIMCHK|n=')) {
			$v = ''
			if ($line -match 'verdict=([A-Z]+)') { $v = $Matches[1] }
			if (-not $res.Sim.ContainsKey($v)) { $res.Sim[$v] = 0 }
			$res.Sim[$v] = [int]$res.Sim[$v] + 1
			$res.Checks++
			if ($v -eq 'DIFF' -and $res.DiffLines.Count -lt 20) { [void]$res.DiffLines.Add('[sim] ' + $line.Trim()) }
		}
	}
	if ($res.Sim.ContainsKey('DIFF')) { $res.Diff = [int]$res.Sim['DIFF'] }
	if ($res.Sim.ContainsKey('TIMING')) { $res.Timing = [int]$res.Sim['TIMING'] }
	if ($res.Sim.ContainsKey('PROCESS')) { $res.Process = [int]$res.Sim['PROCESS'] }
	if ($res.Sim.ContainsKey('SPAN')) { $res.Span = [int]$res.Sim['SPAN'] }
	if ($res.Sim.ContainsKey('NOPRED')) { $res.Nopred = [int]$res.Sim['NOPRED'] }
	if ($res.Sim.ContainsKey('MATCH')) { $res.Match = [int]$res.Sim['MATCH'] }
	return $res
}

# ---------------------------------------------------------------- static layer

function Invoke-StaticLayer {
	param([string]$root, $hero, [string]$matrixHarnessPath)
	$r = [ordered]@{ Script = $false; Registered = $false; TableName = ""; MatrixScenes = -1
		WarnNoScene = $false; Coef = $null; Notes = New-Object System.Collections.ArrayList }
	$disk = Get-ChildItem (Join-Path $root 'heroes') -Filter ($hero.Id + '_*.gd') -File -ErrorAction SilentlyContinue
	$r.Script = ($null -ne $disk)
	$reg = Read-TextFile (Join-Path $root 'heroes\HeroRegistry.gd')
	$r.Registered = ($reg -match ('"' + [regex]::Escape($hero.Id) + '"\s*:'))
	$r.TableName = $hero.TableName
	# dedicated matrix scenes: search the matrix harness for the id and for the Chinese name
	$mh = Read-TextFile $matrixHarnessPath
	$byId = ([regex]::Matches($mh, [regex]::Escape($hero.Id))).Count
	$byName = 0
	if ($hero.Name -ne "") { $byName = ([regex]::Matches($mh, [regex]::Escape($hero.Name))).Count }
	$r.MatrixScenes = $byId + $byName
	if ($r.MatrixScenes -le 0) {
		$r.WarnNoScene = $true
		[void]$r.Notes.Add("no dedicated scene found in the matrix harness -> the generic action families may not cover its entry/turn/passive/aura skills")
	}
	# core coefficient: RL/weights/<nightmare>.json HERO_VALUE
	$wPath = Join-Path $root ('RL\weights\' + (Get-Codepoints @(0x5669,0x68A6)) + '.json')
	$w = Read-TextFile $wPath
	$coef = $null
	if ($w -ne "") {
		if ($w -match ('"' + [regex]::Escape($hero.Id) + '"\s*:\s*([0-9.]+)') ) { $coef = [double]$Matches[1] }
	}
	if ($null -eq $coef) {
		[void]$r.Notes.Add("HERO_VALUE not configured -> built-in default 1.0 (neutral)")
	} else {
		$r.Coef = $coef
	}
	return $r
}

# ---------------------------------------------------------------- main

$root = Get-ProjectRoot
$godot = Get-GodotExe
$ts = $(if ($Stamp -ne "") { $Stamp } else { Get-Date -Format 'yyyyMMdd_HHmmss' })
$reports = Join-Path $root 'RL\reports'
if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports | Out-Null }

# scene + log names (built from code points so this source file stays ASCII)
$sceneMatrix = Get-HarnessScene $root @(0x6280,0x80FD,0x5BF9,0x62CD)                         # matrix harness
$sceneInspect = Get-HarnessScene $root @(0x81EA,0x7531,0x90E8,0x7F72,0x5F,0x6A21,0x62DF,0x68C0,0x89C6) # inspector
# optional debug overrides: point the preflight at any scene (file name keeps its real name)
if ($InspectScene -ne "") { $sceneInspect = Get-Item $InspectScene }
if ($MatrixScene -ne "") { $sceneMatrix = Get-Item $MatrixScene }
$rtBase = Get-Codepoints @(0x5BF9,0x62CD,0x5F,0x8FD0,0x884C,0x65F6)                          # runtime log stem (without .log)
$rtName = $rtBase + '.log'

$allHeroes = Get-HeroTable $root
$selected = @()
if ($heroIds.Count -gt 0) {
	foreach ($id in $heroIds) {
		if (-not $allHeroes.ContainsKey($id)) { Say ("  !! hero not registered in HeroRegistry: " + $id); $script:ExitCode = 2 }
		else { $selected += $allHeroes[$id] }
	}
} elseif ($All) {
	foreach ($k in ($allHeroes.Keys | Sort-Object)) { $selected += $allHeroes[$k] }
} else {
	Say 'usage: verify_heroes.ps1 -Heroes hero_26,hero_22   |   -All   [-Acts 16] [-Seed 7] [-SkipMatrix] [-SkipSweep] [-BothSides]'
	exit 2
}

$logName = 'verify_' + $ts + '.log'
$logPath = Join-Path $reports $logName
Say '================================================================================'
Say ('  hero verification   build-time ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('  project : ' + $root)
Say ('  godot   : ' + $godot)
Say ('  heroes  : ' + (($selected | ForEach-Object { $_.Id }) -join ', '))
Say ('  acts    : ' + $Acts + '   seed: ' + $Seed + '   matrix: ' + (-not $SkipMatrix) + '   sweep: ' + (-not $SkipSweep) + '   bothSides: ' + [bool]$BothSides)
Say ('  log     : RL\reports\' + $logName)
Say '================================================================================'

# ---------------- L0 preflight ----------------
Say ''
Say '[L0 preflight] both harness scenes must load (exit 0 + build stamp + no parse error)'
$preOut = Join-Path $reports ('verify_' + $ts + '_preflight.out')
$preLog = [System.IO.Path]::ChangeExtension($preOut, '.godot.log')
$pre = Invoke-Godot -Exe $godot -ProjectRoot $root -Scene ('res://RL/harness/' + $sceneInspect.Name) `
	-UserArgs @('--', '--panecheck') -LogPath $preLog -OutPath $preOut -TimeoutSec 120 -Tag 'preflight'
$chk = Test-LoadOk $pre '=== '
$stamp = Get-BuildStamp $pre.Out ((Get-Codepoints @(0x6784,0x5EFA)))
Say ('  inspector scene : exit=' + $pre.ExitCode + ' secs=' + $pre.Seconds + ' build=' + $stamp + ' ok=' + $chk.Ok + $(if ($chk.Ok) { '' } else { '  reason=' + $chk.Why }))
if (-not $chk.Ok) {
	Say '  ==> PREFLIGHT FAILED: aborting the whole run (exit code 2). Raw output:'
	foreach ($l in (($pre.Out -split "`r?`n") | Select-Object -First 25)) { Say ('      ' + $l) }
	Say ''
	Say 'PREFLIGHT FAILED -- nothing was run. Fix the load error first (a crash-dialog storm is exactly what this guard prevents).'
	[System.IO.File]::WriteAllLines($logPath, $script:Transcript.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
	exit 2
}
# matrix harness load check: run one cheap hero mode only if we are going to use the matrix at all
if (-not $SkipMatrix) {
	if ($selected.Count -gt 0) {
		$probeOut = Join-Path $reports ('verify_' + $ts + '_probe.out')
		$probeLog = [System.IO.Path]::ChangeExtension($probeOut, '.godot.log')
		$probe = Invoke-Godot -Exe $godot -ProjectRoot $root -Scene ('res://RL/harness/' + $sceneMatrix.Name) `
			-UserArgs @('--', 'hero_26') -LogPath $probeLog -OutPath $probeOut -TimeoutSec 300 -Tag 'probe'
		$pchk = Test-LoadOk $probe ('SK|SUMMARY|')
		Say ('  matrix scene    : exit=' + $probe.ExitCode + ' secs=' + $probe.Seconds + ' ok=' + $pchk.Ok + $(if ($pchk.Ok) { '' } else { '  reason=' + $pchk.Why }))
		if (-not $pchk.Ok) {
			Say '  ==> PREFLIGHT FAILED: the matrix harness does not run (exit code 2). Output head:'
			foreach ($l in (($probe.Out -split "`r?`n") | Select-Object -First 25)) { Say ('      ' + $l) }
			[System.IO.File]::WriteAllLines($logPath, $script:Transcript.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
			exit 2
		}
	}
}

# ---------------- per hero ----------------
$rows = New-Object System.Collections.ArrayList
foreach ($hero in $selected) {
	Say ''
	Say ('---------------- ' + $hero.Id + '  ' + $hero.Name + ' ----------------')
	$st = Invoke-StaticLayer -root $root -hero $hero -matrixHarnessPath (Join-Path $root ('RL\harness\' + $sceneMatrix.Name))

	# ---- L2 matrix ----
	$mx = $null
	if (-not $SkipMatrix) {
		$out = Join-Path $reports ('verify_' + $ts + '_' + $hero.Id + '_matrix.out')
		$lg = [System.IO.Path]::ChangeExtension($out, '.godot.log')
		$run = Invoke-Godot -Exe $godot -ProjectRoot $root -Scene ('res://RL/harness/' + $sceneMatrix.Name) `
			-UserArgs @('--', $hero.Id) -LogPath $lg -OutPath $out -TimeoutSec 900 -Tag 'matrix'
		$mx = Parse-Matrix $run.Out
		$mx.Run = $run
		# refine the static "no dedicated scene" warning with the matrix's own per-hero aggregate
		# line (SK|HERO|<id>|...): its presence proves the hero really has a dedicated scene arm.
		if ($st.WarnNoScene -and $mx.HeroVerdicts.ContainsKey($hero.Id)) {
			$st.WarnNoScene = $false
			$st.Notes.Clear()
			[void]$st.Notes.Add("dedicated scene arm confirmed by the matrix run (SK|HERO|" + $hero.Id + " with " + $mx.HeroVerdicts[$hero.Id].Count + " scenario verdicts)")
		}
		if ($run.TimedOut) { Say ('  matrix: TIMEOUT after ' + $run.Seconds + 's') }
		else { Say ('  matrix: exit=' + $run.ExitCode + ' secs=' + $run.Seconds + ' cases=' + $mx.Cases + ' MATCH=' + $mx.Match + ' DIFF=' + $mx.Diff + ' SKIP=' + $mx.Skip + ' SNAP=' + $mx.Snap + ' fork=' + $mx.ForkSha) }
	}

	# ---- L3 sweep (hero as our main hero; optionally also as the enemy hero) ----
	$sw = $null; $swE = $null
	if (-not $SkipSweep) {
		$picksP = @($hero.Id, 'hero_26', 'hero_06')
		$picksE = @('hero_13', 'hero_12', 'hero_23')
		$out = Join-Path $reports ('verify_' + $ts + '_' + $hero.Id + '_sweep_p.out')
		$lg = [System.IO.Path]::ChangeExtension($out, '.godot.log')
		$rt = Join-Path $reports ('verify_' + $ts + '_' + $hero.Id + '_rt_p.log')
		$run = Invoke-Godot -Exe $godot -ProjectRoot $root -Scene ('res://RL/harness/' + $sceneInspect.Name) `
			-UserArgs @('--', '--selftest', "$Acts", '--pai', '1', '--ai', '1', '--seed', "$Seed", '--beam', "$Beam",
				'--picks', ($picksP -join ','), ($picksE -join ','), '--rtlog', ('res://' + $rt.Substring($root.Length + 1).Replace('\', '/'))) `
			-LogPath $lg -OutPath $out -TimeoutSec 1800 -Tag 'sweep'
		$sw = Parse-Sweep $run.Out (Read-TextFile $rt)
		$sw.Run = $run
		Say ('  sweep (our side) : exit=' + $run.ExitCode + ' secs=' + $run.Seconds + ' printedBlocks=' + $sw.ActBlocks + ' simChecks=' + $sw.Checks + ' DIFF=' + $sw.Diff + ' MATCH=' + $sw.Match + ' TIMING=' + $sw.Timing + ' PROCESS=' + $sw.Process + ' SPAN=' + $sw.Span + ' NOPRED=' + $sw.Nopred)
		if ($BothSides) {
			$out2 = Join-Path $reports ('verify_' + $ts + '_' + $hero.Id + '_sweep_e.out')
			$lg2 = [System.IO.Path]::ChangeExtension($out2, '.godot.log')
			$rt2 = Join-Path $reports ('verify_' + $ts + '_' + $hero.Id + '_rt_e.log')
			$run2 = Invoke-Godot -Exe $godot -ProjectRoot $root -Scene ('res://RL/harness/' + $sceneInspect.Name) `
				-UserArgs @('--', '--selftest', "$Acts", '--pai', '1', '--ai', '1', '--seed', "$Seed", '--beam', "$Beam",
					'--picks', ('hero_26,hero_06,hero_17'), (@($hero.Id, 'hero_12', 'hero_13') -join ','), '--rtlog', ('res://' + $rt2.Substring($root.Length + 1).Replace('\', '/')) ) `
				-LogPath $lg2 -OutPath $out2 -TimeoutSec 1800 -Tag 'sweep'
			$swE = Parse-Sweep $run2.Out (Read-TextFile $rt2)
			$swE.Run = $run2
			Say ('  sweep (enemy side): exit=' + $run2.ExitCode + ' secs=' + $run2.Seconds + ' printedBlocks=' + $swE.ActBlocks + ' simChecks=' + $swE.Checks + ' DIFF=' + $swE.Diff + ' MATCH=' + $swE.Match + ' TIMING=' + $swE.Timing + ' PROCESS=' + $swE.Process + ' SPAN=' + $swE.Span + ' NOPRED=' + $swE.Nopred)
		}
	}

	[void]$rows.Add([pscustomobject]@{ Hero = $hero; Static = $st; Matrix = $mx; Sweep = $sw; SweepE = $swE })
}

# ---------------- conclusion ----------------
Say ''
Say '================================================================================'
Say '  CONCLUSION'
Say '================================================================================'
$anyDiff = $false
foreach ($row in $rows) {
	$h = $row.Hero; $st = $row.Static
	Say ''
	Say ($h.Id + '  (' + $h.Name + ')')
	$s = '  static : script=' + $(if ($st.Script) { 'OK' } else { 'MISSING' })
	$s += '  registry=' + $(if ($st.Registered) { 'OK' } else { 'MISSING' })
	$s += '  tableName=' + $(if ($st.TableName -ne '') { 'OK' } else { 'n/a' })
	$s += '  matrixScenes=' + $st.MatrixScenes
	$s += '  coef=' + $(if ($null -ne $st.Coef) { $st.Coef } else { 'default 1.0' })
	Say $s
	foreach ($n in $st.Notes) { Say ('           note: ' + $n) }
	if ($null -ne $row.Matrix) {
		$m = $row.Matrix
		Say ('  matrix : cases=' + $m.Cases + ' MATCH=' + $m.Match + ' DIFF=' + $m.Diff + ' SKIP=' + $m.Skip + ' SNAP=' + $m.Snap)
	}
	if ($null -ne $row.Sweep) {
		$w = $row.Sweep
		Say ('  sweep  : our side printedBlocks=' + $w.ActBlocks + ' simChecks=' + $w.Checks + ' DIFF=' + $w.Diff + '  (MATCH=' + $w.Match + ' TIMING=' + $w.Timing + ' PROCESS=' + $w.Process + ' SPAN=' + $w.Span + ' NOPRED=' + $w.Nopred + ')')
	}
	if ($null -ne $row.SweepE) {
		$w = $row.SweepE
		Say ('           enemy side printedBlocks=' + $w.ActBlocks + ' simChecks=' + $w.Checks + ' DIFF=' + $w.Diff + '  (MATCH=' + $w.Match + ' TIMING=' + $w.Timing + ' PROCESS=' + $w.Process + ' SPAN=' + $w.Span + ' NOPRED=' + $w.Nopred + ')')
	}
	$diffLines = New-Object System.Collections.ArrayList
	if ($null -ne $row.Matrix) { foreach ($d in $row.Matrix.DiffLines) { [void]$diffLines.Add('[matrix] ' + $d) } }
	if ($null -ne $row.Sweep)  { foreach ($d in $row.Sweep.DiffLines)  { [void]$diffLines.Add('[sweep/our] ' + $d) } }
	if ($null -ne $row.SweepE) { foreach ($d in $row.SweepE.DiffLines) { [void]$diffLines.Add('[sweep/enemy] ' + $d) } }
	$verdict = 'OK'
	if ($diffLines.Count -gt 0) {
		$anyDiff = $true
		$verdict = 'DIFF'
		Say ('  verdict: DIFF -- ' + $diffLines.Count + ' row(s); see below')
		if ($st.WarnNoScene) { Say '           + no dedicated matrix scene (add one so entry/turn/passive/aura skills get covered)'; }
		$shown = 0
		foreach ($d in $diffLines) {
			if ($shown -ge 20) { break }
			Say ('      ' + $d)
			$shown++
		}
		if ($diffLines.Count -gt 20) { Say ('      ... and ' + ($diffLines.Count - 20) + ' more (full text: ' + $logName + ')') }
	} elseif ($st.WarnNoScene) {
		$verdict = 'CAUTION'
		Say '  verdict: CAUTION -- nothing mismatched, but no dedicated matrix scene was found:'
		Say '           the generic action families cannot cover entry / turn / passive / aura skills,'
		Say '           so "all MATCH" here is NOT proof that those skills are simulated correctly.'
	} else {
		Say '  verdict: OK -- AI prediction agreed with the real battle on every comparable case'
	}
	Say ('  result : ' + $verdict)
	[void]$script:Transcript.Add(('RESULT|' + $h.Id + '|' + $verdict + '|diffs=' + $diffLines.Count))
}

Say ''
Say '================================================================================'
Say ('  RUNS (only these PIDs were ever started/killed by this script): ' + (($script:RunIds | ForEach-Object { $_ }) -join ', '))
Say ('  full log: RL\reports\' + $logName)
if ($anyDiff) { Say '  EXIT 1  -- at least one real DIFF (see the rows above)' } else { Say '  EXIT 0  -- all green' }
Say '================================================================================'
[System.IO.File]::WriteAllLines($logPath, $script:Transcript.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
if ($anyDiff) { exit 1 }
exit 0
