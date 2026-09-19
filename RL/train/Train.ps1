<#
  Train.ps1 -- RL weight-training pipeline entry point (PURE ASCII).

  Tasks:
    selftest   : verify the Wilson / normal-quantile / stats implementation
    coverage   : print lineup-pool coverage and train-vs-holdout overlap checks, write coverage.md
    gen        : materialise RL/weights/cand_*.json for the requested configs
    run        : run the requested configs on a seed set (resume-aware), write results + markdown
    status     : show what has already been measured for a run
    estimate   : measured seconds/game and projected wall clock for the phases
    compare    : paired sensitivity table (treatment vs control on the same seed tuples)

  Always invoke with -Command, never -File: with -File, "e,p" arrives as "e p".
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task selftest"
    ... -Task gen -Run pilot -Configs base,p1_ff_lo
    ... -Task run -Run pilot -Configs base,p1_ff_lo -SeedSet train -MaxSeeds 2 -Firsts e -Asides e,p
    ... -Task compare -Run sens -Configs base,p1_ff_lo,p1_ff_hi
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('selftest', 'coverage', 'gen', 'run', 'status', 'estimate', 'compare', 'repair', 'equiv', 'league')][string]$Task,
    [string]$Run = 'scratch',
    [string[]]$Configs = @(),
    [ValidateSet('train', 'holdout')][string]$SeedSet = 'train',
    [int]$MaxSeeds = 0,
    [int]$SeedStart = 0,
    [int]$SeedBlock = 0,
    [string[]]$Firsts = @(),
    [string[]]$Asides = @(),
    [switch]$FixedDecks,
    [switch]$Force,
    [switch]$IKnowThisIsHoldout,
    # Global parallel deadline = TimeoutSec*2 + 300s. Reaching it means cells were NEVER STARTED, so it
    # is now a hard failure (see Invoke-ParallelCells); the default was raised because a worker takes one
    # whole (config, seed, first) cell - 2 games, ~90-300s each - and a big sweep packs 50+ cells per
    # worker. A 900s default gave a 2100s budget and silently truncated real runs.
    [int]$TimeoutSec = 3600,
    [int]$MaxWallSec = 0,
    [string]$Spec = '',
    [string]$OutMd = '',
    [int]$Workers = 1,
    [switch]$AllowHashChange
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RlTrain.ps1')

# Any unexpected error should say exactly where it happened (PS 5.1 otherwise hides the line).
trap {
    Write-Host ('FATAL: ' + $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message)
    Write-Host ('  at ' + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber)
    Write-Host ('  stmt: ' + ([string]$_.InvocationInfo.Line).Trim())
    Write-Host ('  stack: ' + $_.ScriptStackTrace)
    exit 9
}

