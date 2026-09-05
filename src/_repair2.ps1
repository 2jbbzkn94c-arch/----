# Battle.gd repair engine — PASS 2 : split merged lines back at statement boundaries.
# Reads _pass1_joined.txt (fragments already rejoined without markers).
# We split using a *line-aware* scanner: we re-parse each physical line's fragment list and,
# for each boundary between fragments, decide whether a NEWLINE belonged there.
# Indentation of a following fragment is inherited from the fragment list structure:
#   - if previous fragment is a full-line comment ending (or the code just before), same indent.
# We primarily reconstruct by scanning token stream and "re-flowing" lines: we need real GDScript-aware
# logic, so keep this file as the DEV sandbox.  Run interactively.

$src = 'D:\Game creating\战旗\src'
$lines = [System.IO.File]::ReadAllLines("$src\_pass1_joined.txt", [System.Text.Encoding]::UTF8)

# Known statement-initial tokens (word boundary) used to propose a line start.
$START = '^(var|const|func|signal|class|extends|enum|static|if|elif|else|for|while|match|return|await|break|continue|pass|@|\b[A-Za-z_][A-Za-z0-9_]*\s*(\:=|=|\(|\.|\[)|#)'
$startRe = [regex]$START

$sample = $lines | Select-Object -Skip 0 -First 120
$si = 0
for ($n = 0; $n -lt $sample.Count; $n++) {
  $l = $sample[$n]
  if (-not ($l.Contains([char]0xFFFD) -or $l.Contains([char]0x3F))) { continue }
  $si++
  Write-Output ("### L" + ($n+1) + " : " + $l.Substring(0, [Math]::Min(150, $l.Length)))
  if ($si -ge 12) { break }
}
Write-Output "done sample"
