with import <nixpkgs> {};
stdenvNoCC.mkDerivation {
  name = "vmsplice-demo";
  buildInputs = [
    clang_12
    gcc11
    pv
    python38Packages.numpy
    python38Packages.pandas
    python38Packages.tqdm
  ];
}
