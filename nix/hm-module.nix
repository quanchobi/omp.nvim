self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omp-nvim;
  agentDirs = [ "${cfg.configDir}/agent" ] ++ map (p: "${cfg.configDir}/profiles/${p}/agent") cfg.profiles;
in
{
  options.programs.omp-nvim = {
    enable = lib.mkEnableOption "the omp.nvim bridge extension for omp";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "omp-nvim.packages.\${system}.default";
      description = "omp.nvim package whose bridge extension is installed. Use the same package as your Neovim plugin.";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".omp";
      description = "omp's user config root relative to $HOME (omp's PI_CONFIG_DIR).";
    };

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "work" ];
      description = "Named omp profiles (`omp --profile <name>`) that also load the bridge.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.listToAttrs (
      map (
        dir:
        lib.nameValuePair "${dir}/extensions/omp-nvim-bridge.ts" {
          source = "${cfg.package}/extension/omp-nvim-bridge.ts";
        }
      ) agentDirs
    );
  };
}
