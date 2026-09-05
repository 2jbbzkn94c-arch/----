# v11:修复 v10 注释行吞代码问题;注释行遇完整语句/新注释 → 断行;遇中文解释 → 并入
# 输入 _probe2.txt → Battle.gd.v11
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_probe2.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

# 片段若以 保留关键字 开头
$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@|#)'
# 片段若形如 代码语句开头: identifier( / identifier:= / identifier= / identifier[ / identifier. 且后面不是纯中文解释
$codeRe=[regex]'^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'
# 片段以制表符开头(原行缩进痕迹)
function Is-Tabbed($s){ return $s.StartsWith("`t") }

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
    $isCode=$codeRe.IsMatch($ft)
    # 若是注释行:后续 关键字/注释 → 断;标识符代码且带tab缩进 → 断;否则并入
    if($bodyIsComment){
      if($isKw){ $rows.Add($cur); $cur=$fr }
      elseif($isCode -and (Is-Tabbed $fr)){ $rows.Add($cur); $cur=$fr }
      elseif($isCode -and $cur -notmatch '[\u4e00-\u9fff]$' -and $cur.TrimEnd() -match '[\)\]\x22]$'){
        # 注释以代码风格收尾(如伪代码)+ 代码续 → 断(少见,保守)
        $rows.Add($cur); $cur=$fr
      } else { $cur=$cur+$fr }
    } else {
      # 代码行:后跟 关键字/注释 → 断
      if($isKw){ $rows.Add($cur); $cur=$fr; continue }
      if($cur.Contains('#') -and ($isCode -or $isKw)){
        $rows.Add($cur); $cur=$fr; continue
      }
      # 纯代码黏连:cur 完整结束且 fr 是代码
      if($isCode -and $cur.TrimEnd() -match '[\)\]\x22\uFF09]$'){
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
[System.IO.File]::WriteAllLines("$src\Battle.gd.v11",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v11 lines: "+$out.Count+"  splits: "+$debug.Count)