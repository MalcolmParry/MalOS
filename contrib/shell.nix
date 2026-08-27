{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = with pkgs; [
    zig_0_16
    zls_0_16
    nasm
    binutils
    grub2
    libisoburn
    mtools
    dosfstools
    qemu
    gf
  ];

  shellHook = ''
    export GRUB_DIR="${pkgs.grub2}/lib/grub"
    echo "GRUB_DIR=$GRUB_DIR"
  '';
}
