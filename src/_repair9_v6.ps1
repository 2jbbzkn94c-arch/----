# 修复引擎 v6:正确补引号(区分字符串结束位置)+ 二次拆行校正
# 输入 src/Battle.gd.repaired2(v3 输出) → 输出 src/Battle.gd.v6
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.repaired2",[System.Text.Encoding]::UTF8)

function Fix-LineQuotes($line){
  # 逐字符解析:找出代码区(注释外)的字符串,若行内字符串未闭合,
  # 根据后续出现的边界决定补 '"' 的位置。
  # 边界集:')' ']' ',' ' %' '%' 或行尾(# 注释前)
  $inS=$false; $com=$false; $sStart=-1
  for($i=0;$i -lt $line.Length;$i++){
    $ch=$line[$i]
    if($com){ break }
    if($ch -eq '#' -and -not $inS){ $com=$true; break }
    if($ch -eq '"'){ 
      if($inS){ $inS=$false } else { $inS=$true; $sStart=$i }
    }
  }
  if(-not $inS){ return $line }
  # 有未闭合字符串:从 sStart 之后找第一个 边界 字符,在其前插 '"'
  $insert=$line.Length
  # 只考虑 # 注释之前
  $end=$line.IndexOf('#'); if($end -lt 0){$end=$line.Length}
  for($i=$sStart+1;$i -lt $end;$i++){
    $c=$line[$i]
    if($c -eq ')' -or $c -eq ']' -or $c -eq ',' ){
      $insert=$i; break
    }
    if($c -eq '%' -and $i -lt $end-1 -and $line[$i+1] -eq ' '){ $insert=$i; break }
  }
  # 若字符串内容后面没有边界 → 在行尾(注释前)补
  $new=$line.Substring(0,$insert)+'"'+$line.Substring($insert)
  return $new
}

$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.Length -gt 0 -and -not $t.StartsWith('#')){
    $r=Fix-LineQuotes $l
    if($r -ne $l){$fixed++}
    $l=$r
  }
  $out.Add($l)
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v6",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v6 quote-fixed: "+$fixed)