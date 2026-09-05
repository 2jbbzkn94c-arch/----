# v6 后处理审查:输出所有仍可疑(可能拆错/合并残留)的行
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v6",[System.Text.Encoding]::UTF8)
$out=New-Object System.Collections.Generic.List[string]

# 1) 一行内出现两个顶层语句起点(缩进级别相同,非注释区)
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $code=$l
  $h=$code.IndexOf('#'); if($h -ge 0){$code=$code.Substring(0,$h)}
  # 统计缩进后的第一个单词
  if($code -match '(^|[^A-Za-z0-9_])(var |const |signal |func |return |break |continue |if |for |while |else)'){}
  # 找两个不同的语句起始(第二个出现在引号外很难判,粗判:出现 '  var ' 两次,或 '  return ' 两次等)
  $m=[regex]::Matches($code,'(var |const |signal |func |return |break |continue |if |for |while )')
  if($m.Count -ge 2){
    # 排除合法三元/比较中含 if/for? 要求第二个前面有 "    " 或行内;仅作提示
    $out.Add(("P L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(130,$l.Length))))
  }
}
# 2) 注释行内疑似藏着代码(以#开头,但后部含 'var xxx :=', 'func ' 等,且不是同句解释)? 保守列出供人看
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]; $t=$l.Trim()
  if($t.StartsWith('#') -and ($t -match '\b(var|func|signal|class|const|if|for|while|return)\s+[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|:)')){
    $out.Add(("CM L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(150,$l.Length))))
  }
}
[System.IO.File]::WriteAllLines("$src\_v6_issues2.txt",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("suspicious lines: "+$out.Count)
$out | Select-Object -First 80 | ForEach-Object { Write-Output $_ }