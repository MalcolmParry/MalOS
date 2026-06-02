{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    nasm
    binutils
    grub2
    libisoburn
    mtools
    dosfstools
    qemu
  ];

  shellHook = ''
    export GRUB_DIR="${pkgs.grub2}/lib/grub"
    echo "GRUB_DIR=$GRUB_DIR"
  '';
}
