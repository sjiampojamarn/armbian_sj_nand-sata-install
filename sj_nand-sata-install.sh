#!/bin/bash 

# check files currenty open for writting
check_files_open()
{
	lsof / | awk 'NR==1 || $4~/[0-9][uw]/' | grep -v "^COMMAND"
}

# try to stop running services
stop_running_services()
{
	systemctl --state=running | awk -F" " '/.service/ {print $1}' | sort -r | \
		grep -E -e "$1" | while read ; do
		echo -e "\nStopping ${REPLY} \c"
		systemctl stop ${REPLY} 2>&1
	done
}

# define makefs and mount options
declare -A mkopts mountopts
# for ARMv7 remove 64bit feature from default mke2fs format features
if [[ $LINUXFAMILY == mvebu ]]; then
	mkopts[ext2]='-O ^64bit -qF'
	mkopts[ext3]='-O ^64bit -qF'
	mkopts[ext4]='-O ^64bit -qF'
else
	mkopts[ext2]='-qF'
	mkopts[ext3]='-qF'
	mkopts[ext4]='-qF'
fi
mkopts[btrfs]='-f'
mkopts[f2fs]='-f'

mountopts[ext2]='defaults,noatime,nodiratime,commit=600,errors=remount-ro,x-gvfs-hide	0	1'
mountopts[ext3]='defaults,noatime,nodiratime,commit=600,errors=remount-ro,x-gvfs-hide	0	1'
mountopts[ext4]='defaults,noatime,nodiratime,commit=600,errors=remount-ro,x-gvfs-hide	0	1'
mountopts[btrfs]='defaults,noatime,nodiratime,commit=600,compress=lzo,x-gvfs-hide			0	2'
mountopts[f2fs]='defaults,noatime,nodiratime,x-gvfs-hide	0	2'

# script configuration
CWD="/usr/lib/nand-sata-install"
EX_LIST="${CWD}/exclude.txt"

#recognize_root 
root_uuid=$(sed -e 's/^.*root=//' -e 's/ .*$//' < /proc/cmdline)
root_partition=$(blkid | tr -d '":' | grep "${root_uuid}" | awk '{print $1}')
root_partition_device="${root_partition::-2}"

# target SATA
target_root_dev=/dev/sdb1
satauuid=$(blkid -o export "$target_root_dev" | grep -w UUID)

# SD UUID for boot
sduuid=$(blkid -o export /dev/mmcblk*p1 | grep -w UUID | grep -v "$root_partition_device")

FilesystemChoosen=ext4

echo -e "\nCurrent root UUID root_uuid: ${root_uuid}" 
echo "SD UUID sduuid: $sduuid" 
echo "SATA new root UUID satauuid: $satauuid" 
echo "new root target_root_dev: $target_root_dev"
echo "new root FilesystemChoosen: $FilesystemChoosen" 

set -x;
############################
# stop running services
############################
#check_files_open
#stop_running_services "nfs-|smbd|nmbd|winbind|ftpd|netatalk|monit|cron|webmin|rrdcached" 
#stop_running_services "fail2ban|ramlog|folder2ram|postgres|mariadb|mysql|postfix|mail|nginx|apache|snmpd"
#pkill dhclient 
#check_files_open

#########################################
# create mount points, mount and clean
#########################################
TempDir=$(mktemp -d /mnt/${0##*/}.XXXXXX || exit 2)
sync &&	mkdir -p "${TempDir}"/bootfs "${TempDir}"/rootfs
mount "$target_root_dev" "${TempDir}"/rootfs
sleep 3

###################
# rsync copy
###################
 rsync -avXAh --progress --delete --exclude-from=$EX_LIST / "${TempDir}"/rootfs
 sync
 rsync -avXAh --progress --delete --exclude-from=$EX_LIST / "${TempDir}"/rootfs

##################################
# creating fstab from scratch
##################################
rm -f "${TempDir}"/rootfs/etc/fstab
mkdir -p "${TempDir}"/rootfs/etc "${TempDir}"/rootfs/media/mmcboot "${TempDir}"/rootfs/media/mmcroot
echo "# <file system>					<mount point>	<type>	<options>							<dump>	<pass>" > "${TempDir}"/rootfs/etc/fstab
echo "tmpfs						/tmp		tmpfs	defaults,nosuid							0	0" >> "${TempDir}"/rootfs/etc/fstab
grep swap /etc/fstab >> "${TempDir}"/rootfs/etc/fstab

###############################################################
# creating fstab, kernel and boot script for NAND partition
# Boot from SD card, root = SATA / USB
###############################################################
sed -e 's,rootdev=.*,rootdev='"$satauuid"',g' -i /boot/armbianEnv.txt
grep -q '^rootdev' /boot/armbianEnv.txt || echo "rootdev=$satauuid" >> /boot/armbianEnv.txt
sed -e 's,rootfstype=.*,rootfstype='$FilesystemChoosen',g' -i /boot/armbianEnv.txt
grep -q '^rootfstype' /boot/armbianEnv.txt || echo "rootfstype=$FilesystemChoosen" >> /boot/armbianEnv.txt
[[ -f /boot/boot.cmd ]] && mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr >/dev/null 2>&1 || (echo 'Error while creating U-Boot loader image with mkimage' >&2 ; exit 7)
mkdir -p "${TempDir}"/rootfs/media/mmc/boot
echo "${sduuid}	/media/mmcboot	ext4    ${mountopts[ext4]}" >> "${TempDir}"/rootfs/etc/fstab
echo "/media/mmcboot/boot  				/boot		none	bind								0       0" >> "${TempDir}"/rootfs/etc/fstab
echo "$satauuid	/		$FilesystemChoosen	${mountopts[$FilesystemChoosen]}" >> "${TempDir}"/rootfs/etc/fstab
set +x;

