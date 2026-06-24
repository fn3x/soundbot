{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [
          zig_0_13
        ];

        buildInputs = with pkgs; [
          alsa-lib
          libpulseaudio
        ];

        shellHook = ''
          export LD_LIBRARY_PATH="${pkgs.alsa-lib}/lib:${pkgs.libpulseaudio}/lib:$LD_LIBRARY_PATH"
        '';
      };
    };
}
