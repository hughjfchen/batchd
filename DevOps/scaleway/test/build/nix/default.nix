{ compiler ? "ghc865" }:

let
  config = {
    packageOverrides = pkgs: rec {
      haskell = pkgs.haskell // {
        packages = pkgs.haskell.packages // {
          "${compiler}" = pkgs.haskell.packages."${compiler}".override {
            overrides = haskellPackagesNew: haskellPackagesOld: rec {

              http-api-data =
                haskellPackagesNew.callPackage ./http-api-data.nix { };
              postgresql-simple =
                haskellPackagesNew.callPackage ./postgresql-simple.nix { };
              persistent =
                haskellPackagesNew.callPackage ./persistent.nix { };
              persistent-template =
                haskellPackagesNew.callPackage ./persistent-template.nix { };
              persistent-sqlite =
                haskellPackagesNew.callPackage ./persistent-sqlite.nix { };
              persistent-mysql =
                haskellPackagesNew.callPackage ./persistent-mysql.nix { };
              persistent-postgresql =
                haskellPackagesNew.callPackage ./persistent-postgresql.nix { }; 
              esqueleto =
                haskellPackagesNew.callPackage ./esqueleto.nix { };
              heavy-logger =
                haskellPackagesNew.callPackage ./heavy-logger.nix { };
              heavy-logger-instances =
                haskellPackagesNew.callPackage ./heavy-logger-instances.nix { };
              batchd-core =
                haskellPackagesNew.callPackage ./batchd-core.nix { };
              batchd =
                haskellPackagesNew.callPackage ./batchd.nix { };
            };
          };
        };
      };
    };
  };

  pkgs = import <nixpkgs> { inherit config; };

  inherit (pkgs) dockerTools stdenv buildEnv writeText;

  batchd = pkgs.haskell.packages.${compiler}.batchd;

  static-batchd = pkgs.haskell.lib.justStaticExecutables pkgs.haskell.packages.${compiler}.batchd;

  passwd = ''
    root:x:0:0::/root:/run/current-system/sw/bin/bash
    batchd:x:90001:90001::/var/empty:/run/current-system/sw/bin/nologin
  '';

  group = ''
    root:x:0:
    nogroup:x:65534:
    batchd:x:90001:batchd
  '';

  nsswitch = ''
    hosts: files dns myhostname mymachines
  '';

  batchd-conf = ''
    para1 = "$(PARA1)"
    para2 = "$(PARA2)"
  '';

  batchd-env = stdenv.mkDerivation {
    name = "batchd-env";
    phases = [ "installPhase" "fixupPhase" ];

    installPhase = ''
      mkdir -p $out/etc/batchd
      echo '${batchd-conf}' > $out/etc/batchd/batchd.conf
      echo '${passwd}' > $out/etc/passwd
      echo '${group}' > $out/etc/group
      echo '${nsswitch}' > $out/etc/nsswitch.conf
    '';
  };

  batchd-docker =  pkgs.dockerTools.buildImage {
  name = "batchd";
  tag = batchd.version;
  
  contents = [ static-batchd
               batchd-env ];
  config = {
    Env = [ 
    "PARA1="
    "PARA2="
    ];
    User = "batchd";
    Cmd = [ "${static-batchd}/bin/batchd" "/etc/batchd/batchd.conf" ];
    ExposedPorts = {
      "5432/tcp" = {};
    };
    WorkingDir = "/data";
    Volumes = {
      "/data" = {};
    };
  };
};
in  {
  inherit batchd;
  inherit static-batchd;
  inherit batchd-docker;
}
