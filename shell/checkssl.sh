#!/bin/bash
# At top of your script
export LANG=en_US.UTF-8

CERT_DIR="/www/server/panel/vhost/cert"
TODAY=$(date +%s)

# Color codes
RED="\033[31m"
YELLOW="\033[33m"
GREEN="\033[32m"
RESET="\033[0m"

# Column widths
WIDTH_DOMAIN=35
WIDTH_DATE=28
WIDTH_DAYS=12
WIDTH_STATUS=10

draw_line() {
  local left="$1" mid="$2" right="$3"
  local fill="─"

  # For each column, print WIDTH + 2 horizontal lines
  printf "%s" "$left"
  printf "%$((WIDTH_DOMAIN + 2))s" "" | sed "s/ /$fill/g"
  printf "%s" "$mid"
  printf "%$((WIDTH_DATE + 2))s" "" | sed "s/ /$fill/g"
  printf "%s" "$mid"
  printf "%$((WIDTH_DAYS + 2))s" "" | sed "s/ /$fill/g"
  printf "%s" "$mid"
  printf "%$((WIDTH_STATUS + 2))s" "" | sed "s/ /$fill/g"
  printf "%s\n" "$right"
}




# Array for summary
expired_or_soon_domains=()

# Header
draw_line "┌" "┬" "┐"
printf "│ %-*s │ %-*s │ %-*s │ %-*s │\n" \
  $WIDTH_DOMAIN "Domain" \
  $WIDTH_DATE "Expiry Date" \
  $WIDTH_DAYS "Days Left" \
  $WIDTH_STATUS "Status"
draw_line "├" "┼" "┤"

# Main loop
for domain in "$CERT_DIR"/*; do
  [ -d "$domain" ] || continue
  domain_name=$(basename "$domain")

  cert_file="$domain/fullchain.pem"
  [ -f "$cert_file" ] || cert_file="$domain/cert.pem"

  if [ ! -f "$cert_file" ]; then
    printf "${RED}│ %-*s │ %-*s │ %-*s │ %-*s │${RESET}\n" \
      $WIDTH_DOMAIN "$domain_name" \
      $WIDTH_DATE "No cert found" \
      $WIDTH_DAYS "-" \
      $WIDTH_STATUS "Missing"
    expired_or_soon_domains+=("$domain_name (Missing)")
    continue
  fi

  expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
  expiry_ts=$(date -d "$expiry_date" +%s 2>/dev/null)

  if [ -z "$expiry_ts" ]; then
    printf "${RED}│ %-*s │ %-*s │ %-*s │ %-*s │${RESET}\n" \
      $WIDTH_DOMAIN "$domain_name" \
      $WIDTH_DATE "Invalid cert" \
      $WIDTH_DAYS "-" \
      $WIDTH_STATUS "Error"
    expired_or_soon_domains+=("$domain_name (Invalid)")
    continue
  fi

  days_left=$(( (expiry_ts - TODAY) / 86400 ))

  if (( days_left < 0 )); then
    printf "${RED}│ %-*s │ %-*s │ %-*s │ %-*s │${RESET}\n" \
      $WIDTH_DOMAIN "$domain_name" \
      $WIDTH_DATE "$expiry_date" \
      $WIDTH_DAYS "$days_left" \
      $WIDTH_STATUS "Expired"
    expired_or_soon_domains+=("$domain_name (Expired)")
  elif (( days_left <= 15 )); then
    printf "${YELLOW}│ %-*s │ %-*s │ %-*s │ %-*s │${RESET}\n" \
      $WIDTH_DOMAIN "$domain_name" \
      $WIDTH_DATE "$expiry_date" \
      $WIDTH_DAYS "$days_left" \
      $WIDTH_STATUS "Soon"
    expired_or_soon_domains+=("$domain_name (Soon)")
  else
    printf "│ %-*s │ %-*s │ %-*s │ ${GREEN}%-*s${RESET} │\n" \
      $WIDTH_DOMAIN "$domain_name" \
      $WIDTH_DATE "$expiry_date" \
      $WIDTH_DAYS "$days_left" \
      $WIDTH_STATUS "Valid"
  fi
done

# Footer
draw_line "└" "┴" "┘"

# Summary
if [ ${#expired_or_soon_domains[@]} -gt 0 ]; then
  echo -e "\n🔎 Domains with expired, soon-to-expire, or invalid certificates:"
  for d in "${expired_or_soon_domains[@]}"; do
    echo " - $d"
  done
fi
