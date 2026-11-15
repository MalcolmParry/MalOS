{
  config,
  lib,
  pkgs,
  ...
}:
let
  settings = import ./settings.nix;
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];
  boot.loader.timeout = 3;
  boot.loader.grub = {
    enable = true;
    device = settings.bootDevice;
    default = "saved";
    configurationLimit = 5;
    extraConfig = ''
      serial --unit=0 --speed=115200
      terminal_input serial console
      terminal_output serial console
    '';
    extraEntries = ''
      menuentry "MalOS" {
        multiboot2 (hd0,msdos1)/boot/kernel.elf
        module2 (hd0,msdos1)/boot/initrd.tar initrd
        module2 (hd0,msdos1)/boot/kernel_src.tar kernel_src_tar
        set gfxpayload=text
        boot
      }
    '';
  };

  fileSystems."/mnt/malos" = {
    device = "/dev/disk/by-label/malos";
    fsType = "ext2";
    options = [ "nofail" ];
  };

  networking.hostName = settings.hostName;
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  environment.systemPackages = with pkgs; [
    vim
    rsync
    grub2
  ];

  users.users.${settings.userName} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ settings.sshKey ];
  };

  systemd.services.malos-update = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = "/mnt/malos";

    path = with pkgs; [
      rsync
      grub2
    ];
    script = ''
      rsync -av --delete --exclude=/lost+found --timeout=30 --contimeout=10 rsync://${settings.serverIp}/malos/root/ /mnt/malos/
      sync -f /mnt/malos
      grub-reboot MalOS
      systemctl reboot
    '';
  };

  specialisation.maintenance.configuration = {
    systemd.services.malos-update.enable = false;
  };

  system.stateVersion = "26.05";
}
