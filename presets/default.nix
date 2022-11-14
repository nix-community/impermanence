{ config, systemConfig, lib }:

let
  inherit (lib) optionals foldAttrs optionalAttrs mkOption mkEnableOption;
  inherit (lib.types) bool;

  buildPreset = name: value: let
    conditional = (value.option or systemConfig.services."${name}".enable) && config.presets.system."${name}";
  in {
    files = optionals conditional (value.files or [ ]);
    directories = optionals conditional (value.directories or [ ]);
  };

  buildEssentialPreset = name: value: let
    conditional = (value.option or true) && config.presets.essential."${name}";
  in {
    files = optionals conditional (value.files or [ ]);
    directories = optionals conditional (value.directories or [ ]);
  };

  buildEntries = attrs: builtins.mapAttrs (name: value: mkOption {
    type = bool;
    default = true;
    internal = true;
    description = "Whether to enable ${name} preset.";
  }) attrs;

  systemPresets = builtins.mapAttrs (name: value: buildPreset name value)
    (optionalAttrs config.presets.system.enable (import ./system.nix { inherit systemConfig lib; }));

  essentialPresets = builtins.mapAttrs (name: value: buildEssentialPreset name value)
    (optionalAttrs config.presets.essential.enable (import ./essential.nix { inherit systemConfig lib; }));

  allPresets = essentialPresets // systemPresets;
  appliedPresets = foldAttrs (val: col: val ++ col) [] (builtins.attrValues allPresets);
in
{
  files = appliedPresets.files;
  directories = appliedPresets.directories;

  presets = {
    essential = {
      enable = mkEnableOption ''
        essential presets. Without those, you will likely get an unusable,
        broken, or prone to corrupting over time system. It is recommended
        to back up those entries
      '';
    } // buildEntries (import ./essential.nix {inherit systemConfig lib; });

    system = {
      enable = mkEnableOption ''
        system presets. Those are not necessary for having a working system,
        but they are often desired: stuff like preserving passwords
        for Network Manager goes in here. It is not recommended to
        back up those entries
      '';
    } // buildEntries (import ./system.nix {inherit systemConfig lib; });
  };
}
