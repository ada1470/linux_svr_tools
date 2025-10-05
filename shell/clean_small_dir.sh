#!/bin/bash

ROOT_DIR="/home/www/wwwroot"
LIMIT_KB=2
LIMIT_BYTES=$((LIMIT_KB * 1024))

declare -a DELETE_LIST

# Print table header
printf "\n%-40s | %10s | %10s\n" "Directory" "Files" "Size"
printf -- "------------------------------------------+------------+------------\n"

for dir in "$ROOT_DIR"/*/; do
  found_large=0
  file_count=0
  total_size=0

  # Find files in dir and its immediate subdirs only (maxdepth=2), not deeper
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    size=$(stat -c%s "$file")
    if [ "$size" -ge "$LIMIT_BYTES" ]; then
      found_large=1
      break
    fi
    total_size=$((total_size + size))
    file_count=$((file_count + 1))
  done < <(find "$dir" -maxdepth 2 -type f -print0)

  if [ "$found_large" -eq 0 ]; then
    hr_size=$(numfmt --to=iec-i --suffix=B <<< "$total_size")
    printf "%-40s | %10d | %10s\n" "$dir" "$file_count" "$hr_size"
    DELETE_LIST+=("$dir")
  fi
done

# Prompt to delete
if [ "${#DELETE_LIST[@]}" -gt 0 ]; then
  echo -e "\n⚠️  ${#DELETE_LIST[@]} folder(s) eligible for deletion."
  read -p "❓ Do you want to delete them? (y/N): " confirm

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    for d in "${DELETE_LIST[@]}"; do
      # Remove immutable flags if needed
        find "$d" -exec chattr -i {} + 2>/dev/null
        rm -rf "$d"

      echo "🗑️  Deleted: $d"
    done
  else
    echo "❌ No folders were deleted."
  fi
else
  echo -e "\n✅ No folders matched the criteria for deletion."
fi
