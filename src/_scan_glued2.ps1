# 扫描并修复:注释('#'后文本)尾部直接黏一行代码(如 var x += 1、_func() 等)的残留
# 特征:行内含 '#',其后的注释文本末尾(无空格分隔或紧贴)出现代码起始,形如:
#   ...注释尾字符 + [A-Za-z_][A-Za-z0-9_]* (\+=|-=|=|\(|;|:) 且前面中文无空格
# 我们列出供人工确认;若上一行注释本身完整,则在其后补换行 + 同缩进代码。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src 'Battle.gd'),[System.Text.Encoding]::UTF8)
$out=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.StartsWith('#')){ continue }  # 整行注释的处理单独看
  $h=$l.IndexOf('#')
  if($h -lt 0){ continue }
  # 注释起点后的内容
  $after=$l.Substring($h+1)
  # 若 after 匹配:中文(或注释结尾标点)直接跟 变量名+运算符(无空格),疑似吞行
  if($after -match '[\u4e00-\u9fff\uFF09\uFF0C\uFF1B]([A-Za-z_][A-Za-z0-9_]*\s*(\+=|-=|\*=|/=|=|\(|\[|;))'){
    $out.Add(("L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(170,$l.Length))))
  }
}
[System.IO.File]::WriteAllLines((Join-Path $src '_glued2.txt'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("glued-code suspects: "+$out.Count)