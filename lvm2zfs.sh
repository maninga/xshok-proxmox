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
# Assumptions: proxmox installed via OVH manager (non zfs)
# Remaining for /var/lib/vz (LVM)
#
# Creates the following storage/rpools
# zfsbackup (rpool/backup)
# zfsvmdata (rpool/vmdata)
#
# Will automatically detect the required raid level and optimise.
#
# 1 Drive = zfs
# 2 Drives = mirror
# 3-5 Drives = raidz-1
# 6-11 Drives = raidz-2
# 11+ Drives = raidz-3
#
# NOTE: WILL  DESTROY ALL DATA ON /var/lib/vz
#
# Usage:
# curl -O https://raw.githubusercontent.com/extremeshok/xshok-proxmox/master/lvm2zfs.sh && chmod +x lvm2zfs.sh
# ./lvm2zfs.sh
#
################################################################################
#
#    THERE ARE NO USER CONFIGURABLE OPTIONS IN THIS SCRIPT
#
################################################################################

# The default LVM mount which will be replaced with ZFS
mypart="/var/lib/vz"

#Detect and install dependencies
if ! type "zpool" >& /dev/null; then
  apt-get install -y zfsutils-linux
  modprobe zfs
fi

mydev=$(mount | grep "$mypart" | cut -d " " -f 1)
ret=$?
if [ $ret == 0 ] ; then
 	echo "Found partition, continuing"
 	echo "$mydev" #/dev/mapper/pve-data
else
	echo "ERROR: $mypart not found"
fi

if [ "$(which zpool)" == "" ] ; then
	echo "ERROR: ZFS not installed"
	exit 1
fi

myraid=$(pvdisplay 2> /dev/null  | sed -n -e 's/^.*\/dev\///p')
ret=$?
if [ $ret == 0 ] ; then
	 echo "Found raid, continuing"
	 echo "$myraid" #md5
else
	echo "ERROR: $myraid not found"
	exit 1
fi

#pve/data
mylv=$(lvdisplay "$mydev" 2> /dev/null | sed -n -e 's/^.*\/dev\///p')
ret=$?
if [ $ret == 0 ] ; then
	echo "Found lv, continuing"
	echo "$mylv" #sda1
else
	echo "ERROR: $mylv not found"
	exit 1
fi

IFS=' ' read -r -a mddevarray <<< "$(grep "$myraid :" /proc/mdstat | cut -d ' ' -f5- | xargs)"

if [ "${mddevarray[0]}" == "" ] ; then
	echo "ERROR: no devices found for $myraid in /proc/mdstat"
	exit 1
fi
#check there is a minimum of 1 drives detected, not needed, but i rather have it.
if [ "${#mddevarray[@]}" -lt "1" ] ; then
  echo "ERROR: less than 1 devices were detected"
  exit 1
fi

if [ "$mydev" != "" ] && [ "$myraid" != "" ] && [ "$mylv" != "" ] ; then
	echo "All required varibles detected"
else
	echo "ERROR: required varible not found or the server is already converted to zfs"
	exit 1
fi

# remove [*] and /dev/ to each record
echo "Creating the device array"
for index in "${!mddevarray[@]}" ; do
    tempmddevarraystring="${mddevarray[index]}"
    mddevarray[$index]="/dev/${tempmddevarraystring%\[*\]}"
done

echo "Destroying LV (logical volume)"
umount -l "$mypart"
lvremove "/dev/$mylv" -y 2> /dev/null

echo "Destroying MD (linux raid)"
mdadm --stop "/dev/$myraid"
mdadm --remove "/dev/$myraid"

for mydev in "${mddevarray[@]}" ; do
    echo "zeroing $mydev"
    mdadm --zero-superblock "$mydev"
done

