#!/bin/bash

# Check for --skip-scan flag
skip_scan=false
for arg in "$@"; do
  if [ "$arg" == "--skip-scan" ]; then
    skip_scan=true
    break
  fi
done

mkdir -p /www/wwwlogs/scan
time=$(date +"%Y-%m-%d_%H%M")

# SCANNING 

if [ "$skip_scan" = false ]; then
  scanned_file="/www/wwwlogs/scan/backdoor_wwwlogs_$time.log"
  patterns='base64_decode|str_rot13|hex2bin|rmdir|chr|gzinflate|@require|stream_context_create|create_function|str_ireplace|error_reporting\(0\)|curl_exec|\$_REQUEST|eval\(|000000|gzuncompress|fwrite|fread|readfile|convert_cyr_string|SameSite|xxSJRox'

  echo "Scanning . . ."
  find /home/www/wwwroot/ -maxdepth 6 -type f -size 1M \
    -not -path "*/cache/*" -not -path "*/runtime/*" -not -path "*/log/*" -not -path "*/logs/*" \
    -not -path "*/title_url/*" -not -path "*/node_modules/*" -not -path "*/videos/*" \
    -not -name "*.tar.gz" -not -name "*.sql" -not -name "*.txt" \
    -not -name "*.js" -not -name "*.html" \
    -not -name "*.svg" -not -name "*.css" -not -name "*.xml" -not -name "*.m3u8" \
    -not -name "*.ts" -exec egrep -lHI "$patterns" {} + | while read file; do
      echo "Processing: $file"
      egrep -o "(.{0,100})($patterns)(.{0,100})" "$file" | sed "s#^#$file::\t#" >> "$scanned_file"
    done
    
  echo "Scanning done"
else
  # Get latest scan log file
  scanned_file=$(ls -t /www/wwwlogs/scan/backdoor_wwwlogs_*.log 2>/dev/null | head -n 1)
  if [ -z "$scanned_file" ]; then
    echo "No existing scan logs found. Exiting."
    exit 1
  fi
  echo "Skipping scan. Using latest log file: $scanned_file"
fi

# ANALYSIS

# For AWK analysis
patterns='base64_decode|str_rot13|hex2bin|rmdir|chr|gzinflate|@require|stream_context_create|create_function|str_ireplace|error_reporting|curl_exec|\\$_REQUEST|eval|000000|gzuncompress|fwrite|fread|readfile|convert_cyr_string'
output_file="/www/wwwlogs/scan/backdoor_summary_$time.log"

echo "----------------------------------------------------------------------------------";
echo "Analyzing the scanned log..."
echo "File location: $scanned_file"
echo "----------------------------------------------------------------------------------";
awk -v pat="$patterns" -F'::' '
BEGIN {
  n = split(pat, kw, "|")
  split("base64_decode,eval,gzuncompress", critical, ",")
  split("str_rot13,hex2bin,gzinflate|xxSJRox", min1, ",")
  for (i in critical) crit[critical[i]] = 1
  for (i in min1) lowcrit[min1[i]] = 1

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
      key = file ":" kw[i]
      seen[key] = 1
      if (kw[i] in crit) crit_seen[file ":" kw[i]] = 1
      if (kw[i] in lowcrit) low_seen[file ":" kw[i]] = 1
    }
  }
}
END {
  for (f_kw in seen) {
    split(f_kw, parts, ":")
    f = parts[1]
    kwd = parts[2]
    files[f] = 1
    file_kw[f][kwd] = 1
  }

  found = 0
  for (f in files) {
    count = 0
    keywords = ""
    for (k in file_kw[f]) {
      count++
      keywords = keywords (keywords == "" ? "" : ", ") k
    }

    crit_count = 0
    low_count = 0
    for (k in crit_seen) {
      split(k, p, ":")
      if (p[1] == f) crit_count++
    }
    for (k in low_seen) {
      split(k, p, ":")
      if (p[1] == f) low_count++
    }

    if (count >= 3 || crit_count >= 2 || low_count >= 1) {
      printf "%-70s | %-6d | %s\n", f, count, keywords
      found = 1
    }
  }

  if (found == 0) {
    print "Not found any potential malicious file in the log."
  }
}' "$scanned_file" | tee "$output_file"

echo "----------------------------------------------------------------------------------";
# Summary
echo "Analyzing done"
echo "Scanned file path: $scanned_file"
echo "Analyzed file path: $output_file"
echo "----------------------------------------------------------------------------------";
