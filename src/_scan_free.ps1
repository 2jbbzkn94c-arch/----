# 扫描游离注释碎片:不以#开头、但整行像"注释文本后半段"(含中文、无代码结构)
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src 'Battle.gd'),[System.Text.Encoding]::UTF8)
$out=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.Length -eq 0){continue}
  if($t.StartsWith('#')){continue}
  # 判断是否是"纯中文注释尾巴": 去引号/括号/运算符后仍以中文收尾且整体不像语句
  $noStr=$l -replace '"[^"]*"',''
  $codeish=$noStr -match ':=|=|\(|\)|\[|\]|\b(var|if|for|while|return|func|emit|\.|,|:)'
  $hasCn = $l -match '[\u4e00-\u9fff]'
  if($hasCn -and -not $codeish){
    # 可能是注释尾巴
    $out.Add(("L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(130,$l.Length))))
  }
}
[System.IO.File]::WriteAllLines((Join-Path $src '_free.txt'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("free-floating comment tails: "+$out.Count)