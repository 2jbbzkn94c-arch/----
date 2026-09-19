# Pick the holdout stride set (separate distribution) and verify that no holdout lineup
# collides with any train lineup. Pure ASCII, read-only, stdout only.
#
# Generator model (must stay in sync with RlTrain.ps1 Get-Lineup):
#   slots = S, round r = floor(seed/S), slot j = seed mod S
#   stride = strides[(r + j) mod strideCount]
#   triple = ( (i*stride + r + offset) mod 49 ) for i = j, j+1, j+2   [1-based hero_XX]

param(
    [string]$TrainStrides = '11,3,29,19,37,15,39,25,45,27,31,1',
    [int]$Slots = 12,
    [int]$TrainStart = 10001,
    [int]$TrainCount = 120,
    [int]$HoldStart = 90001,
    [int]$HoldCount = 24,
    [int]$Trials = 100000,
    [int]$Seed = 424242
)

$PoolSize = 49
$oddStrides = @(1,3,5,9,11,13,15,17,19,23,25,27,29,31,33,37,39,41,43,45,47)
$rng = New-Object System.Random($Seed)

function New-LineupKey([int]$seedVal, [int[]]$strides, [int]$slots, [int]$offset) {
    $r = [int][Math]::Floor([double]$seedVal / [double]$slots)
    $j = $seedVal % $slots
    $stride = $strides[(($r + $j) % $strides.Count)]
    $ids = @()
    for ($i = $j; $i -le $j + 2; $i++) {
        $v = ((($i * $stride + $r + $offset) % $PoolSize) + $PoolSize) % $PoolSize
        $ids += ('{0:D2}' -f ($v + 1))
    }
    return ($ids -join '-')
}

$trainKeys = @{}
$ts = @($TrainStrides -split ',' | ForEach-Object { [int]$_ })
for ($s = 0; $s -lt $TrainCount; $s++) { $trainKeys[(New-LineupKey ($TrainStart + $s) $ts $Slots 0)] = $true }
Write-Host ('train distinct lineups = ' + $trainKeys.Count)

$best = $null
for ($t = 0; $t -lt $Trials; $t++) {
    $picked = New-Object System.Collections.Generic.List[int]
    while ($picked.Count -lt $ts.Count) {
        $v = $oddStrides[$rng.Next(0, $oddStrides.Count)]
        if (-not $picked.Contains($v)) { $picked.Add($v) }
    }
    $cand = $picked.ToArray()
    $collide = 0
    $holdKeys = @{}
    for ($s = 0; $s -lt $HoldCount; $s++) {
        $k = New-LineupKey ($HoldStart + $s) $cand $Slots 0
        $holdKeys[$k] = $true
        if ($trainKeys.ContainsKey($k)) { $collide++ }
    }
    if ($collide -eq 0 -and $holdKeys.Count -eq $HoldCount) {
        $best = $cand
        Write-Host ('trial ' + $t + ': disjoint holdout set found: ' + ($cand -join ','))
        break
    }
}

if ($null -eq $best) { Write-Host 'NO disjoint holdout stride set found'; exit 1 }

# final verification both directions
$holdKeys = @{}
for ($s = 0; $s -lt $HoldCount; $s++) { $holdKeys[(New-LineupKey ($HoldStart + $s) $best $Slots 0)] = $true }
$overlap = @($holdKeys.Keys | Where-Object { $trainKeys.ContainsKey($_) })
Write-Host ('HOLDOUT_STRIDES=' + ($best -join ','))
Write-Host ('holdout distinct lineups = ' + $holdKeys.Count)
Write-Host ('train/holdout overlap = ' + $overlap.Count + $(if ($overlap.Count -gt 0) { ' -> ' + ($overlap -join ',') } else { '' }))
Write-Host ''
Write-Host 'holdout lineups:'
for ($s = 0; $s -lt $HoldCount; $s++) {
    Write-Host ('  seed ' + ($HoldStart + $s) + ' -> ' + (New-LineupKey ($HoldStart + $s) $best $Slots 0))
}
