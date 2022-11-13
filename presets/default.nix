{ config, systemConfig, lib }:

let
  inherit (lib) optionals foldAttrs;

  buildPreset = { option, files ? [ ], directories ? [ ] }: {
    files = optionals option files;
    directories = optionals option directories;
  };

  essential = { 
    option = config.presets.essential.enable;
    files = [ "/etc/machine-id" ];
    directories = [ "/var/lib/nixos" ];
  };

  allPresets = builtins.map (x: buildPreset x) [ essential ];
  appliedPresets = foldAttrs (val: col: val ++ col) [] allPresets;
in
{
  files = appliedPresets.files;
  directories = appliedPresets.directories;
}
