{ systemConfig, lib }:

let
  inherit (systemConfig) networking services;
in
{
  networkmanager = {
    option = networking.networkmanager.enable;
    directories = [ "/etc/NetworkManager/system-connections" ];
  };
  tailscale.directories = [ "/var/lib/tailscale" ];
}
