{ systemConfig, lib }:

let
  inherit (systemConfig) networking services hardware security virtualisation;
in
{
  networkmanager = {
    option = networking.networkmanager.enable;
    directories = [ "/etc/NetworkManager/system-connections" ];
    files = [
      "/var/lib/NetworkManager/secret_key"
      "/var/lib/NetworkManager/seen-bssids"
      "/var/lib/NetworkManager/timestamps"
    ]; # Why those files?
  };
  tailscale.directories = [ "/var/lib/tailscale" ];
  bluetooth = {
    option = hardware.bluetooth.enable;
    directories = [ "/var/lib/bluetooth" ];
  };
  acme = let
    cfg = security.acme.certs;
  in {
    option = cfg != { };
    directories = [ "/var/lib/acme" ]; # Is this more correct than the snippet below?
    #directories = builtins.map (x: x.directory) (builtins.attrValues cfg);
  };
  libvirtd = {
    option = virtualisation.libvirtd.enable;
    directories = [ "/var/lib/libvirt" ];
  };
  podman = {
    option = virtualisation.podman.enable;
    directories = [ "/var/lib/containers" ];
  };
  docker = {
    option = virtualisation.docker.enable;
    directories = [ "/var/lib/docker" ];
  };
  nixos-containers = {
    option = systemConfig.containers != { };
    directories = [ "/var/lib/nixos-containers" ];
  };
  flatpak.directories = [ "/var/lib/flatpak" ];
  fwupd.directories = [ "/var/lib/fwupd" ];
  lxd = {
    option = virtualisation.lxd.enable;
    directories = [ "/var/lib/lxd" ];
  };
  postgresql.directories = [ services.postgresql.dataDir ];
  prometheus.directories = [ ("/var/lib/" + services.prometheus.stateDir) ];
  loki.directories = [ services.loki.dataDir ];
  grafana.directories = [ services.grafana.dataDir ];
}
