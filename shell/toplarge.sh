#!/bin/bash

if [ $# -lt 1 ]; then
  echo "Usage: $0 <directory> [target_size_kb] [-p]"
  exit 1
fi

directory_to_search="$1"
# Set a default target size if not provided
target_size_kb=${2:-1000000}
print_progress=false

# Check for the -p flag (progress flag)
if [ "$3" == "-p" ]; then
  print_progress=true
fi

# Function to estimate the directory size in kilobytes
estimate_directory_size_kb() {
  local total_size_kb=0
  for item in "$1"/*; do
    if [ -d "$item" ]; then
        for child_item in "$item"/*; do
        
        
       if [ "$print_progress" = true ]; then
        echo -ne "\rProcessing: $child_item" >&2 # Print processing message to stderr
      fi

        
          local size_kb=$(du -sk "$child_item" | cut -f1)
          total_size_kb=$((total_size_kb + size_kb))
          
          
          if [ "$total_size_kb" -ge "$target_size_kb" ]; then
         
            break
          fi
        done
    fi
  done
  echo "$total_size_kb"
}

# Function to display colored output
show_colored_output() {
  local size_kb=$1
  if [ "$size_kb" -eq 0 ]; then
    echo -e "\e[93m$size_kb KB\e[0m"  # Yellow
  elif [ "$size_kb" -gt "$target_size_kb" ]; then
    echo -e "\e[91m$size_kb KB\e[0m"  # Red
  else
    echo -e "\e[92m$size_kb KB\e[0m"  # Green
  fi
}

# Check if the specified directory exists
if [ ! -d "$directory_to_search" ]; then
  echo "Directory not found: $directory_to_search"
  exit 1
fi

# Loop through directories in the specified directory
for dir in "$directory_to_search"/*; do
  if [ -d "$dir" ]; then
  
    estimated_size_kb=$(estimate_directory_size_kb "$dir")
    echo "$(basename "$dir"): (Estimated size) $(show_colored_output $estimated_size_kb)"
    
    if [ "$estimated_size_kb" -ge "$target_size_kb" ]; then
      continue
    fi
    
    size_kb=$(du -sk "$dir" | cut -f1)
    
    if [ "$estimated_size_kb" -ne "$size_kb" ]; then
        echo "$(basename "$dir"): $(show_colored_output $size_kb)"
    fi
  fi
done
