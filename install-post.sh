#!/bin/bash
################################################################################
# This is property of eXtremeSHOK.com
# You are free to use, modify and distribute, however you may not remove this notice.
# Copyright (c) Adrian Jon Kriel :: admin@extremeshok.com
################################################################################
#
# Script updates can be found at: https://github.com/extremeshok/xshok-proxmox
#
# post-installation script for Proxmox
#
# License: BSD (Berkeley Software Distribution)
#
################################################################################
#
# Assumptions: proxmox installed
#
################################################################################
#
#    THERE ARE NO USER CONFIGURABLE OPTIONS IN THIS SCRIPT
#
################################################################################

## disable enterprise proxmox repo
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  echo -e "#deb https://enterprise.proxmox.com/debian/pve stretch pve-enterprise\n" > /etc/apt/sources.list.d/pve-enterprise.list
fi
## enable public proxmox repo
if [ ! -f /etc/apt/sources.list.d/pve-public-repo.list ] && [ ! -f /etc/apt/sources.list.d/pve-install-repo.list ] ; then
  echo -e "deb http://download.proxmox.com/debian/pve stretch pve-no-subscription\n" > /etc/apt/sources.list.d/pve-public-repo.list
fi

## Add non-free to sources
sed -i "s/main\( contrib\)\?$/main contrib non-free/g" /etc/apt/sources.list

## Refresh the package lists
apt-get update

## Fix no public key error for debian repo
apt-get install -y debian-archive-keyring

## Update proxmox and install various system utils
apt-get -y dist-upgrade # --force-yes

pveam update

## Fix no public key error for debian repo
# apt-get -y install debian-archive-keyring

## Remove no longer required packages and purge old cached updates
apt-get -y autoremove
apt-get -y autoclean

## Install openvswitch for a virtual internal network
apt-get install -y openvswitch-switch

## Install zfs support, appears to be missing on some Proxmox installs.
apt-get install -y zfsutils

## Install missing ksmtuned
apt-get install -y ksmtuned
systemctl enable ksmtuned

# ## Install the latest ceph provided by proxmox
echo y | pveceph install --version luminous

## Install common system utilities
apt-get install -y whois omping wget axel nano pigz net-tools htop iptraf iotop iftop iperf vim vim-nox screen unzip zip software-properties-common aptitude curl dos2unix dialog mlocate build-essential git
#snmpd snmp-mibs-downloader

## Remove conflicting utilities
apt-get purge -y ntp openntpd chrony

## Detect AMD EPYC CPU and install kernel 4.15
if [ "$(cat /proc/cpuinfo | grep -i -m 1 "model name" | grep -i "EPYC")" != "" ]; then
  echo "AMD EPYC detected"
  #Apply EPYC fix to kernel : Fixes random crashing and instability
  if ! cat /etc/default/grub | grep "GRUB_CMDLINE_LINUX_DEFAULT" | grep -q "idle=nomwait" ; then
    echo "Setting kernel idle=nomwait"
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="idle=nomwait /g' /etc/default/grub
    update-grub
  fi
  echo "Installing kernel 4.15"
  apt-get install -y pve-kernel-4.15
fi

## Install kexec, allows for quick reboots into the latest updated kernel set as primary in the boot-loader.
# use command 'reboot-quick'
echo "kexec-tools kexec-tools/load_kexec boolean false" | debconf-set-selections
apt-get install -y kexec-tools

cat > /etc/systemd/system/kexec-pve.service <<EOF
[Unit]
Description=boot into into the latest pve kernel set as primary in the boot-loader
Documentation=man:kexec(8)
DefaultDependencies=no
Before=shutdown.target umount.target final.target

[Service]
Type=oneshot
ExecStart=/sbin/kexec -l /boot/pve/vmlinuz --initrd=/boot/pve/initrd.img --reuse-cmdline

[Install]
WantedBy=kexec.target
EOF
systemctl enable kexec-pve.service
echo "alias reboot-quick='systemctl kexec'" >> /root/.bash_profile

## Remove no longer required packages and purge old cached updates
apt-get autoremove -y
apt-get autoclean -y

## Disable portmapper / rpcbind (security)
systemctl disable rpcbind
systemctl stop rpcbind

## Set Timezone to UTC and enable NTP
timedatectl set-timezone UTC
echo > /etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=2048
EOF
service systemd-timesyncd start
timedatectl set-ntp true

## Set pigz to replace gzip, 2x faster gzip compression
cat > /bin/pigzwrapper <<EOF
#!/bin/sh
PATH=/bin:\$PATH
GZIP="-1"
exec /usr/bin/pigz "\$@"
EOF
mv -f /bin/gzip /bin/gzip.original
cp -f /bin/pigzwrapper /bin/gzip
chmod +x /bin/pigzwrapper
chmod +x /bin/gzip

