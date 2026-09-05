# 词法分析:准确找出"真拆行"还是"仅丢字"
# 对每个损坏行,输出:片段、注释区/字符串区信息,供修复决策使用
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_recovered_probe.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F
$res=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ continue }
  # 行结构分析:标记位置,以及每个标记前后是注释还是字符串还是代码
  $pos=New-Object System.Collections.Generic.List[int]
  for($j=0;$j -lt $l.Length;$j++){ if($l[$j]-eq $BAD -or $l[$j]-eq $Q){ $pos.Add($j) } }
  # 简化输出:标注行内引号总数、# 位置、标记数
  $nq=0; $nstr=0; $ncn=0
  foreach($ch in $l.ToCharArray()){ if($ch -eq '"'){$nq++}; if($ch -eq '#' ){$nstr++}; if($ch -ge [int]0x4E00 -and $ch -le [int]0x9FFF){$ncn++} }
  $res.Add(("L{0} marks={1} quotes={2} hash={3} chinese={4} :: {5}" -f ($i+1),$pos.Count,$nq,$nstr,$ncn,$l.Substring(0,[Math]::Min(110,$l.Length))))
}
[System.IO.File]::WriteAllLines("$src\_lex1.txt",$res,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("lex1 entries: "+$res.Count)