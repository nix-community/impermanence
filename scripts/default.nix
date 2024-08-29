{ lib
, pkgs
, systemctl ? lib.getExe' pkgs.systemd "systemctl"
, ...
}:
let
  outputPrefix = "OUTPUT:";

  os.mount-file = pkgs.writeShellApplication {
    name = "impermanence-mount-file";
    runtimeInputs = with pkgs; [ util-linux gnugrep ];
    text = builtins.readFile ./os-mount-file.bash;
  };
  os.create-directories = pkgs.writeShellApplication {
    name = "impermanence-create-directories";
    runtimeInputs = with pkgs; [ coreutils ];
    text = builtins.readFile ./os-create-directories.bash;
  };

  hm.unmount = pkgs.writeShellApplication {
    name = "impermanence-hm-unmount";
    runtimeInputs = (with pkgs; [
      fuse
    ]) ++ (with hm; [
      mount-info
    ]);
    text = builtins.readFile ./hm-unmount.bash;
  };

  hm.mount-info = pkgs.writeShellApplication {
    name = "impermanence-hm-mount-info";
    runtimeInputs = with pkgs; [ util-linux gnugrep ];
    text = builtins.readFile ./hm-mount-info.bash;
  };

  hm.bind-mount-activation = pkgs.writeShellApplication {
    name = "impermanence-hm-bind-mount-activation";
    runtimeInputs = (with pkgs; [
      bindfs
      coreutils
      util-linux
    ]) ++ (with hm; [
      mount-info
      unmount
    ]);
    text = ''
      PATH="${builtins.dirOf systemctl}:$PATH"
      ${builtins.readFile ./hm-bind-mount-activation.bash}
    '';
  };
  hm.bind-mount-service = pkgs.writeShellApplication {
    name = "impermanence-hm-bind-mount-service";
    runtimeInputs = (with pkgs; [
      bindfs
      coreutils
    ]) ++ (with hm; [
      mount-info
      unmount
    ]);
    text = builtins.readFile ./hm-bind-mount-service.bash;
  };
in
{
  inherit os hm outputPrefix;
}