## Detect if this is an OVH server by getting the global IP and checking the ASN
if [ "$(whois -h v4.whois.cymru.com " -t $(curl ipinfo.io/ip 2> /dev/null)" | tail -n 1 | cut -d'|' -f3 | grep -i "ovh")" != "" ] ; then
  echo "Detected OVH Server, installing OVH RTM (real time monitoring)"
  #http://help.ovh.co.uk/RealTimeMonitoring
  wget ftp://ftp.ovh.net/made-in-ovh/rtm/install_rtm.sh -c -O install_rtm.sh && bash install_rtm.sh && rm install_rtm.sh
fi

## Protect the web interface with fail2ban
apt-get install -y fail2ban
cat > /etc/fail2ban/filter.d/proxmox.conf <<EOF
[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
EOF
cat > /etc/fail2ban/jail.d/proxmox <<EOF
[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
logpath = /var/log/daemon.log
maxretry = 3
# 1 hour
bantime = 3600
EOF
systemctl enable fail2ban
##testing
#fail2ban-regex /var/log/daemon.log /etc/fail2ban/filter.d/proxmox.conf

## Increase vzdump backup speed
sed -i "s/#bwlimit: KBPS/bwlimit: 10240000/" /etc/vzdump.conf

## Remove subscription banner
sed -i "s|if (data.status !== 'Active')|if (data.status === 'Active')|g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
sed -i "s|if (data.status !== 'Active')|if (data.status === 'Active')|g" /usr/share/pve-manager/js/pvemanagerlib.js
# create a daily cron to make sure the banner does not re-appear
cat > /etc/cron.daily/proxmox-nosub <<EOF
#!/bin/sh
sed -i "s|if (data.status !== 'Active')|if (data.status === 'Active')|g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
sed -i "s|if (data.status !== 'Active')|if (data.status === 'Active')|g" /usr/share/pve-manager/js/pvemanagerlib.js
EOF
chmod 755 /etc/cron.daily/proxmox-nosub

# ## Pretty MOTD
# if ! grep -q https "/etc/motd" ; then
# cat > /etc/motd.new <<'EOF'
#    This system is optimised by:            https://eXtremeSHOK.com
#      __   ___                            _____ _    _  ____  _  __
#      \ \ / / |                          / ____| |  | |/ __ \| |/ /
#   ___ \ V /| |_ _ __ ___ _ __ ___   ___| (___ | |__| | |  | | ' /
#  / _ \ > < | __| '__/ _ \ '_ ` _ \ / _ \\___ \|  __  | |  | |  <
# |  __// . \| |_| | |  __/ | | | | |  __/____) | |  | | |__| | . \
#  \___/_/ \_\\__|_|  \___|_| |_| |_|\___|_____/|_|  |_|\____/|_|\_\

## Bugfix: pve 5.1 high swap usage with low memory usage
cat <<'EOF' >> /etc/sysctl.conf
# Start using SWAP when RAM is used at 90 percent, not before
# vm.swappiness = 60 # default value
# vm.swappiness = 5 # recommended
vm.swappiness = 10

EOF
sysctl -p /etc/sysctl.conf

## Increase max user watches (default is 8192)
# BUG FIX : No space left on device
cat <<'EOF' >> /etc/sysctl.conf
# Increase max user watches
# fs.inotify.max_user_watches = 8192 # default value
# fs.inotify.max_user_watches = 100000 # more
fs.inotify.max_user_watches = 1048576 # even more

EOF
# echo 1048576 > /proc/sys/fs/inotify/max_user_watches
sysctl -p /etc/sysctl.conf

### zimbra tuning: http://core-us.fr/tuning-zimbra/
# Check default values before changing as tcp_tw_reuse seems to fool everything
# cat <<'EOF' >> /etc/sysctl.conf
# # zimbra tuning: http://core-us.fr/tuning-zimbra/
#
# #net.ipv4.tcp_fin_timeout = 60
# net.ipv4.tcp_fin_timeout = 50
# ##net.ipv4.tcp_tw_reuse = 0
# #net.ipv4.tcp_tw_reuse = 1 # attention cette option fout le bordel: https://vincent.bernat.im/fr/blog/2014-tcp-time-wait-state-linux
# net.ipv4.tcp_tw_reuse = 0
# ##net.ipv4.tcp_tw_recycle = 0
# #net.ipv4.tcp_tw_recycle = 1 # attention cette option fout le bordel: https://vincent.bernat.im/fr/blog/2014-tcp-time-wait-state-linux
# net.ipv4.tcp_tw_recycle = 0
#
# EOF

## Increase max FD limit / ulimit
cat <<'EOF' >> /etc/security/limits.conf
# Increase max FD limit / ulimit
* soft     nproc          131072
* hard     nproc          131072
* soft     nofile         131072
* hard     nofile         131072
root soft     nproc          131072
root hard     nproc          131072
root soft     nofile         131072
root hard     nofile         131072
EOF

## Increase kernel max Key limit
cat <<'EOF' > /etc/sysctl.d/60-maxkeys.conf
# Increase kernel max Key limit
kernel.keys.root_maxkeys = 1000000
kernel.keys.maxkeys = 1000000
EOF

## Script Finish
echo -e '\033[1;33m Finished....please restart the system \033[0m'
