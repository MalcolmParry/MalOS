#!/bin/sh
set -eu
boot_img=$1 core_img=$2 fs_img=$3 out=$4

truncate -s 32M "$out"
parted -s "$out" mklabel msdos mkpart primary ext2 1MiB 100%

dd if="$boot_img" of="$out" bs=440 count=1 conv=notrunc status=none
dd if="$core_img" of="$out" bs=512 seek=1  conv=notrunc status=none
dd if="$fs_img"   of="$out" bs=1M  seek=1  conv=notrunc status=none
