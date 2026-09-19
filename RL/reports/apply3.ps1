$ErrorActionPreference = "Stop"
$p = "RL\ai\AI_Battle.gd"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lines = [System.Collections.Generic.List[string]]::new()
foreach ($x in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) { $lines.Add($x) }
$done = @()
# 4) 捡攻击道具：echo 激活时不把 +1 加进 eatk
for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq 'u.eatk += 1' -and $lines[$i - 1].Trim() -eq 'u.atk_use_buff += 1') {
        $raw = $lines[$i]
        $ind = $raw.Substring(0, $raw.Length - $raw.TrimStart().Length)
        $lines[$i] = $ind + 'if u.echo_set < 0:   # 【RL 修正】共鸣者 echo 激活时真实 effective_atk() 直接 return，道具 +1 不生效'
        $lines.Insert($i + 1, $ind + [char]9 + 'u.eatk += 1')
        $done += "4-pickup"
        break
    }
}
# 5) 消耗攻击道具：echo 激活时只清账、不动 eatk
for ($i = 1; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i].Trim() -eq 'u.eatk = maxi(u.eatk - u.atk_use_buff, 0)' -and $lines[$i + 1].Trim() -eq 'u.atk_use_buff = 0') {
        $raw = $lines[$i]
        $ind = $raw.Substring(0, $raw.Length - $raw.TrimStart().Length)
        $lines.Insert($i, $ind + 'if u.echo_set >= 0:   # 【RL 修正】echo 激活：这 +1 从未计入 eatk，只清账')
        $lines.Insert($i + 1, $ind + [char]9 + 'u.atk_use_buff = 0')
        $lines.Insert($i + 2, $ind + [char]9 + 'return')
        $done += "5-consume"
        break
    }
}
[System.IO.File]::WriteAllLines($p, $lines, $utf8)
Write-Host ("DONE: " + ($done -join ",") + "  lines=" + $lines.Count)
Write-Host ("fork_sha12 = " + (Get-FileHash $p -Algorithm SHA256).Hash.ToLower().Substring(0,12))
$h = "RL\harness\" + [string][char]25216 + [string][char]33021 + [string][char]23545 + [string][char]25293 + ".gd"
Write-Host ("harness_exists = " + (Test-Path $h))
