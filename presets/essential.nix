{ systemConfig, lib }:

{
  machine-id = { 
    files = [ "/etc/machine-id" ];
  };
  uid-gid-map = { 
    directories = [ "/var/lib/nixos" ];
  };
  openssh = {
    option = systemConfig.services.openssh.enable;
    files = lib.concatMap (key: [ key.path (key.path + ".pub") ]) systemConfig.services.openssh.hostKeys;
  };
}
