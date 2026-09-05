# v9:精确补闭合引号
# 输入 Battle.gd.v7 → Battle.gd.v9
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v7",[System.Text.Encoding]::UTF8)

function Scan($line){
  # returns list of '#' positions outside strings and quote-open state
  $inS=$false;$comPos=-1
  for($i=0;$i -lt $line.Length;$i++){
    $ch=$line[$i]
    if($ch -eq '"'){ $inS=-not $inS }
    elseif($ch -eq '#' -and -not $inS){ return @{com=$i; open=$inS} }
  }
  return @{com=$line.Length; open=$inS}
}

$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $st=Scan $l
  if(-not $st.open){ $out.Add($l); continue }
  # 未闭合。找到最后一个(最内层)开引号的位置?由于只有一个字符串未闭合,找奇数个引号中最后一个开引号位置
  # 找最后一个 '"' 位置作为开引号
  $lastQ=-1
  for($j=$st.com-1;$j -ge 0;$j--){ if($l[$j] -eq '"'){ $lastQ=$j; break } }
  if($lastQ -lt 0){ $out.Add($l); continue }
  # 从 lastQ+1 扫描到 com,寻找:
  #  优先 ' % ' (空格百分号空格):字符串格式串。
  $end=$st.com
  $insert=-1
  for($j=$lastQ+1;$j -lt $end-2;$j++){
    if($l[$j] -eq ' ' -and $l[$j+1] -eq '%' -and ($l[$j+2] -eq ' ' -or $l[$j+2] -eq '[' -or $l[$j+2] -eq 'G' -or $l[$j+2] -eq 'g' -or $l[$j+2] -eq 'u' -or $l[$j+2] -eq 'p' -or $l[$j+2] -eq 'L' -or $l[$j+2] -eq 'D' -or $l[$j+2] -eq 'r' -or $l[$j+2] -eq 'a' -or $l[$j+2] -eq 'c' -or $l[$j+2] -eq 's' -or $l[$j+2] -eq 't')){
      $insert=$j; break
    }
  }
  if($insert -lt 0){
    # 否则:找第一个 行尾结束括号 ) 或 ] 或 , 之前(即字符串应闭于此)
    for($j=$lastQ+1;$j -lt $end;$j++){
      $ch=$l[$j]
      if($ch -eq ')' -or $ch -eq ']' -or $ch -eq ','){ $insert=$j; break }
    }
  }
  if($insert -lt 0){ $insert=$end }
  $new=$l.Substring(0,$insert)+'"'+$l.Substring($insert)
  $out.Add($new); $fixed++
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v9",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v9 fixed: "+$fixed)