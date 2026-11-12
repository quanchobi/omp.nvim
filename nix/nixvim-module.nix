self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.plugins.omp-nvim;
in
{
  options.plugins.omp-nvim = {
    enable = lib.mkEnableOption "omp.nvim";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "omp-nvim.packages.\${system}.default";
      description = "The omp.nvim package.";
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      example = {
        busy = "steer";
        auto_install = false;
      };
      description = "Options passed to `require('omp_nvim').setup()`.";
    };
  };

  config = lib.mkIf cfg.enable {
    extraPlugins = [ cfg.package ];
    extraConfigLua = "require('omp_nvim').setup(${lib.nixvim.toLuaObject cfg.settings})";
  };
}
