let
  pkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/2786a2a72088ecf32aea5b3ec52099e6a7cff78f.tar.gz";
    sha256 = "0fm3lxj743j3ksdhs31lb2sn9bkix3kvam2qb4hc8ipr2yzmbxbz";
  }) { };
in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    zig_0_17
    zls_0_17
    nasm
    binutils
    grub2
    qemu
    gf
    e2fsprogs
    parted
    tio
  ];

  shellHook = ''
    export GRUB_DIR="${pkgs.grub2}/lib/grub"
    echo "GRUB_DIR=$GRUB_DIR"
  '';
}
