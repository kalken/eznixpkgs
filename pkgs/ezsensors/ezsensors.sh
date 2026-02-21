#!/usr/bin/env bash

cputemp() {
    local found=0
    shopt -s nullglob

    for i in /sys/class/thermal/thermal_zone*; do
        if [[ -r "$i/temp" ]]; then
            _name=$(basename -- "$i")
            _temp=$(cat "$i/temp")
            if [[ "$_temp" =~ ^[0-9]+$ ]]; then
                # Convert millidegree Celsius to degree Celsius with rounding
                printf '%s: %d°C\n' "$_name" $(( (_temp + 500) / 1000 ))
                found=1
            fi
        fi
    done

    shopt -u nullglob

    if [[ $found -eq 0 ]]; then
        echo "No sensor readings found." >&2
        return 1
    fi
}

# Execute the function when script is run
cputemp
