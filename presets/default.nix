{ config, systemConfig, lib }:

let
  inherit (lib) optionals foldAttrs optionalAttrs;

  buildPreset = name: value: {
    files = optionals (value.option or systemConfig.services."${name}".enable) (value.files or [ ]);
    directories = optionals (value.option or systemConfig.services."${name}".enable) (value.directories or [ ]);
  };

  essential = { 
    option = config.presets.essential.enable;
    files = [ "/etc/machine-id" ];
    directories = [ "/var/lib/nixos" ];
  };

  allPresets = builtins.mapAttrs (name: value: buildPreset name value)
  { inherit essential; } //
  optionalAttrs config.presets.system.enable (import ./system.nix { inherit systemConfig lib; });

  appliedPresets = foldAttrs (val: col: val ++ col) [] (builtins.attrValues allPresets);
in
{
  files = appliedPresets.files;
  directories = appliedPresets.directories;
}
