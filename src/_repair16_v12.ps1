# v12:注释行后续片段 若为纯ASCII代码形(无CJK且匹配语句开头)→ 断行;若含中文 → 并入注释
# 输入 _probe2.txt → Battle.gd.v12
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_probe2.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@|#)'
$codeRe=[regex]'^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'

function Has-CJK($s){ foreach($ch in $s.ToCharArray()){ if($ch -ge [int]0x4E00 -and $ch -le [int]0x9FFF){return $true} }; return $false }

$out=New-Object System.Collections.Generic.List[string]
$debug=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  $lead=''; for($j=0;$j -lt $l.Length;$j++){ $c=$l[$j]; if($c -eq "`t" -or $c -eq ' '){$lead+=$c}else{break} }
  $body=$l.Substring($lead.Length)
  $bodyIsComment=$body.TrimStart(" ","`t").StartsWith('#')

  $frags=New-Object System.Collections.Generic.List[string]
  $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length){$frags.Add($sb.ToString())};[void]$sb.Clear() } else {[void]$sb.Append($ch)}
  }
  if($sb.Length){$frags.Add($sb.ToString())}

  $rows=New-Object System.Collections.Generic.List[string]
  $cur=''
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=$frags[$f]; $ft=$fr.TrimStart(" ","`t")
    if($cur.Length -eq 0){ $cur=$fr; continue }
    $isKw=$kwRe.IsMatch($ft)
    $isCode=($codeRe.IsMatch($ft))
    $cjk=Has-CJK $ft
    if($bodyIsComment){
      # 注释行逻辑:后续片段是新行,当它是:
      #  - 保留关键字/新# 注释
      #  - 纯ASCII代码形(无中文)且看起来是语句/调用/赋值  (即注释行之后的代码行)
      if($isKw){ $rows.Add($cur); $cur=$fr }
      elseif($isCode -and -not $cjk -and $cur.TrimEnd().Length -gt 0){
        $rows.Add($cur); $cur=$fr
      } else { $cur=$cur+$fr }   # 中文延续/注释里提代码名
    } else {
      # 代码行逻辑
      if($isKw){ $rows.Add($cur); $cur=$fr; continue }
      if($cur.Contains('#') -and ($isCode -or $isKw)){ $rows.Add($cur); $cur=$fr; continue }
      if($isCode -and -not $cjk -and $cur.TrimEnd() -match '[\)\]\x22\uFF09]$'){
        $rows.Add($cur); $cur=$fr; continue
      }
      $cur=$cur+$fr
    }
  }
  if($cur.Length){$rows.Add($cur)}
  if($rows.Count -eq 0){$rows.Add('')}
  foreach($r in $rows){ $out.Add($lead+$r) }
  if($rows.Count -gt 1){
    $debug.Add(("--- L{0} rows={1}" -f ($i+1),$rows.Count))
    $debug.Add("   "+$l)
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v12",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v12 lines: "+$out.Count+"  splits: "+$debug.Count)