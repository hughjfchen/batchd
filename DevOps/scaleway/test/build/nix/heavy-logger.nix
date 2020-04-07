{ mkDerivation, attoparsec, base, bytestring, containers
, data-default, fast-logger, fetchgit, hsyslog, lifted-base
, monad-control, monad-logger, mtl, stdenv, stm, template-haskell
, text, text-format-heavy, th-lift, th-lift-instances
, thread-local-storage, transformers-base
}:
mkDerivation {
  pname = "heavy-logger";
  version = "0.3.2.1";
  src = fetchgit {
    url = "https://github.com/portnov/heavy-logger";
    sha256 = "1plkzby877400mx1bv6rn9nsd00a2p6rgl7x9nslwqcgwi6c40ys";
    rev = "d5394bce976565c5b3b09da211dd5cc5502fb7bd";
    fetchSubmodules = true;
  };
  libraryHaskellDepends = [
    attoparsec base bytestring containers data-default fast-logger
    hsyslog lifted-base monad-control monad-logger mtl stm
    template-haskell text text-format-heavy th-lift th-lift-instances
    thread-local-storage transformers-base
  ];
  description = "Full-weight logging based on fast-logger";
  license = stdenv.lib.licenses.bsd3;
}
