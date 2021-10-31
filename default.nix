with import <nixpkgs> {};
stdenvNoCC.mkDerivation {
  name = "vmsplice-demo";
  buildInputs = [ clang_12 pv ];
}
