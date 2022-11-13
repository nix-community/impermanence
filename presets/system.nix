{ systemConfig, lib }:

let
  inherit (systemConfig) networking services;
in
[
  {
    option = networking.networkmanager.enable;
    directories = [ "/etc/NetworkManager/system-connections" ];
  }
  {
    option = services.tailscale.enable;
    directories = [ "/var/lib/tailscale" ];
  }
]
