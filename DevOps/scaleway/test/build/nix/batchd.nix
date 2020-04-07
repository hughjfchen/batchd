{ mkDerivation, aeson, base, batchd-core, boxes, bytestring
, conduit, conduit-combinators, conduit-extra, connection
, containers, cryptonite, data-default, dates, ekg-core, ekg-json
, esqueleto, exceptions, fast-logger, filepath, Glob, heavy-logger
, heavy-logger-instances, hsyslog, http-client, http-client-tls
, http-types, libssh2, libssh2-conduit, localize, microlens
, monad-metrics, mtl, optparse-applicative, parsec, persistent
, persistent-postgresql, persistent-sqlite, persistent-template
, process, readline, resourcet, scotty, stdenv, syb, text
, text-format-heavy, th-lift, time, tls, unix, unliftio-core
, unordered-containers, vault, vector, wai, wai-cors, wai-extra
, wai-middleware-metrics, wai-middleware-static, warp, x509-store
, yaml
}:
mkDerivation {
  pname = "batchd";
  version = "0.1.0.0";
  src = /home/chenjf/projects/my-batched/batchd/DevOps/scaleway/test/build/../../../..;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson base batchd-core boxes bytestring conduit conduit-combinators
    conduit-extra connection containers cryptonite data-default dates
    ekg-core ekg-json esqueleto exceptions fast-logger filepath Glob
    heavy-logger heavy-logger-instances hsyslog http-client
    http-client-tls http-types libssh2 libssh2-conduit localize
    microlens monad-metrics mtl optparse-applicative parsec persistent
    persistent-postgresql persistent-sqlite persistent-template process
    readline resourcet scotty syb text text-format-heavy th-lift time
    tls unix unliftio-core unordered-containers vault vector wai
    wai-cors wai-extra wai-middleware-metrics wai-middleware-static
    warp x509-store yaml
  ];
  homepage = "https://github.com/portnov/batchd";
  description = "Batch processing toolset for Linux / Unix";
  license = stdenv.lib.licenses.bsd3;
}