# #used to make a max free space lvm
# #lvcreate -n ZFS pve -l 100%FREE -y
if [ "${#mddevarray[@]}" -eq "1" ] ; then
  echo "Creating ZFS mirror (raid1)"
  zpool create -f -o ashift=12 -O compression=lz4 rpool "${mddevarray[@]}"
  ret=$?
elif [ "${#mddevarray[@]}" -eq "2" ] ; then
  echo "Creating ZFS mirror (raid1)"
  zpool create -f -o ashift=12 -O compression=lz4 rpool mirror "${mddevarray[@]}"
  ret=$?
elif [ "${#mddevarray[@]}" -ge "3" ] && [ "${#mddevarray[@]}" -le "5" ] ; then
  echo "Creating ZFS raidz-1 (raid5)"
  zpool create -f -o ashift=12 -O compression=lz4 rpool raidz "${mddevarray[@]}"
  ret=$?
elif [ "${#mddevarray[@]}" -ge "6" ] && [ "${#mddevarray[@]}" -lt "11" ] ; then
  echo "Creating ZFS raidz-2 (raid6)"
  zpool create -f -o ashift=12 -O compression=lz4 rpool raidz2 "${mddevarray[@]}"
  ret=$?
elif [ "${#mddevarray[@]}" -ge "11" ] ; then
  echo "Creating ZFS raidz-3 (raid7)"
  zpool create -f -o ashift=12 -O compression=lz4 rpool raidz3 "${mddevarray[@]}"
  ret=$?
fi

if [ $ret != 0 ] ; then
	echo "ERROR: creating ZFS"
	exit 1
fi

echo "Creating Secondary ZFS Pools"
echo "-- rpool/vmdata"
zfs create rpool/vmdata
echo "-- rpool/backup (/backup_rpool)"
zfs create -o mountpoint=/backup_rpool rpool/backup
echo "-- rpool/tmp (/tmp_rpool)"
zfs create -o setuid=off -o devices=off -o mountpoint=/tmp_rpool rpool/tmp

#export the pool
zpool export rpool
sleep 5
zpool import rpool
sleep 5

echo "Cleaning up fstab / mounts"
#/dev/pve/data   /var/lib/vz     ext3    defaults        1       2
grep -v "$mypart" /etc/fstab > /tmp/fstab.new && mv /tmp/fstab.new /etc/fstab

echo "Setting ZFS Optimisations"
zfspoolarray=("rpool" "rpool/vmdata" "rpool/backup" "rpool/tmp")
for zfspool in "${zfspoolarray[@]}" ; do
  echo "Optimising $zfspool"
  zfs set compression=on "$zfspool"
  zfs set compression=lz4 "$zfspool"
  zfs set sync=disabled "$zfspool"
  zfs set primarycache=all "$zfspool"
  zfs set atime=off "$zfspool"
  zfs set checksum=off "$zfspool"
  zfs set dedup=off "$zfspool"

  echo "Adding weekly pool scrub for ${zfspool}"
  if [ ! -f "/etc/cron.weekly/rpool" ] ; then
    echo '#!/bin/bash' > "/etc/cron.weekly/rpool"
  fi
  echo "zpool scrub ${zfspool}" >> "/etc/cron.weekly/rpool"

done

if [ -f "/etc/vzdump.conf" ]; then
  echo "set vzdump temp dir to use the /tmp_rpool"
  sed -i "s|tmpdir: /var/lib/vz/tmp_backup|tmpdir: /tmp_rpool|" /etc/vzdump.conf
fi

if type "pvesm" >& /dev/null; then
  # https://pve.proxmox.com/pve-docs/pvesm.1.html
  echo "Adding the ZFS storage pools to Proxmox GUI"
  echo "-- rpool-vmdata"
  pvesm add zfspool rpool-vmdata --pool rpool/vmdata --sparse 1
  echo "-- rpool-backup"
  pvesm add dir rpool-backup --path /backup_rpool
fi

#script Finish
echo -e '\033[1;33m Finished....please restart the server \033[0m'
