# v14 精简健壮版:拆行引擎
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src '_probe2.txt'),[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

function Get-Indent2($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq [char]9 -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }

function Has-CJK2($s){ foreach($ch in $s.ToCharArray()){ $v=[int]$ch; if($v -ge 0x4E00 -and $v -le 0x9FFF){return $true} }; return $false }

$out=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $hasMark=$false
  for($j=0;$j -lt $l.Length;$j++){ if($l[$j] -eq $BAD -or $l[$j] -eq $Q){$hasMark=$true;break} }
  if(-not $hasMark){ $out.Add($l); continue }
  $lead=Get-Indent2 $l
  $body=$l.Substring($lead.Length)
  # 切片段
  $frags=New-Object 'System.Collections.Generic.List[object]'
  $sb=New-Object System.Text.StringBuilder
  for($j=0;$j -lt $body.Length;$j++){
    $ch=$body[$j]
    if($ch -eq $BAD -or $ch -eq $Q){
      if($sb.Length -gt 0){ $frags.Add($sb.ToString()); [void]$sb.Clear() }
    } else { [void]$sb.Append($ch) }
  }
  if($sb.Length -gt 0){ $frags.Add($sb.ToString()) }
  if($frags.Count -eq 0){ $out.Add($l); continue }

  $bodyIsComment = $frags[0].TrimStart(" ","`t").StartsWith('#')
  # 逐片段组装逻辑行。逻辑行 = list of fragments to join (strings)
  $rowFrags=New-Object 'System.Collections.Generic.List[object]'  # each: hashtable t,ind (frag text w/o own indent, indent)
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=[string]$frags[$f]
    $frInd=Get-Indent2 $fr
    $frText=$fr.Substring($frInd.Length)
    $isCommentStart=$frText.TrimStart().StartsWith('#')
    $isKw=$false; $isCode=$false
    if($frText -match '^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@)'){ $isKw=$true }
    if($frText -match '^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'){ $isCode=$true }
    $cjk=Has-CJK2 $frText
    if($f -eq 0){
      $o=New-Object psobject -Property @{ txt=$fr; ind=$lead }
      $rowFrags.Add($o)
      continue
    }
    # 决定是否断行
    $cut=$false
    if($bodyIsComment){
      if($isKw -or $isCommentStart){ $cut=$true }
      elseif($isCode -and -not $cjk){ $cut=$true }
    } else {
      if($isKw -or $isCommentStart){ $cut=$true }
      else {
        $last=$rowFrags[$rowFrags.Count-1]
        $ltxt=$last.txt
        $lastHasComment=$ltxt.Contains('#')
        $lastEnds=$ltxt.TrimEnd()
        if($lastHasComment){ if($isCode){ $cut=$true } }
        elseif($isCode -and -not $cjk -and ($lastEnds.EndsWith(')') -or $lastEnds.EndsWith(']') -or $lastEnds.EndsWith('"'))){
          $cut=$true
        }
      }
    }
    if($cut){
      $ind=''
      if($frInd.Length -gt 0){ $ind=$frInd }
      elseif($rowFrags.Count -gt 0){ $ind=$rowFrags[$rowFrags.Count-1].ind }
      $o=New-Object psobject -Property @{ txt=$frText; ind=$ind }
      $rowFrags.Add($o)
    } else {
      # 并入上一行(注释延续/续行)
      $last=$rowFrags[$rowFrags.Count-1]
      $last.txt=$last.txt+$frText
    }
  }
  foreach($o in $rowFrags){ $out.Add($o.ind+$o.txt) }
}
[System.IO.File]::WriteAllLines((Join-Path $src 'Battle.gd.v14'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v14 lines: "+$out.Count)