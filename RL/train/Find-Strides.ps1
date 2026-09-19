# Search a stride set for the deterministic lineup generator so that
#   * every one of the 49 heroes appears at least twice in the train seed set
#   * the train/holdout lineups stay disjoint
# Pure ASCII. Read-only helper; writes nothing except stdout.
# Generator model (must stay in sync with RlTrain.ps1 Get-Lineup):
#   slots = S, round r = floor(seed/S), slot j = seed mod S
#   stride = strides[(r + j) mod strideCount]
#   triple = ( (i*stride + r + jitter*seed) mod 49 ) for i = j, j+1, j+2   [1-based hero_XX]

param(
    [int]$Slots = 12,
    [int]$SeedCount = 120,
    [int]$SeedStart = 10001,
    [int]$StrideCount = 12,
    [int]$Trials = 200000,
    [int]$Jitter = 0,
    [int]$Seed = 20260913
)

$PoolSize = 49
$oddStrides = @(1,3,5,9,11,13,15,17,19,23,25,27,29,31,33,37,39,41,43,45,47)
$rng = New-Object System.Random($Seed)

$best = $null
for ($t = 0; $t -lt $Trials; $t++) {
    $picked = New-Object System.Collections.Generic.List[int]
    while ($picked.Count -lt $StrideCount) {
        $v = $oddStrides[$rng.Next(0, $oddStrides.Count)]
        if (-not $picked.Contains($v)) { $picked.Add($v) }
    }
    $strides = $picked.ToArray()
    $cov = New-Object 'int[]' ($PoolSize + 1)
    for ($s = 0; $s -lt $SeedCount; $s++) {
        $seedVal = $SeedStart + $s
        $r = [int][Math]::Floor([double]$seedVal / [double]$Slots)
        $j = $seedVal % $Slots
        $stride = $strides[(($r + $j) % $StrideCount)]
        for ($i = $j; $i -le $j + 2; $i++) {
            $v = ((($i * $stride + $r + $Jitter * $seedVal) % $PoolSize) + $PoolSize) % $PoolSize
            $cov[$v + 1]++
        }
    }
    $minCov = 9999
    for ($h = 1; $h -le $PoolSize; $h++) { if ($cov[$h] -lt $minCov) { $minCov = $cov[$h] } }
    if ($null -eq $best -or $minCov -gt $best.min) {
        $best = [pscustomobject]@{ min = $minCov; strides = $strides }
        Write-Host ('trial ' + $t + ': new best min_coverage=' + $minCov + ' strides=' + ($strides -join ','))
        if ($minCov -ge 3) { break }
    }
}
Write-Host ''
Write-Host ('BEST min_coverage=' + $best.min)
Write-Host ('STRIDES=' + ($best.strides -join ','))
