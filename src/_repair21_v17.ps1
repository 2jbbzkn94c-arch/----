# v17 最终拆行:注释行遇代码起点(含中文字符串参数的代码)应断行;括号未闭则续行
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src '_probe2.txt'),[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F
function Get-Ind3($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq [char]9 -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }
function PB3($s){ $inS=$false;$com=$false;$bal=0
  for($j=0;$j -lt $s.Length;$j++){ $c=$s[$j]
    if($com){break}
    if($c -eq '"'){ $inS=-not $inS; continue }
    if($c -eq '#' -and -not $inS){$com=$true; continue}
    if(-not $inS){ if($c -eq '('){$bal++} elseif($c -eq ')'){$bal--} elseif($c -eq '['){$bal+=10} elseif($c -eq ']'){$bal-=10} } }
  return $bal }
$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@|#)'
$codeRe=[regex]'^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'
$out=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $hm=$false; for($j=0;$j -lt $l.Length;$j++){ if($l[$j]-eq $BAD -or $l[$j]-eq $Q){$hm=$true;break} }
  if(-not $hm){ $out.Add($l); continue }
  $lead=Get-Ind3 $l; $body=$l.Substring($lead.Length)
  $frags=New-Object 'System.Collections.Generic.List[object]'
  $sb=New-Object System.Text.StringBuilder
  for($j=0;$j -lt $body.Length;$j++){ $ch=$body[$j]
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length){$frags.Add($sb.ToString());[void]$sb.Clear()} } else {[void]$sb.Append($ch)} }
  if($sb.Length){$frags.Add($sb.ToString())}
  if($frags.Count -eq 0){ $out.Add($l); continue }
  $bodyIsComment=$frags[0].TrimStart(" ","`t").StartsWith('#')
  $rows=New-Object 'System.Collections.Generic.List[object]'
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=[string]$frags[$f]; $frInd=Get-Ind3 $fr; $frText=$fr.Substring($frInd.Length)
    if($f -eq 0){ $rows.Add((New-Object psobject -Property @{txt=$fr;ind=$lead})); continue }
    $curAll=$rows[$rows.Count-1].txt
    $bal=PB3 $curAll
    $isKw=$kwRe.IsMatch($frText); $isCode=$codeRe.IsMatch($frText)
    $cut=$false
    if($bal -gt 0){
      # 括号内续行:不拆
    } elseif($bodyIsComment){
      if($isKw -or $isCode){ $cut=$true }
    } else {
      if($isKw){ $cut=$true }
      else{
        $last=$rows[$rows.Count-1]; $lt=$last.txt
        if($lt.Contains('#')){ if($isCode){$cut=$true} }
        elseif($isCode -and ($lt.TrimEnd().EndsWith(')') -or $lt.TrimEnd().EndsWith(']') -or $lt.TrimEnd().EndsWith('"') -or $lt.TrimEnd().EndsWith('='))){
          $cut=$true
        }
      }
    }
    if($cut){
      $ind= if($frInd.Length){$frInd} else {$rows[$rows.Count-1].ind}
      $rows.Add((New-Object psobject -Property @{txt=$frText;ind=$ind}))
    } else {
      $last=$rows[$rows.Count-1]; $last.txt=$last.txt+$frText
    }
  }
  foreach($o in $rows){ $out.Add($o.ind+$o.txt) }
}
[System.IO.File]::WriteAllLines((Join-Path $src 'Battle.gd.v17'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v17 lines: "+$out.Count)