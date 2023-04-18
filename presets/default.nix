{ config, systemConfig, lib }:

let
  inherit (lib) optionals foldAttrs optionalAttrs mkOption mkEnableOption;
  inherit (lib.types) bool;

  buildPreset = preset: name: value: let
    autogenServiceEnabled = if (preset == "essential") then true else systemConfig.services."${name}".enable;
    conditional = (value.option or autogenServiceEnabled) && config.presets."${preset}"."${name}";
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

  presetBuilder = preset: builtins.mapAttrs (name: value: buildPreset preset name value)
    (optionalAttrs config.presets."${preset}".enable (import (../presets + "/${preset}.nix") { inherit systemConfig lib; }));

  allPresets = builtins.foldl' (val: col: val // (presetBuilder col)) {} [ "essential" "system" "services" ];
  appliedPresets = foldAttrs (val: col: val ++ col) [] (builtins.attrValues allPresets);
in
{
  files = appliedPresets.files or [];
  directories = appliedPresets.directories or [];

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

    services = {
      enable = mkEnableOption ''
        service presets. Those are necessary if you're running some services, such
        as databases, monitoring solutions, and so on. It is recommended to back
        up those entries
      '';
    } // buildEntries (import ./services.nix {inherit systemConfig lib; });
  };
}
