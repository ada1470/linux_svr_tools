#!/bin/bash

print_progress_bar() {
    local percent=$1
    local width=50  # width of the bar
    local filled=$((percent * width / 100))

    # Color selection
    if (( percent >= 90 )); then
        color="\e[41m"  # red background
    elif (( percent >= 80 )); then
        color="\e[43m"  # yellow background
    else
        color="\e[42m"  # green background
    fi

    # Start the line
    echo -ne "${percent}% ["

    # Print bar
    for ((i=0; i<width; i++)); do
        if (( i < filled )); then
            echo -ne "${color} \e[0m"
        else
            echo -ne " "
        fi
    done

    echo -e "]"
}

# Example usage
for i in {0..100..10}; do
    print_progress_bar $i
    sleep 0.2
done
