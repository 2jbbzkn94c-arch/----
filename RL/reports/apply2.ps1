$ErrorActionPreference = "Stop"
$BS = [string][char]92
$TAB = [string][char]9
$CRLF = [string][char]13 + [string][char]10
$data = [System.IO.File]::ReadAllText("RL\reports\edits.txt", [System.Text.Encoding]::UTF8)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$cur = "RL\ai\AI_Battle.gd"
$blocks = [ordered]@{}
$tag = ""
foreach ($line in ($data -split ([string][char]10))) {
    $l = $line.TrimEnd([char]13).TrimEnd([char]10)
    if ($l.StartsWith("@@@")) { $tag = $l.Substring(3).Trim(); $blocks[$tag] = @{ old = ""; new = ""; file = $cur }; continue }
    if ($tag -eq "") { continue }
    if ($l.StartsWith("FILE")) { $cur = $l.Substring(4).Replace($BS + "t", $TAB).Trim(); $blocks[$tag]["file"] = $cur; continue }
    if ($l.StartsWith("OLD")) { $blocks[$tag]["old"] = $l.Substring(3); $blocks[$tag]["file"] = $cur; continue }
    if ($l.StartsWith("NEW")) { $blocks[$tag]["new"] = $l.Substring(3); continue }
}
$esc_n = $BS + "n"
$esc_t = $BS + "t"
function Unesc($s) { return $s.Replace($esc_n, $CRLF).Replace($esc_t, $TAB) }
$ok = 0; $bad = @()
foreach ($tag in $blocks.Keys) {
    $f = $blocks[$tag]["file"]
    $old = Unesc $blocks[$tag]["old"]
    $new = Unesc $blocks[$tag]["new"]
    $txt = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    if (-not $txt.Contains($old)) { $bad += $tag; continue }
    $txt = $txt.Replace($old, $new)
    [System.IO.File]::WriteAllText($f, $txt, $utf8)
    $ok++
}
Write-Host ("APPLIED " + $ok + " / " + $blocks.Count + "  FAILED: " + ($bad -join ","))
Write-Host ("fork_sha12 = " + (Get-FileHash "RL\ai\AI_Battle.gd" -Algorithm SHA256).Hash.ToLower().Substring(0,12))
Write-Host ("harness_sha12 = " + (Get-FileHash "RL\harness\pin.gd" -Algorithm SHA256).Hash.ToLower().Substring(0,12))
