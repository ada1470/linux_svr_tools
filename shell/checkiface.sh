#!/bin/bash

echo "Checking active network interfaces..."

# Get list of interfaces (excluding loopback and virtual interfaces)
interfaces=$(ls /sys/class/net | grep -vE 'lo|docker|veth|br|virbr')

for iface in $interfaces; do
    # Check if interface is UP
    state=$(cat /sys/class/net/$iface/operstate)
    
    # Get RX and TX bytes
    rx_bytes=$(cat /sys/class/net/$iface/statistics/rx_bytes)
    tx_bytes=$(cat /sys/class/net/$iface/statistics/tx_bytes)

    if [[ "$state" == "up" && ( "$rx_bytes" -gt 0 || "$tx_bytes" -gt 0 ) ]]; then
        echo "Active Interface: $iface"
        echo "  State: $state"
        echo "  RX Bytes: $rx_bytes"
        echo "  TX Bytes: $tx_bytes"
    fi
done
