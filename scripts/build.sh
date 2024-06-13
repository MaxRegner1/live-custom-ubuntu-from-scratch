#!/bin/bash

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

CMD=(setup_host debootstrap run_chroot build_iso)

DATE=$(TZ="UTC" date +"%y%m%d-%H%M%S")

function help() {
    if [ -n "${1:-}" ]; then
        echo -e "$1\n"
    else
        echo -e "This script builds a bootable Daliha OS/Fuchsia OS ISO image\n"
    fi
    echo -e "Supported commands: ${CMD[*]}\n"
    echo -e "Syntax: $0 [start_cmd] [-] [end_cmd]"
    echo -e "\trun from start_cmd to end_cmd"
    echo -e "\tif start_cmd is omitted, start from the first command"
    echo -e "\tif end_cmd is omitted, end with the last command"
    echo -e "\tenter a single cmd to run that specific command"
    echo -e "\tenter '-' as the only argument to run all commands\n"
    exit 0
}

function find_index() {
    local ret
    for i in "${!CMD[@]}"; do
        if [ "${CMD[i]}" == "$1" ]; then
            index=$i
            return
        fi
    done
    help "Command not found: $1"
}

function chroot_enter_setup() {
    sudo mount --bind /dev chroot/dev
    sudo mount --bind /run chroot/run
    sudo chroot chroot mount none -t proc /proc
    sudo chroot chroot mount none -t sysfs /sys
    sudo chroot chroot mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    sudo chroot chroot umount /proc
    sudo chroot chroot umount /sys
    sudo chroot chroot umount /dev/pts
    sudo umount chroot/dev
    sudo umount chroot/run
}

function check_host() {
    if ! lsb_release -i | grep -E "(Ubuntu|Debian)" > /dev/null; then
        echo "WARNING: OS is not Debian or Ubuntu and is untested"
    fi

    if [ $(id -u) -eq 0 ]; then
        echo "This script should not be run as 'root'"
        exit 1
    fi
}

function load_config() {
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then 
        . "$SCRIPT_DIR/config.sh"
    elif [[ -f "$SCRIPT_DIR/default_config.sh" ]]; then
        . "$SCRIPT_DIR/default_config.sh"
    else
        >&2 echo "Unable to find default config file $SCRIPT_DIR/default_config.sh, aborting."
        exit 1
    fi
}

function check_config() {
    local expected_config_version="0.3"

    if [[ "$CONFIG_FILE_VERSION" != "$expected_config_version" ]]; then
        >&2 echo "Invalid or old config version $CONFIG_FILE_VERSION, expected $expected_config_version. Please update your configuration file from the default."
        exit 1
    fi
}

function setup_host() {
    echo "=====> running setup_host ..."
    sudo apt update
    sudo apt install -y binutils debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools
    sudo mkdir -p chroot
}

function debootstrap() {
    echo "=====> running debootstrap ... will take a couple of minutes ..."
    sudo debootstrap --arch=amd64 --variant=minbase $TARGET_UBUNTU_VERSION chroot http://us.archive.ubuntu.com/ubuntu/
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    chroot_enter_setup

    sudo cp -f $SCRIPT_DIR/chroot_build.sh chroot/root/chroot_build.sh
    sudo cp -f $SCRIPT_DIR/default_config.sh chroot/root/default_config.sh
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        sudo cp -f $SCRIPT_DIR/config.sh chroot/root/config.sh
    fi    

    sudo chroot chroot /root/chroot_build.sh -

    sudo rm -f chroot/root/chroot_build.sh
    sudo rm -f chroot/root/default_config.sh
    if [[ -f "chroot/root/config.sh" ]]; then
        sudo rm -f chroot/root/config.sh
    fi

    chroot_exit_teardown
}

function build_iso() {
    echo "=====> running build_iso ..."

    rm -rf image
    mkdir -p image/{casper,isolinux,install}

    sudo cp chroot/boot/vmlinuz-*-generic image/casper/vmlinuz
    sudo cp chroot/boot/initrd.img-*-generic image/casper/initrd

    sudo cp chroot/boot/memtest86+.bin image/install/memtest86+

    wget --progress=dot https://www.memtest86.com/downloads/memtest86-usb.zip -O image/install/memtest86-usb.zip
    unzip -p image/install/memtest86-usb.zip memtest86-usb.img > image/install/memtest86
    rm -f image/install/memtest86-usb.zip

    touch image/ubuntu
    cat <<EOF > image/isolinux/grub.cfg
search --set=root --file /ubuntu
insmod all_video
set default="0"
set timeout=30

menuentry "${GRUB_LIVEBOOT_LABEL}" {
    linux /casper/vmlinuz boot=casper nopersistent toram quiet splash ---
    initrd /casper/initrd
}

menuentry "${GRUB_INSTALL_LABEL}" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

menuentry "Test memory Memtest86+ (BIOS)" {
    linux16 /install/memtest86+
}

menuentry "Test memory Memtest86 (UEFI, long load time)" {
    insmod part_gpt
    insmod search_fs_uuid
    insmod chain
    loopback loop /install/memtest86
    chainloader (loop,gpt1)/efi/boot/BOOTX64.efi
}
EOF

    sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee image/casper/filesystem.manifest
    sudo cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
    for pkg in $TARGET_PACKAGE_REMOVE; do
        sudo sed -i "/$pkg/d" image/casper/filesystem.manifest-desktop
    done

    sudo mksquashfs chroot image/casper/filesystem.squashfs \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile"
    printf $(sudo du -sx --block-size=1 chroot | cut -f1) > image/casper/filesystem.size

    cat <<EOF > image/README.diskdefines
#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    pushd $SCRIPT_DIR/image
    grub-mkstandalone \
        --format=x86_64-efi \
        --output=isolinux/bootx64.efi \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=isolinux/grub.cfg"
    
    (
        cd isolinux
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        sudo mkfs.vfat efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/boot
        LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/
    )

    grub-mkstandalone \
        --format=i386-pc \
        --output=isolinux/core.img \
        --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
        --modules="linux16 linux normal iso9660 biosdisk search" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=isolinux/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img

    sudo /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'md5sum.txt' -e 'bios.img' -e 'efiboot.img' > md5sum.txt)"

    sudo xorriso \
        -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$TARGET_NAME" \
        -eltor    -ito-boot boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --eltorito-catalog boot/grub/boot.cat \
    --grub2-boot-info \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -append_partition 2 0xef isolinux/efiboot.img \
    -output "$SCRIPT_DIR/$TARGET_NAME.iso" \
    -m "isolinux/efiboot.img" \
    -m "isolinux/bios.img" \
    -graft-points \
       "/EFI/efiboot.img=isolinux/efiboot.img" \
       "/boot/grub/bios.img=isolinux/bios.img" \
       "."

    popd
}

cd $SCRIPT_DIR

load_config
check_config
check_host

if [[ $# == 0 || $# > 3 ]]; then help; fi

dash_flag=false
start_index=0
end_index=${#CMD[@]}
for arg in "$@"; do
    if [[ $arg == "-" ]]; then
        dash_flag=true
        continue
    fi
    find_index $arg
    if [[ $dash_flag == false ]]; then
        start_index=$index
    else
        end_index=$((index + 1))
    fi
done
if [[ $dash_flag == false ]]; then
    end_index=$((start_index + 1))
fi

for ((i = start_index; i < end_index; i++)); do
    ${CMD[i]}
done

echo "$0 - Initial build is done!"