Assert-ScriptEncoding -Paths @((Join-Path $PSScriptRoot 'Train.ps1'), (Join-Path $PSScriptRoot 'RlTrain.ps1')) -Repair
if (-not $Spec) { $Spec = Join-Path $PSScriptRoot 'train_spec.json' }
$specObj = Read-TrainSpec $Spec
if ($Firsts -and $Firsts.Count -gt 0) {
    $specObj.measurement.firsts = @($Firsts | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($v in $specObj.measurement.firsts) {
        if (@('p', 'e', 'both') -notcontains $v) {
            throw ('bad -Firsts value [' + $v + ']: allowed p / e / both. NOTE: with "powershell -File", "e,p" arrives as "e p"; pass it as "e","p" via -Command, or as a single "both".')
        }
    }
}
if ($Asides -and $Asides.Count -gt 0) {
    $specObj.measurement.asides = @($Asides | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($v in $specObj.measurement.asides) {
        if (@('p', 'e') -notcontains $v) {
            throw ('bad -Asides value [' + $v + ']: allowed p / e. NOTE: with "powershell -File", "e,p" arrives as "e p"; pass it as "e","p" via -Command.')
        }
    }
}
Get-HoldoutGuard -SeedSet $SeedSet -Ack ([bool]$IKnowThisIsHoldout)

Write-Host ('[spec] ' + (Split-Path -Leaf $Spec) + ' base=' + $specObj.base_weights + ' opp=' + $specObj.opponent +
           ' beamA=' + $specObj.beam.candidate + ' train_seeds=' + $specObj.seeds.train.Count +
           ' holdout_seeds=' + $specObj.seeds.holdout.Count + ' overlap=' + $specObj._seed_intersection +
           ' lineup_overlap=' + $specObj._lineup_overlap)
Write-Host ('[frozen] AI_Battle.gd=' + (Get-Sha256Hex12 (Join-Path $script:RepoRoot 'RL\ai\AI_Battle.gd')) +
           ' opponent_copy=' + (Get-Sha256Hex12 $script:OpponentScript) +
           ' harness=' + (Get-Sha256Hex12 $script:HarnessScript) +
           ' weights_base=' + (Get-Sha256Hex12 (Join-Path $script:RepoRoot $specObj.base_weights)))
Write-Host ('[paths] opponent=' + $script:OpponentScript + ' harness=' + $script:HarnessScript + ' scene=' + $script:HarnessScene)

function Get-SeedList {
    param([object]$SpecObj, [string]$Set, [int]$Start, [int]$Block, [int]$Max)
    [int[]]$seeds = @($SpecObj.seeds.$Set | ForEach-Object { [int]$_ })
    if ($Start -gt 0) { $seeds = @($seeds[$Start..($seeds.Count - 1)]) }
    if ($Block -gt 0 -and $seeds.Count -gt $Block) { $seeds = @($seeds[0..($Block - 1)]) }
    if ($Max -gt 0 -and $seeds.Count -gt $Max) { $seeds = @($seeds[0..($Max - 1)]) }
    # ',' keeps a one-element result an array (PowerShell otherwise unwraps it and .Count breaks).
    return ,$seeds
}

function Get-ConfigNamesFromArgs([string[]]$Arg, [object]$SpecObj) {
    if (-not $Arg -or $Arg.Count -eq 0 -or ($Arg.Count -eq 1 -and $Arg[0] -eq 'all')) {
        return @($SpecObj.configs | ForEach-Object { [string]$_.name })
    }
    $out = @()
    foreach ($piece in $Arg) {
        foreach ($p in ($piece -split ',')) {
            $t = $p.Trim()
            if ($t) { $out += $t }
        }
    }
    return $out
}

switch ($Task) {
    'selftest' {
        $f = Test-StatsSelfTest
        exit $f
    }
    'coverage' {
        $rep = Get-LineupCoverageReport -Spec $specObj
        $lines = @()
        $lines += '# Lineup pool coverage'
        $lines += ''
        $lines += ('generated by Train.ps1 -Task coverage at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $lines += ''
        $lines += $rep.Lines
        $lines += ''
        $lines += ('## train seeds, per-seed lineups (first 12 of ' + @($specObj.seeds.train).Count + ')')
        $lines += ''
        $lines += '| seed | round | slot | stride | lineup_used | side | enemy_deck | player_deck | filler |'
        $lines += '|---|---|---|---|---|---|---|---|---|'
        $showTrain = @($specObj.seeds.train)
        if ($showTrain.Count -gt 12) { $showTrain = @($showTrain[0..11]) }
        foreach ($sd in $showTrain) {
            $i = Get-SeedInfo -Spec $specObj -Seed ([int]$sd)
            $lines += ('| ' + $sd + ' | ' + $i.round + ' | ' + $i.slot + ' | ' + $i.train_stride + ' | `' + $i.lineup_used + '` | ' + $i.lineup_side + ' | `' + $i.enemy_deck + '` | `' + $i.player_deck + '` | ' + $(if ($i.fill_hero) { '`' + $i.fill_hero + '`' } else { '-' }) + ' |')
        }
        $lines += ''
        $lines += ('## holdout seeds, per-seed lineups (all ' + @($specObj.seeds.holdout).Count + ')')
        $lines += ''
        $lines += '| seed | round | slot | stride | lineup_used | side | enemy_deck | player_deck | filler |'
        $lines += '|---|---|---|---|---|---|---|---|---|'
        foreach ($sd in @($specObj.seeds.holdout)) {
            $i = Get-SeedInfo -Spec $specObj -Seed ([int]$sd)
            $lines += ('| ' + $sd + ' | ' + $i.round + ' | ' + $i.slot + ' | ' + $i.holdout_stride + ' | `' + $i.lineup_used + '` | ' + $i.lineup_side + ' | `' + $i.enemy_deck + '` | `' + $i.player_deck + '` | ' + $(if ($i.fill_hero) { '`' + $i.fill_hero + '`' } else { '-' }) + ' |')
        }
        $lines += ''
        $lines += '## anchor pools (the side that does not get the generated lineup)'
        $lines += ''
        $lines += ('lineup version = ' + (Get-LineupVersion $specObj))
        $lines += ''
        $lines += 'each anchor side fields: pool heroes + 1 deterministic filler (`filler` column above); filler = candidates[seed mod count], candidates = hero universe minus that seed''s generated lineup minus that seed''s pools, sorted.'
        $lines += ''
        $lines += '| set | pool | heroes |'
        $lines += '|---|---|---|'
        $pools = Get-LineupPoolSet -Spec $specObj
        foreach ($setName in @('train', 'holdout')) {
            $idx = 0
            foreach ($pool in $pools.$setName) {
                $idx++
                $lines += ('| ' + $setName + ' | ' + $idx + ' | `' + ($pool -join ',') + '` |')
            }
        }
        $lines += ''
        $lines += '## hero appearance counts'
        $lines += ''
        $lines += Get-LineupCoverageTable -Spec $specObj
        $out = Join-Path $PSScriptRoot 'lineup_coverage.md'
        Write-TextUtf8 -Path $out -Lines $lines
        $rep.Lines | ForEach-Object { Write-Host $_ }
        Write-Host ('[coverage] wrote ' + $out)
    }
    'gen' {
        $names = Get-ConfigNamesFromArgs -Arg $Configs -SpecObj $specObj
        $resolved = Resolve-Configs -Spec $specObj -Names $names -Run $Run
        foreach ($c in $resolved) {
            $fp = Get-WeightsFingerprint $c.weights_file
            # beamA/beamB are printed as the EFFECTIVE values that will be handed to the harness, so a
            # `gen` run is proof of what a beam arm will actually measure, without playing a game.
            Write-Host ('[gen] ' + $c.name + ' -> ' + $c.weights_file + ' sha12=' + (Get-Sha256Hex12 $c.weights_file) +
                        ' fp=' + $fp + ' beamA=' + [int]$c.beam + ' beamB=' + [int](Get-CfgBeamOpp $c))
        }
    }
    'status' {
        $rows = @(Read-MeasureRows $Run)
        Write-Host ('[status] run=' + $Run + ' rows=' + $rows.Count)
        # version integrity first: is this run dir still homogeneous?
        $hs = Get-RunHashStatus -Run $Run
        Write-Host ('[status] script hashes now     : ' + (Get-ScriptHashString))
        if ($hs.Status -eq 'new') {
            if ($rows.Count -gt 0) {
                Write-Host ('[status] !! ' + $rows.Count + ' row(s) but NO run_manifest.json -> historical run, version unrecorded.')
                Write-Host '[status] !! Its numbers belong to the OLDER script set (see the report warnings); do not append to it.'
            } else {
                Write-Host '[status] no run_manifest.json yet (nothing measured in this run)'
            }
        } elseif ($hs.Status -eq 'match') {
            Write-Host ('[status] manifest ' + $hs.Manifest.created + ' -> MATCH (single version, safe to append)')
        } else {
            Write-Host ('[status] manifest ' + $hs.Manifest.created + ' -> MISMATCH: ' +
                        'cand=' + $hs.Manifest.cand + ' base=' + $hs.Manifest.base + ' duel=' + $hs.Manifest.duel + ' skil=' + $hs.Manifest.skil)
            Write-Host '[status] !! this table MIXES versions; use -AllowHashChange to archive+continue, or a fresh -Run'
        }
        if ($rows.Count -gt 0) {
            $byConfig = $rows | Group-Object config
            foreach ($g in $byConfig) {
                $seeds = @($g.Group | ForEach-Object { [int]$_.seed } | Sort-Object -Unique)
                Write-Host ('[status]   ' + $g.Name + ': games=' + $g.Count + ' seeds=' + $seeds.Count + ' [' + ($seeds -join ',') + ']')
            }
            Write-Host ('[status] raw log: ' + (Get-RawLogPath $Run))
        }
    }
    'equiv' {
        # Equivalence proof for the parallel runner: run the SAME cells serially and with -Workers K,
        # then require the game rows to match EXACTLY (every field except wall/godpid/batch file names).
        # If any row differs, parallelism must not be trusted; report which fields differ.
        $names = Get-ConfigNamesFromArgs -Arg $Configs -SpecObj $specObj
        $resolved = Resolve-Configs -Spec $specObj -Names $names -Run 'equiv'
        $seeds = Get-SeedList -SpecObj $specObj -Set $SeedSet -Start $SeedStart -Block $SeedBlock -Max $MaxSeeds
        if ($seeds.Count -eq 0) { throw 'equiv: empty seed list' }
        $k = [Math]::Max(2, [Math]::Min(10, $Workers))
        # Games per arm = seeds x firsts x asides. The asides factor was missing here, so `games/arm`
        # printed HALF the games an arm actually plays (one cell = one game per aside), which made the
        # s/game derived from it look twice as good as reality.
        $gamesPlanned = $seeds.Count * @($specObj.measurement.firsts).Count * @($specObj.measurement.asides).Count
        Write-Host ('[equiv] configs=' + ($names -join ',') + ' seeds=' + ($seeds -join ',') + ' games/arm=' + $gamesPlanned + ' workers=' + $k)
        $sum = @()
        foreach ($arm in @(@{ n = 'serial'; w = 1 }, @{ n = 'parallel'; w = $k })) {
            $armRun = 'equiv_' + $arm.n
            Write-Host ('[equiv] --- arm ' + $arm.n + ' (workers=' + $arm.w + ') ---')
            $t0 = Get-Date
            [void](Start-MeasureRun -Run $armRun -Configs $resolved -Seeds $seeds -Spec $specObj `
                  -TimeoutSec $TimeoutSec -Workers $arm.w -SpecPath $Spec -Force -LeagueScope ('equiv:' + [string]$k))
            $wall = ((Get-Date) - $t0).TotalSeconds
            $rows = @(Read-MeasureRows $armRun)
            $sum += [pscustomobject]@{ Arm = $arm.n; Workers = $arm.w; Rows = $rows.Count; WallSec = $wall; SecPerGame = $(if ($rows.Count) { $wall / $rows.Count } else { 0 }) }
        }
        $sum | ForEach-Object { Write-Host ('[equiv] arm ' + $_.Arm + ': rows=' + $_.Rows + ' wall=' + (Format-Num $_.WallSec 1) + 's s/game=' + (Format-Num $_.SecPerGame 1)) }
        # --- compare game rows field by field (ignore timing/bookkeeping columns) ---
        # weights_fp belongs to this list: the parallel arm's table is rebuilt from the merged raw log,
        # which records the weights file's sha12 (audit=w=<sha12>) but not the fingerprint, so the column
        # is empty there. It is not a measurement - both arms run the SAME weights file anyway.
        $ignore = @('run', 'batch_out', 'batch_wall_s', 'line_no', 'weights_sha12', 'audit', 'weights_file', 'weights_fp', 'inv')
        $rs = @(Import-Csv (Join-Path (Get-ResultsDir 'equiv_serial') 'measure.csv') -Encoding UTF8)
        $rp = @(Import-Csv (Join-Path (Get-ResultsDir 'equiv_parallel') 'measure.csv') -Encoding UTF8)
        $keyCols = @('config', 'seed', 'seq')
        $idxS = @{}; foreach ($r in $rs) { $idxS[(($keyCols | ForEach-Object { [string]$r.$_ }) -join '|')] = $r }
        $idxP = @{}; foreach ($r in $rp) { $idxP[(($keyCols | ForEach-Object { [string]$r.$_ }) -join '|')] = $r }
        $cols = @($rs[0].PSObject.Properties.Name | Where-Object { $ignore -notcontains $_ })
        $missing = @(); $diffs = @()
        foreach ($key in $idxS.Keys) {
            if (-not $idxP.ContainsKey($key)) { $missing += $key; continue }
            foreach ($col in $cols) {
                if ([string]$idxS[$key].$col -ne [string]$idxP[$key].$col) {
                    $diffs += ($key + ' field=' + $col + ' serial=[' + [string]$idxS[$key].$col + '] parallel=[' + [string]$idxP[$key].$col + ']')
                }
            }
        }
        foreach ($key in $idxP.Keys) { if (-not $idxS.ContainsKey($key)) { $missing += ('parallel-only:' + $key) } }
        Write-Host ''
        Write-Host ('[equiv] serial games=' + $rs.Count + ' parallel games=' + $rp.Count + ' compared cols=' + ($cols -join ','))
        Write-Host ('[equiv] missing keys=' + $missing.Count + ' differing fields=' + $diffs.Count)
        if ($diffs.Count -eq 0 -and $missing.Count -eq 0) {
            Write-Host '[equiv] RESULT: PASS - parallel output is field-for-field identical to serial'
        } else {
            Write-Host '[equiv] RESULT: FAIL - parallelism changes results; do NOT trust parallel runs'
            $diffs | Select-Object -First 20 | ForEach-Object { Write-Host ('  diff: ' + $_) }
            $missing | Select-Object -First 10 | ForEach-Object { Write-Host ('  missing: ' + $_) }
        }
        $lines = @()
        $lines += ('## equivalence check: serial vs -Workers ' + $k)
        $lines += ''
        $lines += ('- cells: configs=' + ($names -join ',') + ' seeds=' + ($seeds -join ',') + ' games per arm=' + $gamesPlanned)
        $lines += ''
        $lines += '| arm | workers | games | wall_s | s/game |'
        $lines += '|---|---|---|---|---|'
        foreach ($s in $sum) { $lines += ('| ' + $s.Arm + ' | ' + $s.Workers + ' | ' + $s.Rows + ' | ' + (Format-Num $s.WallSec 1) + ' | ' + (Format-Num $s.SecPerGame 1) + ' |') }
        $lines += ''
        $lines += ('- compared fields: ' + ($cols -join ', '))
        $lines += ('- differing fields: ' + $diffs.Count + ' ; missing keys: ' + $missing.Count)
        $lines += ('- RESULT: ' + $(if ($diffs.Count -eq 0 -and $missing.Count -eq 0) { 'PASS' } else { 'FAIL' }))
        $lines += ''
        if ($OutMd) { Write-TextUtf8 -Path $OutMd -Lines $lines; Write-Host ('[equiv] wrote ' + $OutMd) }
    }
    'league' {
        # Self-play league bookkeeping. No games are played:
        #   -Task league                            -> show the config, the checkpoint and the planned split
        #   -Task league -Configs <cfg> -Run <run>  -> INIT the checkpoint from that config's weights,
        #                                              or PROMOTE the accepted round winner (same call)
        #   -Task league ... -Force                 -> overwrite an existing checkpoint (records the old sha12)
        $lg = Get-LeagueConfig -Spec $specObj
        if (-not $lg) { throw 'league: the spec has no (enabled) league block' }
        $ckPath = $lg.checkpoint
        $exists = Test-Path -LiteralPath $ckPath
        Write-Host ('[league] fraction=' + $lg.fraction + ' checkpoint=' + $lg.checkpoint_name +
                    ' exists=' + $exists + $(if ($exists) { ' sha12=' + $lg.checkpoint_sha12 } else { '' }))
        $names = @()
        # @(...) because a single -Configs value binds as a plain string, which has no .Count in PS 5.1
        # (that threw "The property 'Count' cannot be found on this object").
        $cfgArgs = @($Configs)
        if ($cfgArgs.Count -gt 0 -and -not ($cfgArgs.Count -eq 1 -and [string]$cfgArgs[0] -eq 'all')) {
            $names = @(Get-ConfigNamesFromArgs -Arg $Configs -SpecObj $specObj)
        }
        if ($names.Count -eq 0) {
            Write-Host '[league] no -Configs given -> inspection only (pass -Configs <cfg> -Run <run> to write/promote the checkpoint)'
            $seeds = Get-SeedList -SpecObj $specObj -Set $SeedSet -Start $SeedStart -Block $SeedBlock -Max $MaxSeeds
            if ($seeds.Count -gt 0) {
                $nSelf = 0; $nBase = 0
                foreach ($n in @($specObj.configs | ForEach-Object { [string]$_.name })) {
                    foreach ($sd in $seeds) {
                        foreach ($fs in @($specObj.measurement.firsts)) {
                            if (Test-LeagueSelfPlay -Run $Run -Config $n -Seed $sd -First $fs -Fraction $lg.fraction) { $nSelf++ } else { $nBase++ }
                        }
                    }
                }
                Write-Host ('[league] planned split for run=' + $Run + ' (all configs x ' + $seeds.Count + ' seeds): self-play cells=' + $nSelf + ' base cells=' + $nBase)
            }
            return
        }
        if ($exists -and -not $Force) {
            throw ('league: checkpoint already exists (' + $ckPath + '); pass -Force to overwrite (its sha12 ' + $lg.checkpoint_sha12 + ' keys older self-play rows, which then get re-measured)')
        }
        $oldSha = ''
        if ($exists) { $oldSha = $lg.checkpoint_sha12 }
        $resolved = Resolve-Configs -Spec $specObj -Names $names -Run $Run
        $src = @($resolved)[0]
        $base = Join-Path $script:RepoRoot $specObj.base_weights
        $theta = $null
        $co = @($specObj.configs | Where-Object { [string]$_.name -eq [string]$src.name })[0]
        if ($co.PSObject.Properties.Name -contains 'theta') { $theta = $co.theta }
        $note = 'league checkpoint from config ' + $src.name + ' (run ' + $Run + ')'
        $written = New-CandidateWeights -BasePath $base -Name ('league_' + [string]$src.name) -Theta $theta -Note $note -OutPath $ckPath
        $sha = Get-Sha256Hex12 $written
        Write-Host ('[league] wrote checkpoint ' + $written + ' sha12=' + $sha + $(if ($oldSha) { ' (replaced ' + $oldSha + ')' } else { '' }))
        Write-Host '[league] the next self-play round keys its cells on this sha12; rows of the previous generation are ignored, not reused'
    }
    'repair' {
        # measure.csv is derived data; rebuild it from the append-only raw log + per-batch stdout.
        Write-Host ('[repair] rebuilding measure.csv for run ' + $Run + ' from raw_lines.log')
        $n = Repair-MeasureCsv -Run $Run -Spec $specObj
        Write-Host ('[repair] rebuilt ' + $n + ' row(s); previous file kept as measure.csv.before_repair')
    }
    'compare' {
        $names = Get-ConfigNamesFromArgs -Arg $Configs -SpecObj $specObj
        if ($names.Count -lt 2) {
            throw 'compare: pass -Configs <control>,<treatment>[,<treatment>...] (the first name is the control)'
        }
        $control = $names[0]
        $treatments = @($names[1..($names.Count - 1)])
        Write-Host ('[compare] run=' + $Run + ' control=' + $control + ' treatments=' + ($treatments -join ','))
        $rows = @(Read-MeasureRows $Run)
        if ($rows.Count -eq 0) { throw ('compare: run ' + $Run + ' has no measured rows') }
        $lines = @()
        $lines += ('# Sensitivity comparison: run ' + $Run + ' (control = ' + $control + ')')
        $lines += ''
        $lines += ('generated by Train.ps1 -Task compare at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $lines += ''
        $lines += 'Pairing unit = (seed, first, a_side). Only tuples present for BOTH configs are used.'
        $lines += ''
        $lines += Get-SensitivityTable -Run $Run -Control $control -Treatments $treatments
        if ($OutMd) {
            Write-TextUtf8 -Path $OutMd -Lines $lines
            Write-Host ('[compare] wrote ' + $OutMd)
        } else {
            $lines | ForEach-Object { Write-Host $_ }
        }
    }
    'estimate' {
        $rows = @(Read-MeasureRows $Run)
        if ($rows.Count -eq 0) { throw ('estimate: run ' + $Run + ' has no measured rows yet') }
        # Two different quantities, and conflating them is how a 2.6 h plan looks like 25 h:
        #   summed_batch_wall = the sum of EVERY batch's wall clock. With K workers in parallel that
        #                       sum counts K games at once, so it is throughput, not elapsed time.
        #   real wall         = the wall clock the parent actually spent, as recorded in results/<Run>.md.
        #                       estimate uses the best (smallest wall) invocation that measured the most
        #                       games, because an earlier invocation may have resumed a partial table.
        $wall = 0.0
        foreach ($r in $rows) { $wall += (Get-Num $r.batch_wall_s) }
        $summedPerGame = $wall / $rows.Count
        $inv = @(Get-ThroughputEvents -Run $Run)
        $realWall = 0.0; $realGames = 0
        if ($inv.Count -gt 0) {
            $realGames = ($inv | Measure-Object -Property Games -Maximum).Maximum
            $best = @($inv | Where-Object { $_.Games -eq $realGames })
            $realWall = ($best | Measure-Object -Property WallSec -Minimum).Minimum
        }
        $realPerGame = 0.0
        if ($realWall -gt 0) { $realPerGame = $realWall / $realGames }
        Write-Host ('[estimate] run=' + $Run + ' games=' + $rows.Count + ' recorded invocations=' + $inv.Count)
        Write-Host ('[estimate]   summed batch wall=' + (Format-Num $wall 1) + 's -> ' + (Format-Num $summedPerGame 2) +
                    ' s/game  [worker-seconds, NOT elapsed: every worker counts at once]')
        if ($realWall -gt 0) {
            Write-Host ('[estimate]   real wall (best invocation)=' + (Format-Num $realWall 1) + 's for ' + $realGames +
                        ' games -> ' + (Format-Num $realPerGame 2) + ' s/game  <-- USE THIS for planning')
            $wm = ($best | Measure-Object -Property Workers -Maximum).Maximum
            Write-Host ('[estimate]   parallel speedup vs summed = ' + (Format-Num ($wall / $realWall) 2) + 'x' +
                        ' (recorded with ' + $wm + ' worker(s); summed/real ~= the worker count that overlapped)')
        } else {
            Write-Host '[estimate]   !! no throughput.csv row and no "wall clock this invocation" line for this run'
            Write-Host '[estimate]   !! (runs measured before throughput.csv existed) -> the projections below fall back to the summed figure and are TOO PESSIMISTIC'
        }
        $planPerGame = $realPerGame
        $planBasis = 'real wall'
        if ($planPerGame -le 0) { $planPerGame = $summedPerGame; $planBasis = 'summed wall (fallback, pessimistic)' }
        Write-Host ('[estimate] projected wall clock uses ' + (Format-Num $planPerGame 2) + ' s/game (' + $planBasis + '), single-machine')
        foreach ($p in $specObj.phases.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $ph = $p.Value
            if ($ph.PSObject.Properties.Name -notcontains 'games_per_config') { continue }
            $games = [int]$ph.games_per_config * [int]$ph.configs
            $sec = $games * $planPerGame
            $workers = 1
            if ($ph.PSObject.Properties.Name -contains 'workers') { $workers = [Math]::Max(1, [int]$ph.workers) }
            Write-Host ('[estimate] ' + $p.Name + ': configs=' + $ph.configs + ' games/config=' + $ph.games_per_config +
                        ' total_games=' + $games + ' -> ' + (Format-Num ($sec / 60.0) 1) + ' min (' + (Format-Num ($sec / 3600.0) 2) + ' h)' +
                        $(if ($workers -gt 1) { '  [x' + $workers + ' workers -> ' + (Format-Num ($sec / $workers / 60.0) 1) + ' min / ' + (Format-Num ($sec / $workers / 3600.0) 2) + ' h]' } else { '' }))
        }
    }
    'run' {
        $names = Get-ConfigNamesFromArgs -Arg $Configs -SpecObj $specObj
        $resolved = Resolve-Configs -Spec $specObj -Names $names -Run $Run
        $seeds = Get-SeedList -SpecObj $specObj -Set $SeedSet -Start $SeedStart -Block $SeedBlock -Max $MaxSeeds
        if ($seeds.Count -eq 0) { throw 'run: empty seed list' }
        # Games per config = seeds x firsts x asides (one cell plays one game per aside; the same
        # definition the equiv report below uses).
        $gamesPlanned = $seeds.Count * @($specObj.measurement.firsts).Count * @($specObj.measurement.asides).Count
        Write-Host ('[run] run=' + $Run + ' configs=' + ($names -join ',') + ' seed_set=' + $SeedSet +
                   ' seeds=' + $seeds.Count + ' [' + $seeds[0] + '..' + $seeds[$seeds.Count - 1] + ']' +
                   ' firsts=' + ($specObj.measurement.firsts -join ',') + ' asides=' + ($specObj.measurement.asides -join ',') +
                   ' planned_games_per_config=' + $gamesPlanned + ' fixed_decks=' + [bool]$FixedDecks)
        $t0 = Get-Date
        $res = Start-MeasureRun -Run $Run -Configs $resolved -Seeds $seeds -Spec $specObj -Force:$Force -TimeoutSec $TimeoutSec -FixedDecks:$FixedDecks -Workers $Workers -SpecPath $Spec -AllowHashChange:$AllowHashChange
        $wall = ((Get-Date) - $t0).TotalSeconds
        Write-Host ('[run] TOTAL wall=' + (Format-Num $wall 1) + 's for ' + $res.NewGames + ' game(s)')
        # Durable real-wall record: this is what -Task estimate must use, not the summed batch walls.
        Add-ThroughputEvent -Run $Run -Games ([int]$res.NewGames) -WallSec $wall -Workers ([int]$Workers)
        Write-Host ('[run] recorded throughput -> ' + (Join-Path (Get-ResultsDir $Run) 'throughput.csv') +
                    ' (' + $res.NewGames + ' games in ' + (Format-Num $wall 1) + 's = ' +
                    $(if ($res.NewGames -gt 0) { Format-Num ($wall / $res.NewGames) 2 } else { 'n/a' }) + ' s/game, real wall)')
        Write-SummaryCsv -Run $Run -Spec $specObj -ConfigNames $names
        $lines = @()
        $lines += ('## results: run ' + $Run + ' (seed set ' + $SeedSet + ')')
        $lines += ''
        $lines += ('- seeds: `' + ($seeds -join ',') + '`')
        $lines += ('- games per config: ' + $gamesPlanned + ' (firsts=' + ($specObj.measurement.firsts -join '/') + ', asides=' + ($specObj.measurement.asides -join '/') + ')')
        $lines += ('- total Godot wall clock this invocation: ' + (Format-Num $wall 1) + 's')
        $lines += ''
        $lines += Get-StatsTable -Run $Run -SeedSet $SeedSet -Spec $specObj -ConfigNames $names
        $lines += ''
        $lines += ('- raw verbatim R| lines: ' + (Get-RawLogPath $Run))
        $lines += ('- parsed per-game table: ' + (Join-Path (Get-ResultsDir $Run) 'measure.csv'))
        $lines += ''
        $lines += '### verifiable throughput'
        $lines += ''
        foreach ($r in $resolved) {
            $sub = @(Read-MeasureRows $Run) | Where-Object { [string]$_.config -eq $r.name }
            foreach ($sd in $seeds) {
                $g = @($sub | Where-Object { [int]$_.seed -eq $sd })
                if ($g.Count -eq 0) { continue }
                $firstRow = $g[0]
                $lines += ('- ' + $r.name + ' seed ' + $sd + ': ' + $g.Count + ' game(s), wall ' + ([string]$firstRow.batch_wall_s) + 's, batch `' + ([string]$firstRow.batch_out) + '`')
            }
        }
        $lines += ''
        $lines += Get-BeamBlock -Spec $specObj -Configs $resolved
        $lines += ''
        $lines += Get-ParamsBlock -Spec $specObj
        if ($OutMd) {
            Add-ContentUtf8 -Path $OutMd -Lines $lines
            Write-Host ('[run] appended markdown to ' + $OutMd)
        } else {
            $lines | ForEach-Object { Write-Host $_ }
        }
        if ($MaxWallSec -gt 0) {
            Write-Host ('[run] wall guard: ' + (Format-Num $wall 1) + 's vs limit ' + $MaxWallSec + 's -> ' + $(if ($wall -le $MaxWallSec) { 'OK' } else { 'OVER' }))
            if ($wall -gt $MaxWallSec) { exit 2 }
        }
    }
}
