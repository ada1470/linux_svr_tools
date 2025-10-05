#!/bin/bash

set -e

GREEN="\033[1;32m"
RED="\033[1;31m"
RESET="\033[0m"

show_menu() {
  echo -e "${GREEN}CentOS 7 Repair & Essentials Tool${RESET}"
  echo "----------------------------------"
  echo " 1) Yum update"
  echo " 2) Install EPEL"
  echo " 3) Fix Yum (Aliyun Repo)"
  echo " 4) Fix Firmware Conflict"
  echo " 5) Install htop"
  echo " 6) Install wget"
  echo " 7) Install Python3 & pip"
  echo " 8) Install Node.js"
  echo " 9) Install jq"
  echo "10) Reinstall firewalld"
  echo "11) Repair cron"
  echo "12) Install iostat (sysstat)"
  echo "13) Install Fail2Ban"
  echo "14) Install Nginx"
  echo "15) Install Apache (httpd)"
  echo "16) Install PHP"
  echo "17) Install MySQL"
  echo "18) Install Redis"
  echo " 0) Exit"
  echo "----------------------------------"
}

fix_yum_repo_aliyun() {
  echo -e "${GREEN}Switching to Aliyun Yum repo...${RESET}"
  yum install -y wget
  mkdir -p /etc/yum.repos.d/backup/
  mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
  wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
  yum clean all
  yum makecache
}

fix_firmware_conflict() {
  echo -e "${GREEN}Fixing firmware conflict...${RESET}"
  yum remove -y linux-firmware
  yum install -y iwl7260-firmware
}

install_python3() {
  echo -e "${GREEN}Installing Python 3 & pip...${RESET}"
  yum install -y python3 python3-pip
}

install_nodejs() {
  echo -e "${GREEN}Installing Node.js 16.x...${RESET}"
  curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
  yum install -y nodejs
}

reinstall_firewalld() {
  echo -e "${GREEN}Reinstalling firewalld...${RESET}"
  systemctl stop firewalld || true
  yum remove -y firewalld
  yum install -y firewalld
  systemctl enable firewalld --now
}

repair_cron() {
  echo -e "${GREEN}Repairing cron service...${RESET}"
  yum reinstall -y cronie
  systemctl enable crond --now
}

install_mysql() {
  echo -e "${GREEN}Installing MySQL 5.7 from official repo...${RESET}"
  rpm -Uvh https://repo.mysql.com/mysql57-community-release-el7.rpm
  yum install -y mysql-server
  systemctl enable mysqld --now
}

while true; do
  show_menu
  read -p "Choose an option: " choice
  case $choice in
    1) yum update -y ;;
    2) yum install -y epel-release ;;
    3) fix_yum_repo_aliyun ;;
    4) fix_firmware_conflict ;;
    5) yum install -y htop ;;
    6) yum install -y wget ;;
    7) install_python3 ;;
    8) install_nodejs ;;
    9) yum install -y jq ;;
   10) reinstall_firewalld ;;
   11) repair_cron ;;
   12) yum install -y sysstat ;;
   13) yum install -y fail2ban ;;
   14) yum install -y nginx && systemctl enable nginx --now ;;
   15) yum install -y httpd && systemctl enable httpd --now ;;
   16) yum install -y php php-cli php-fpm php-mysqlnd ;;
   17) install_mysql ;;
   18) yum install -y redis && systemctl enable redis --now ;;
    0) echo "Bye!"; exit 0 ;;
    *) echo -e "${RED}Invalid option.${RESET}" ;;
  esac
  echo -e "\n${GREEN}Done. Press Enter to continue...${RESET}"
  read
done
