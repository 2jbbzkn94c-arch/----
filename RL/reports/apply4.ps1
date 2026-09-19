$ErrorActionPreference = "Stop"
$p = "RL\ai\AI_Battle.gd"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$TAB = [string][char]9
$raw = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)
$mk = [System.IO.File]::ReadAllLines("RL\reports\dedupe.txt", [System.Text.Encoding]::UTF8)
$c47 = $mk[0].Trim()
$cEcho = $mk[1].Trim()
$cWS = $mk[2].Trim()
$uniq = @($mk[3].Trim(), $mk[4].Trim(), $mk[5].Trim())
$L = [System.Collections.Generic.List[string]]::new()
foreach ($x in $raw) { $L.Add($x) }
function IdxAll($list, $text, $mode) {
    $r = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = $list[$i].Trim()
        if ($mode -eq "eq" -and $t -eq $text) { $r += $i }
        if ($mode -eq "pre" -and $t.StartsWith($text)) { $r += $i }
    }
    return $r
}
# --- 块1 重复：从第 2 个 hero_47 注释到最后一个 var atkdown := false 之前，删掉 ---
$i47 = IdxAll $L $c47 "pre"
$iatk = IdxAll $L "var atkdown := false" "eq"
if ($i47.Count -ge 2 -and $iatk.Count -ge 2) {
    $s = $i47[1]; $e = $iatk[$iatk.Count - 1] - 1
    if ($e -ge $s) { $L.RemoveRange($s, $e - $s + 1) }
    Write-Host ("block1 removed lines " + $s + ".." + $e)
}
# --- 块3 重复：从第 2 个 echo 注释到其后第一个 u.echo_set 行，删掉 ---
$ice = IdxAll $L $cEcho "pre"
if ($ice.Count -ge 2) {
    $s = $ice[1]; $e = $s
    for ($i = $s; $i -lt $L.Count; $i++) { if ($L[$i].Trim() -eq 'u.echo_set = int(d.get("echo_set", -1))') { $e = $i; break } }
    $L.RemoveRange($s, $e - $s + 1)
    Write-Host ("block3 removed lines " + $s + ".." + $e)
}
# --- 块6 重复：从第 2 个风语者注释到 hero_17 那行为止，删掉 ---
$iws = IdxAll $L $cWS "pre"
if ($iws.Count -ge 2) {
    $s = $iws[1]; $e = $s
    for ($i = $s; $i -lt $L.Count; $i++) { if ($L[$i].Trim().StartsWith('if u.hero_id == "hero_17":')) { $e = $i - 1; break } }
    $L.RemoveRange($s, $e - $s + 1)
    Write-Host ("block6 removed lines " + $s + ".." + $e)
}
# --- 保首去重（只在唯一标记上） ---
$seen = @{}
$out = [System.Collections.Generic.List[string]]::new()
foreach ($ln in $L) {
    $t = $ln.Trim()
    if ($uniq -contains $t) { if ($seen.ContainsKey($t)) { continue } else { $seen[$t] = $true } }
    $out.Add($ln)
}
# --- 补 4) 捡道具守卫 ---
$did = @()
for ($i = 1; $i -lt $out.Count; $i++) {
    if ($out[$i].Trim() -eq 'u.eatk += 1' -and $out[$i - 1].Trim() -eq 'u.atk_use_buff += 1') {
        $rawline = $out[$i]
        $ind = $rawline.Substring(0, $rawline.Length - $rawline.TrimStart().Length)
        $out[$i] = $ind + 'if u.echo_set < 0:'
        $out.Insert($i + 1, ($ind + $TAB + 'u.eatk += 1'))
        $did += "4-pickup"
        break
    }
}
# --- 补 5) 消耗守卫 ---
for ($i = 1; $i -lt $out.Count - 1; $i++) {
    if ($out[$i].Trim() -eq 'u.eatk = maxi(u.eatk - u.atk_use_buff, 0)' -and $out[$i + 1].Trim() -eq 'u.atk_use_buff = 0') {
        $rawline = $out[$i]
        $ind = $rawline.Substring(0, $rawline.Length - $rawline.TrimStart().Length)
        $out.Insert($i, ($ind + 'if u.echo_set >= 0:'))
        $out.Insert($i + 1, ($ind + $TAB + 'u.atk_use_buff = 0'))
        $out.Insert($i + 2, ($ind + $TAB + 'return'))
        $did += "5-consume"
        break
    }
}
[System.IO.File]::WriteAllLines($p, $out, $utf8)
Write-Host ("GUARDS: " + ($did -join ",") + "  total_lines=" + $out.Count)
Write-Host ("var echo_set x" + (IdxAll $out "var echo_set := -1" "eq").Count + " / var atkdown x" + (IdxAll $out "var atkdown := false" "eq").Count + " / cu.echo_set x" + (IdxAll $out "cu.echo_set = u.echo_set" "eq").Count + " / u.echo_set=int x" + (IdxAll $out 'u.echo_set = int(d.get("echo_set", -1))' "eq").Count + " / other_ws x" + (IdxAll $out "var other_ws := false" "eq").Count)
Write-Host ("fork_sha12 = " + (Get-FileHash $p -Algorithm SHA256).Hash.ToLower().Substring(0,12))
