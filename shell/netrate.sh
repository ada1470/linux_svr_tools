#!/bin/bash

# Detect active interface (exclude loopback and down interfaces)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | while read i; do
    RX=$(cat /sys/class/net/$i/statistics/rx_bytes)
    TX=$(cat /sys/class/net/$i/statistics/tx_bytes)
    [[ $RX -gt 0 || $TX -gt 0 ]] && echo "$i" && break
done)

if [[ -z "$IFACE" ]]; then
    echo "No active network interface found."
    exit 1
fi

# Read RX/TX before sleep
RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
sleep 1
# Read RX/TX after 1 second
RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)

# Calculate difference in KB
RX_RATE=$(( (RX2 - RX1) / 1024 ))
TX_RATE=$(( (TX2 - TX1) / 1024 ))

echo "Interface: $IFACE"
echo "Inbound : $RX_RATE KB/s"
echo "Outbound: $TX_RATE KB/s"
