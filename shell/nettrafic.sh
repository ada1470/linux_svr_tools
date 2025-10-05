#!/bin/bash
# net_traffic.sh

IFACE=$(awk 'NR>2 && $1 !~ /lo:/ && $2 > 0 {gsub(":", "", $1); print $1; exit}' /proc/net/dev)

read RX1 TX1 < <(awk -v iface="$IFACE" '$1 ~ iface":" {print $2, $10}' /proc/net/dev)
sleep 1
read RX2 TX2 < <(awk -v iface="$IFACE" '$1 ~ iface":" {print $2, $10}' /proc/net/dev)

RX_RATE=$(( (RX2 - RX1) / 1024 ))
TX_RATE=$(( (TX2 - TX1) / 1024 ))

echo "Interface : $IFACE"
echo "Inbound   : $RX_RATE KB/s"
echo "Outbound  : $TX_RATE KB/s"
