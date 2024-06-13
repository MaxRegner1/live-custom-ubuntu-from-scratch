#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error
#set -x

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

CMD=(setup_host install_pkg finish_up)

function help() {
    # if $1 is set, use $1 as headline message in help()
    if [ -z ${1+x} ]; then
        echo -e "This script builds Ubuntu from scratch with Pangolin Desktop and OpenEuler configurations"
        echo -e
    else
        echo -e $1
        echo
    fi
    echo -e "Supported commands : ${CMD[*]}"
    echo -e
    echo -e "Syntax: $0 [start_cmd] [-] [end_cmd]"
    echo -e "\trun from start_cmd to end_cmd"
    echo -e "\tif start_cmd is omitted, start from first command"
    echo -e "\tif end_cmd is omitted, end with last command"
    echo -e "\tenter single cmd to run the specific command"
    echo -e "\tenter '-' as only argument to run all commands"
    echo -e
    exit 0
}

function find_index() {
    local ret;
    local i;
    for ((i=0; i<${#CMD[*]}; i++)); do
        if [ "${CMD[i]}" == "$1" ]; then
            index=$i;
            return;
        fi
    done
    help "Command not found : $1"
}

function check_host() {
    if [ $(id -u) -ne 0 ]; then
        echo "This script should be run as 'root'"
        exit 1
    fi

    export HOME=/root
    export LC_ALL=C
}

function setup_host() {
    echo "=====> running setup_host ..."

    cat <<EOF > /etc/apt/sources.list
deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
EOF

    echo "$TARGET_NAME" > /etc/hostname

    # Install necessary packages
    apt-get update
    apt-get install -y libterm-readline-gnu-perl systemd-sysv dbus

    # Configure machine id
    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    # Handle initctl diversion
    dpkg-divert --local --rename --add /sbin/initctl
    ln -s /bin/true /sbin/initctl
}

# Load configuration values from file
function load_config() {
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then 
        . "$SCRIPT_DIR/config.sh"
    elif [[ -f "$SCRIPT_DIR/default_config.sh" ]]; then
        . "$SCRIPT_DIR/default_config.sh"
    else
        >&2 echo "Unable to find default config file  $SCRIPT_DIR/default_config.sh, aborting."
        exit 1
    fi
}

function install_pkg() {
    echo "=====> running install_pkg ... will take a long time ..."
    apt-get -y upgrade

    # Install minimal desktop environment
    apt-get install -y ubuntu-standard ubuntu-desktop-minimal

    # Install network tools
    apt-get install -y network-manager net-tools wireless-tools

    # Install bootloader
    apt-get install -y grub-common grub-pc grub2-common

    # Install locales
    apt-get install -y locales

    # Install kernel package
    apt-get install -y --no-install-recommends $TARGET_KERNEL_PACKAGE

    # Install Pangolin desktop environment
    add-apt-repository ppa:ubuntubudgie/backports || true  # Ignore errors if repository already added
    apt-get update
    apt-get install -y ubuntu-budgie-desktop

    # Call into config function
    customize_image

    # Remove unused and clean up apt cache
    apt-get autoremove -y

    # Final configuration
    dpkg-reconfigure locales

    # Check if resolvconf is installed before reconfiguring
    if dpkg -l resolvconf >/dev/null 2>&1; then
        dpkg-reconfigure resolvconf
    else
        echo "resolvconf is not installed"
    fi

    # Network manager configuration
    cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=resolvconf
plugins=ifupdown,keyfile
dns=dnsmasq

[ifupdown]
managed=false
EOF

    dpkg-reconfigure network-manager

    apt-get clean -y
}

function finish_up() { 
    echo "=====> finish_up"

    # Truncate machine id
    truncate -s 0 /etc/machine-id

    # Remove initctl diversion
    rm /sbin/initctl
    dpkg-divert --rename --remove /sbin/initctl

    # Clean up
    rm -rf /tmp/* ~/.bash_history
}

# =============   main  ================

load_config
check_host

# Check number of arguments
if [[ $# == 0 || $# > 3 ]]; then help; fi

# Loop through arguments
dash_flag=false
start_index=0
end_index=${#CMD[*]}
for ii in "$@";
do
    if [[ $ii == "-" ]]; then
        dash_flag=true
        continue
    fi
    find_index $ii
    if [[ $dash_flag == false ]]; then
        start_index=$index
    else
        end_index=$(($index+1))
    fi
done
if [[ $dash_flag == false ]]; then
    end_index=$(($start_index + 1))
fi

# Execute commands based on specified range
for ((ii=$start_index; ii<$end_index; ii++)); do
    ${CMD[ii]}
done

echo "$0 - Initial build is done!"
