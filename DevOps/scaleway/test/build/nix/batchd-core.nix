{ mkDerivation, aeson, base, bytestring, containers, dates
, directory, filepath, heavy-logger, hsyslog, localize, mtl
, persistent, persistent-template, resourcet, scotty, stdenv, syb
, template-haskell, text, text-format-heavy, th-lift, time
, unordered-containers, wai, yaml
}:
mkDerivation {
  pname = "batchd-core";
  version = "0.1.0.0";
  src = /home/chenjf/projects/my-batched/batchd/DevOps/scaleway/test/build/../../../../batchd-core;
  libraryHaskellDepends = [
    aeson base bytestring containers dates directory filepath
    heavy-logger hsyslog localize mtl persistent persistent-template
    resourcet scotty syb template-haskell text text-format-heavy
    th-lift time unordered-containers wai yaml
  ];
  homepage = "https://github.com/portnov/batchd";
  description = "Core modules of batchd, to use in batchd extensions";
  license = stdenv.lib.licenses.bsd3;
}
