{ mkDerivation, aeson, attoparsec, base, base64-bytestring
, blaze-html, blaze-markup, bytestring, conduit, containers
, fast-logger, haskell-src-meta, hspec, http-api-data
, monad-control, monad-logger, mtl, old-locale, path-pieces
, resource-pool, resourcet, scientific, silently, stdenv, tagged
, template-haskell, text, time, transformers, unliftio-core
, unordered-containers, vector, void
}:
mkDerivation {
  pname = "persistent";
  version = "2.8.2";
  sha256 = "696bb279259e307778dc7fbd49565c48a66429f14e793a41a13cfae0968c1ec0";
  revision = "2";
  editedCabalFile = "1y7gm3qcgizy42kf0h9hzjf27kl11dbfwvi72ggkw00apjsp9hnn";
  libraryHaskellDepends = [
    aeson attoparsec base base64-bytestring blaze-html blaze-markup
    bytestring conduit containers fast-logger haskell-src-meta
    http-api-data monad-logger mtl old-locale path-pieces resource-pool
    resourcet scientific silently tagged template-haskell text time
    transformers unliftio-core unordered-containers vector void
  ];
  testHaskellDepends = [
    aeson attoparsec base base64-bytestring blaze-html bytestring
    conduit containers fast-logger hspec http-api-data monad-control
    monad-logger mtl old-locale path-pieces resource-pool resourcet
    scientific tagged template-haskell text time transformers
    unordered-containers vector
  ];
  homepage = "http://www.yesodweb.com/book/persistent";
  description = "Type-safe, multi-backend data serialization";
  license = stdenv.lib.licenses.mit;
}
