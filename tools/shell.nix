{
  pkgs ? import <nixpkgs> { },
}:
let
  unstable =
    import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz")
      { };
in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    unstable.zig_0_17
    unstable.zls_0_17
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
