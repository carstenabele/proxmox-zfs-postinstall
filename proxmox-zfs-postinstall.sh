#!/bin/bash

###### CONFIG SECTION ######

# Define basic tools to install
TOOLS="sudo vim ifupdown2 libpve-network-perl net-tools dnsutils ethtool git curl unzip screen iftop lshw smartmontools nvme-cli lsscsi sysstat exa zsh htop mc rpl lsb-release"

#### PVE CONF BACKUP CONFIGURATION ####

# Define target dataset for backup of /etc
# IMPORTANT NOTE: Don't type in the leading /, this will be set where needed
PVE_CONF_BACKUP_TARGET=rpool/pveconf

# Define timer for your backup cronjob (default: every 15 minutes fron 3 through 59)
PVE_CONF_BACKUP_CRON_TIMER="3,18,33,48 * * * *"

# Get Debian version info
source /etc/os-release

###### SYSTEM INFO AND INTERACTIVE CONFIGURATION SECTION ######

ROUND_FACTOR=512

roundup(){
    echo $(((($1 + $ROUND_FACTOR) / $ROUND_FACTOR) * $ROUND_FACTOR))
}

roundoff(){
    echo $((($1 / $ROUND_FACTOR) * $ROUND_FACTOR))
}

#### L1ARC SIZE CONFIGURATION ####

# get total size of all zpools
ZPOOL_SIZE_SUM_BYTES=0
for line in $(zpool list -o size -Hp); do ZPOOL_SIZE_SUM_BYTES=$(($ZPOOL_SIZE_SUM_BYTES+$line)); done

# get information about available ram
MEM_TOTAL_BYTES=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) * 1024))

# get values if defaults are set
ARC_MAX_DEFAULT_BYTES=$(($MEM_TOTAL_BYTES / 2))
ARC_MIN_DEFAULT_BYTES=$(($MEM_TOTAL_BYTES / 32))

# get current settings
ARC_MIN_CUR_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_min)
ARC_MAX_CUR_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_max)

# calculate suggested l1arc sice
ZFS_ARC_MIN_MEGABYTES=$(roundup $(($ZPOOL_SIZE_SUM_BYTES / 2048 / 1024 / 1024)))
ZFS_ARC_MAX_MEGABYTES=$(roundoff $(($ZPOOL_SIZE_SUM_BYTES / 1024 / 1024 / 1024)))

echo -e "######## CONFIGURE ZFS L1ARC SIZE ########\n"
echo "System Summary:"
echo -e "\tSystem Memory:\t\t$(($MEM_TOTAL_BYTES / 1024 / 1024))\tMB"
echo -e "\tZpool size (sum):\t$(($ZPOOL_SIZE_SUM_BYTES / 1024 / 1024))\tMB"
echo -e "Calculated l1arc if set to defaults:"
if [ $ARC_MIN_DEFAULT_BYTES -lt 33554432 ]; then
    echo -e "\tDefault zfs_arc_min:\t32\tMB"
else
    echo -e "\tDefault zfs_arc_min:\t$(($ARC_MIN_DEFAULT_BYTES / 1024 / 1024))\tMB"
fi
echo -e "\tDefault zfs_arc_max:\t$(($ARC_MAX_DEFAULT_BYTES / 1024 / 1024))\tMB"
echo -e "Current l1arc configuration:"
if [ $ARC_MIN_CUR_BYTES -gt 0 ]; then
    echo -e "\tCurrent zfs_arc_min:\t$(($ARC_MIN_CUR_BYTES / 1024 / 1024))\tMB"
else
    echo -e "\tCurrent zfs_arc_min:\t0"
fi
if [ $ARC_MAX_CUR_BYTES -gt 0 ]; then
    echo -e "\tCurrent zfs_arc_max:\t$(($ARC_MAX_CUR_BYTES / 1024 / 1024))\tMB"
else
    echo -e "\tCurrent zfs_arc_max:\t0"
fi
echo -e "Note: If your current values are 0, the calculated values above will apply."
echo ""
echo -e "The l1arc cache will be set relative to the size (sum) of your zpools by policy"
echo -e "zfs_arc_min:\t\t\t$(($ZFS_ARC_MIN_MEGABYTES))\tMB\t\t= 512 MB RAM per 1 TB ZFS storage (round off in 512 MB steps)"
echo -e "zfs_arc_max:\t\t\t$(($ZFS_ARC_MAX_MEGABYTES))\tMB\t\t= 1 GB RAM per 1 TB ZFS storage (round up in 512 MB steps)"
echo ""
RESULT=not_set
while [ "$(echo $RESULT | awk '{print tolower($0)}')" != "y" ] && [ "$(echo $RESULT | awk '{print tolower($0)}')" != "n" ] && [ "$(echo $RESULT | awk '{print tolower($0)}')" != "" ]; do
    read -p "If you want to apply the values by script policy type 'y', type 'n' to adjust the values yourself [Y/n]? "
    RESULT=${REPLY}
