mkdir -p /www/wwwlogs/scan
time=$(date +"%Y-%m-%d_%H%M")
scanned_file="/www/wwwlogs/scan/backdoor_wwwlogs_$time.log"
patterns='base64_decode|str_rot13|hex2bin|rmdir|chr|gzinflate|@require|stream_context_create|create_function|str_ireplace|error_reporting\(0\)|curl_exec|\$_REQUEST|eval\(|000000|gzuncompress|fwrite|fread|readfile|convert_cyr_string'

echo "Scanning . . ."
find /home/www/wwwroot/ -maxdepth 6 -type f -size 1M -not -path "*/cache/*" -not -path "*/runtime/*" -not -path "*/log/*" -not -path "*/upload/*" -not -name "*.js" -not -name "*.html" -not -name "*.txt" -not -name "*.svg" -not -name "*.css" -not -name "*.xml" -not -name "*.m3u8"  -not -name "*.ts" -exec egrep -lHI "$patterns" {} + | while read file; do
  echo "Processing: $file"
  egrep -o "(.{0,100})($patterns)(.{0,100})" "$file" | sed "s#^#$file::\t#" >> $scanned_file
done
echo "Scanning done"

# double-escape special characters ((, ), $, \) for AWK expects POSIX regular expressions

patterns='base64_decode|str_rot13|hex2bin|rmdir|chr|gzinflate|@require|stream_context_create|create_function|str_ireplace|error_reporting|curl_exec|\\$_REQUEST|eval|000000|gzuncompress|fwrite|fread|readfile|convert_cyr_string'

output_file="/www/wwwlogs/scan/backdoor_summary_$time.log"

echo "Analyzing the scanned log..."
awk -v pat="$patterns" -F'::' '
BEGIN {
  n = split(pat, kw, "|")
  header = sprintf("%-70s | %-6s | %s\n", "File", "Count", "Matched Keywords")
  sep = gensub(/./, "-", "g", sprintf("%-70s | %-6s | %s", "", "", ""))
  print header
  print sep
}
{
  file = $1
  code = $2
  for (i = 1; i <= n; i++) {
    if (code ~ kw[i]) {
      seen[file][kw[i]] = 1
    }
  }
}
END {
  found = 0
  for (f in seen) {
    count = 0
    keywords = ""
    for (k in seen[f]) {
      count++
      keywords = keywords (keywords == "" ? "" : ", ") k
    }
    if (count >= 3) {
      printf "%-70s | %-6d | %s\n", f, count, keywords
      found = 1
    }
  }
  if (found == 0) {
    print "Not found any potential malicious file in the log."
  }
}' /www/wwwlogs/scan/backdoor_wwwlogs_$time.log | tee "$output_file"

echo "Analyzing done"
echo "Scanned file path: $scanned_file"
echo "Analyzed file path: $output_file"