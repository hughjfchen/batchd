{ mkDerivation, base, binary, exceptions, fetchgit, heavy-logger
, hpack, hsyslog, mtl, stdenv, template-haskell, text
, text-format-heavy, unliftio-core
}:
mkDerivation {
  pname = "heavy-logger-instances";
  version = "0.2.1.0";
  src = fetchgit {
    url = "https://github.com/portnov/heavy-logger";
    sha256 = "1plkzby877400mx1bv6rn9nsd00a2p6rgl7x9nslwqcgwi6c40ys";
    rev = "d5394bce976565c5b3b09da211dd5cc5502fb7bd";
    fetchSubmodules = true;
  };
  postUnpack = "sourceRoot+=/heavy-logger-instances; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [
    base binary exceptions heavy-logger hsyslog mtl template-haskell
    text text-format-heavy unliftio-core
  ];
  libraryToolDepends = [ hpack ];
  testHaskellDepends = [
    base binary exceptions heavy-logger hsyslog mtl template-haskell
    text text-format-heavy unliftio-core
  ];
  prePatch = "hpack";
  homepage = "https://github.com/portnov/heavy-logger#readme";
  description = "Orphan instances for data types in heavy-logger package";
  license = stdenv.lib.licenses.bsd3;
}
