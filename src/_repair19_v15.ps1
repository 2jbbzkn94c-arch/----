# v15:括号感知拆行 —— 有未闭合括号时一律续行,避免把表达式内部(三元if等)误拆
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src '_probe2.txt'),[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

function Get-Ind2($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq [char]9 -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }
function HasCJK2($s){ foreach($ch in $s.ToCharArray()){ $v=[int]$ch; if($v -ge 0x4E00 -and $v -le 0x9FFF){return $true} }; return $false }

# 括号平衡(注释外、字符串外);返回: 剩余未闭合 '(' '[' 数
function ParenBalance($s){
  $inS=$false;$com=$false;$bal=0
  for($j=0;$j -lt $s.Length;$j++){
    $c=$s[$j]
    if($com){break}
    if($c -eq '"'){ $inS=-not $inS; continue }
    if($c -eq '#' -and -not $inS){$com=$true; continue}
    if(-not $inS){
      if($c -eq '('){$bal++}
      elseif($c -eq ')'){$bal--}
      elseif($c -eq '['){$bal+=10}
      elseif($c -eq ']'){$bal-=10}
    }
  }
  return $bal
}

$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@|#)'
$codeRe=[regex]'^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'

$out=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $hasMark=$false
  for($j=0;$j -lt $l.Length;$j++){ if($l[$j] -eq $BAD -or $l[$j] -eq $Q){$hasMark=$true;break} }
  if(-not $hasMark){ $out.Add($l); continue }
  $lead=Get-Ind2 $l
  $body=$l.Substring($lead.Length)

  $frags=New-Object 'System.Collections.Generic.List[object]'
  $sb=New-Object System.Text.StringBuilder
  for($j=0;$j -lt $body.Length;$j++){
    $ch=$body[$j]
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length){$frags.Add($sb.ToString());[void]$sb.Clear()} }
    else {[void]$sb.Append($ch)}
  }
  if($sb.Length){$frags.Add($sb.ToString())}
  if($frags.Count -eq 0){ $out.Add($l); continue }

  $bodyIsComment=$frags[0].TrimStart(" ","`t").StartsWith('#')
  $rowFrags=New-Object 'System.Collections.Generic.List[object]'
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=[string]$frags[$f]
    $frInd=Get-Ind2 $fr
    $frText=$fr.Substring($frInd.Length)
    if($f -eq 0){ $o=New-Object psobject -Property @{txt=$fr;ind=$lead}; $rowFrags.Add($o); continue }
    # 当前累积行文本
    $curAll=($rowFrags | ForEach-Object { $_.txt }) -join ''
    $bal=ParenBalance $curAll
    $isKw=$kwRe.IsMatch($frText)
    $isCode=$codeRe.IsMatch($frText)
    $cjk=HasCJK2 $frText
    $isCommentStart=$frText.TrimStart().StartsWith('#')
    $cut=$false
    if($bal -gt 0){
      # 表达式续行:不拆
    } elseif($bodyIsComment){
      if($isKw -or $isCommentStart){ $cut=$true }
      elseif($isCode -and -not $cjk){ $cut=$true }
    } else {
      if($isKw -or $isCommentStart){ $cut=$true }
      else {
        $last=$rowFrags[$rowFrags.Count-1]; $ltxt=$last.txt
        if($ltxt.Contains('#')){ if($isCode){$cut=$true} }
        elseif($isCode -and -not $cjk -and ($ltxt.TrimEnd().EndsWith(')') -or $ltxt.TrimEnd().EndsWith(']') -or $ltxt.TrimEnd().EndsWith('"'))){
          $cut=$true
        }
      }
    }
    if($cut){
      $ind=''
      if($frInd.Length){ $ind=$frInd }
      else { $ind=$rowFrags[$rowFrags.Count-1].ind }
      $rowFrags.Add((New-Object psobject -Property @{txt=$frText;ind=$ind}))
    } else {
      $last=$rowFrags[$rowFrags.Count-1]; $last.txt=$last.txt+$frText
    }
  }
  foreach($o in $rowFrags){ $out.Add($o.ind+$o.txt) }
}
[System.IO.File]::WriteAllLines((Join-Path $src 'Battle.gd.v15'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v15 lines: "+$out.Count)