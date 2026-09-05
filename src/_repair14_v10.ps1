# v10:保守拆行(避免把注释里引用的代码字样误拆)
# 输入 _probe2.txt → Battle.gd.v10
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_probe2.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

# 保留关键字(仅在 这些开头 时才认为开始新代码行)
$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@)'
# 代码行黏连时,cur 完整结束判定
$endRe=[regex]'[\)\]\x22\uFF09]$'

function Has-Hash($s){ return $s.Contains('#') }

$out=New-Object System.Collections.Generic.List[string]
$debug=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  $lead=''; for($j=0;$j -lt $l.Length;$j++){ $c=$l[$j]; if($c -eq "`t" -or $c -eq ' '){$lead+=$c}else{break} }
  $body=$l.Substring($lead.Length)
  $bodyIsComment=$body.TrimStart(" ","`t").StartsWith('#')

  # 片段化
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
    $isNewHash=$ft.StartsWith('#')
    if($isKw -or $isNewHash){
      if($bodyIsComment){
        # 注释行后跟关键字声明/新注释 → 断行(原文件: 注释行\n声明)
        $rows.Add($cur); $cur=$fr
      } elseif(Has-Hash $cur){
        # 代码行含行尾注释,其后再跟语句 → 断行
        $rows.Add($cur); $cur=$fr
      } elseif($endRe.IsMatch($cur.TrimEnd()) -or $cur.TrimEnd().EndsWith('=') -or $cur.TrimEnd() -match '\S$' -and $cur.TrimEnd() -notmatch '[\u4e00-\u9fff]$'){
        # 代码以结尾符号结束且非中文尾部
        $rows.Add($cur); $cur=$fr
      } else { $cur=$cur+$fr }
    } elseif($bodyIsComment){
      # 注释延续(注释里提到代码名或中文)并入
      $cur=$cur+$fr
    } elseif($ft -match '^[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|\[|\.)' -and (Has-Hash $cur) ){
      # 代码+注释 后跟以标识符起始的调用/赋值(联机等场景,如 NetBus.disconnected.connect)
      $rows.Add($cur); $cur=$fr
    } elseif($ft -match '^[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|\[|\.)' -and $endRe.IsMatch($cur.TrimEnd())){
      # 纯代码黏连(上片已完整结束)
      $rows.Add($cur); $cur=$fr
    } else {
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
[System.IO.File]::WriteAllLines("$src\Battle.gd.v10",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_v10_debug.txt",$debug,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v10 lines: "+$out.Count+"  debug: "+$debug.Count)