done
if [[ "$(echo $RESULT | awk '{print tolower($0)}')" == "n" ]]; then
    read -p "Please type in the desired value in MB for 'zfs_arc_min' [$(($ZFS_ARC_MIN_MEGABYTES))]: "
    if [[ ${REPLY} -gt 0 ]]; then
        ZFS_ARC_MIN_MEGABYTES=$((${REPLY}))
    fi
    read -p "Please type in the desired value in MB for 'zfs_arc_max' [$(($ZFS_ARC_MAX_MEGABYTES))]: "
    if [[ ${REPLY} -gt 0 ]]; then
        ZFS_ARC_MAX_MEGABYTES=$((${REPLY}))
    fi
fi

#### SWAPPINESS ####

echo -e "######## CONFIGURE SWAPPINESS ########\n"
SWAPPINESS=$(cat /proc/sys/vm/swappiness)
echo "The current swappiness is configured to '$SWAPPINESS %' of free memory until using swap."
read -p "If you want to change the swappiness, please type in the percentage as number (0 = diasbled):" user_input
if echo "$user_input" | grep -qE '^[0-9]+$'; then
    echo "Changing swappiness from '$SWAPPINESS %' to '$user_input %'"
    SWAPPINESS=$user_input
else
    echo "No input - swappiness unchanged at '$SWAPPINESS %'."
fi

###### INSTALLER SECTION ######

# disable pve-enterprise repo and add pve-no-subscription repo
if [[ "$(uname -r)" == *"-pve" ]]; then
    echo "Deactivating pve-enterprise repository"
    mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak > /dev/null 2>&1
    echo "Activating pve-no-subscription repository"
    q=$(cat /etc/apt/sources.list | grep "pve-no-subscription")
    if [ $? -gt 0 ]; then
        echo "deb http://download.proxmox.com/debian/pve $VERSION_CODENAME pve-no-subscription" >> /etc/apt/sources.list
    fi
    rm -f /etc/apt/sources.list.d/pve-no-subscription.list
fi
echo "Getting latest package lists"
apt update > /dev/null 2>&1

# include interfaces.d to enable SDN features
q=$(cat /etc/network/interfaces | grep "source /etc/network/interfaces.d/*")
if [ $? -gt 0 ]; then
    echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
fi

# update system and install basic tools
echo "Upgrading system to latest version - Depending on your version this could take a while..."
DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt -y -qq dist-upgrade > /dev/null 2>&1
echo "Installing toolset - Depending on your version this could take a while..."
DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt -y -qq install $TOOLS > /dev/null 2>&1

# configure zfs-auto-snapshot
for interval in "${!auto_snap_keep[@]}"; do
    echo "Setting zfs-auto-snapshot retention: $interval = ${auto_snap_keep[$interval]}"
    if [[ "$interval" == "frequent" ]]; then
        CURRENT=$(cat /etc/cron.d/zfs-auto-snapshot | grep keep | cut -d' ' -f19 | cut -d '=' -f2)
        if [[ "${auto_snap_keep[$interval]}" != "$CURRENT" ]]; then
            rpl "keep=$CURRENT" "keep=${auto_snap_keep[$interval]}" /etc/cron.d/zfs-auto-snapshot > /dev/null 2>&1
        fi
    else
        CURRENT=$(cat /etc/cron.$interval/zfs-auto-snapshot | grep keep | cut -d' ' -f6 | cut -d'=' -f2)
        if [[ "${auto_snap_keep[$interval]}" != "$CURRENT" ]]; then
            rpl "keep=$CURRENT" "keep=${auto_snap_keep[$interval]}" /etc/cron.$interval/zfs-auto-snapshot > /dev/null 2>&1
        fi
    fi
done

echo "Configuring swappiness"
echo "vm.swappiness=$SWAPPINESS" > /etc/sysctl.d/swappiness.conf
sysctl -w vm.swappiness=$SWAPPINESS

echo "Configuring pve-conf-backup"
# create backup jobs of /etc
zfs list $PVE_CONF_BACKUP_TARGET > /dev/null 2>&1
if [ $? -ne 0 ]; then
    zfs create $PVE_CONF_BACKUP_TARGET
fi

if [[ "$(df -h -t zfs | grep /$ | cut -d ' ' -f1)" == "rpool/ROOT/pve-1" ]] ; then
  echo "$PVE_CONF_BACKUP_CRON_TIMER root rsync -va --delete /etc /$PVE_CONF_BACKUP_TARGET > /$PVE_CONF_BACKUP_TARGET/pve-conf-backup.log" > /etc/cron.d/pve-conf-backup
fi

ZFS_ARC_MIN_BYTES=$((ZFS_ARC_MIN_MEGABYTES * 1024 *1024))
ZFS_ARC_MAX_BYTES=$((ZFS_ARC_MAX_MEGABYTES * 1024 *1024))

echo "Adjusting ZFS level 1 arc"
echo $ZFS_ARC_MIN_BYTES > /sys/module/zfs/parameters/zfs_arc_min
echo $ZFS_ARC_MAX_BYTES > /sys/module/zfs/parameters/zfs_arc_max

cat << EOF > /etc/modprobe.d/zfs.conf
options zfs zfs_arc_min=$ZFS_ARC_MIN_BYTES
options zfs zfs_arc_max=$ZFS_ARC_MAX_BYTES
EOF


echo "Updating initramfs - This will take some time..."
update-initramfs -u -k all > /dev/null 2>&1

echo "Proxmox postinstallation finished!"
