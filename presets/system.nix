{ config, systemConfig, lib }:

let
  enabled = config.presets.system.enable;
  inherit (systemConfig) networking services;
in
[
  {
    option = enabled && networking.networkmanager.enable;
    directories = [ "/etc/NetworkManager/system-connections" ];
  }
  {
    option = enabled && services.tailscale.enable;
    directories = [ "/var/lib/tailscale" ];
  }
]
