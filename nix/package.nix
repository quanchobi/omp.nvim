{
  lib,
  vimUtils,
  version,
}:
vimUtils.buildVimPlugin {
  pname = "omp.nvim";
  inherit version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../lua
      ../plugin
      ../extension
      ../LICENSE
      ../README.md
    ];
  };
  nvimRequireCheck = "omp_nvim";
  meta = {
    description = "Send editor context to a running omp session from Neovim";
    homepage = "https://github.com/quanchobi/omp.nvim";
    license = lib.licenses.mit;
  };
}
