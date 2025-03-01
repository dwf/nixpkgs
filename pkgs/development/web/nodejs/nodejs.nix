{ lib, stdenv, fetchurl, openssl, python, zlib, libuv, util-linux, http-parser
, pkg-config, which
# Updater dependencies
, writeScript, coreutils, gnugrep, jq, curl, common-updater-scripts, nix, runtimeShell
, gnupg
, darwin, xcbuild
, procps, icu
}:

with lib;

{ enableNpm ? true, version, sha256, patches ? [] } @args:

let
  inherit (darwin.apple_sdk.frameworks) CoreServices ApplicationServices;

  majorVersion = versions.major version;
  minorVersion = versions.minor version;

  baseName = if enableNpm then "nodejs" else "nodejs-slim";

  useSharedHttpParser = !stdenv.isDarwin && versionOlder "${majorVersion}.${minorVersion}" "11.4";

  sharedLibDeps = { inherit openssl zlib libuv; } // (optionalAttrs useSharedHttpParser { inherit http-parser; });

  sharedConfigureFlags = concatMap (name: [
    "--shared-${name}"
    "--shared-${name}-libpath=${getLib sharedLibDeps.${name}}/lib"
    /** Closure notes: we explicitly avoid specifying --shared-*-includes,
     *  as that would put the paths into bin/nodejs.
     *  Including pkg-config in build inputs would also have the same effect!
     */
  ]) (builtins.attrNames sharedLibDeps) ++ [
    "--with-intl=system-icu"
  ];

  copyLibHeaders =
    map
      (name: "${getDev sharedLibDeps.${name}}/include/*")
      (builtins.attrNames sharedLibDeps);

  extraConfigFlags = optionals (!enableNpm) [ "--without-npm" ];
in

  stdenv.mkDerivation {
    inherit version;

    name = "${baseName}-${version}";

    src = fetchurl {
      url = "https://nodejs.org/dist/v${version}/node-v${version}.tar.xz";
      inherit sha256;
    };

    buildInputs = optionals stdenv.isDarwin [ CoreServices ApplicationServices ]
      ++ [ zlib libuv openssl http-parser icu ];

    nativeBuildInputs = [ which pkg-config python ]
      ++ optionals stdenv.isDarwin [ xcbuild ];

    configureFlags = let
      isCross = stdenv.hostPlatform != stdenv.buildPlatform;
      inherit (stdenv.hostPlatform) gcc isAarch32;
    in sharedConfigureFlags ++ [
      "--without-dtrace"
    ] ++ (optionals isCross [
      "--cross-compiling"
      "--without-intl"
      "--without-snapshot"
    ]) ++ (optionals (isCross && isAarch32 && hasAttr "fpu" gcc) [
      "--with-arm-fpu=${gcc.fpu}"
    ]) ++ (optionals (isCross && isAarch32 && hasAttr "float-abi" gcc) [
      "--with-arm-float-abi=${gcc.float-abi}"
    ]) ++ (optionals (isCross && isAarch32) [
      "--dest-cpu=arm"
    ]) ++ extraConfigFlags;

    configurePlatforms = [];

    dontDisableStatic = true;

    enableParallelBuilding = true;

    passthru.interpreterName = "nodejs";

    setupHook = ./setup-hook.sh;

    pos = builtins.unsafeGetAttrPos "version" args;

    inherit patches;

    postPatch = ''
      patchShebangs .

      # fix tests
      for a in test/parallel/test-child-process-env.js \
               test/parallel/test-child-process-exec-env.js \
               test/parallel/test-child-process-default-options.js \
               test/fixtures/syntax/good_syntax_shebang.js \
               test/fixtures/syntax/bad_syntax_shebang.js ; do
        substituteInPlace $a \
          --replace "/usr/bin/env" "${coreutils}/bin/env"
      done
    '' + optionalString stdenv.isDarwin ''
      sed -i 's/raise.*No Xcode or CLT version detected.*/version = "7.0.0"/' tools/gyp/pylib/gyp/xcode_emulation.py
      sed -i -e "s|tr1/type_traits|type_traits|g" \
             -e "s|std::tr1|std|" src/util.h
    '';

    checkInputs = [ procps ];
    doCheck = false; # fails 4 out of 1453 tests

    postInstall = ''
      PATH=$out/bin:$PATH patchShebangs $out

      ${optionalString (enableNpm && stdenv.hostPlatform == stdenv.buildPlatform) ''
        mkdir -p $out/share/bash-completion/completions/
        $out/bin/npm completion > $out/share/bash-completion/completions/npm
        for dir in "$out/lib/node_modules/npm/man/"*; do
          mkdir -p $out/share/man/$(basename "$dir")
          for page in "$dir"/*; do
            ln -rs $page $out/share/man/$(basename "$dir")
          done
        done
      ''}

      # install the missing headers for node-gyp
      cp -r ${concatStringsSep " " copyLibHeaders} $out/include/node
    '' + optionalString (stdenv.isDarwin && enableNpm) ''
      sed -i 's/raise.*No Xcode or CLT version detected.*/version = "7.0.0"/' $out/lib/node_modules/npm/node_modules/node-gyp/gyp/pylib/gyp/xcode_emulation.py
    '';

    passthru.updateScript = import ./update.nix {
      inherit writeScript coreutils gnugrep jq curl common-updater-scripts gnupg nix runtimeShell;
      inherit lib;
      inherit majorVersion;
    };

    meta = {
      description = "Event-driven I/O framework for the V8 JavaScript engine";
      homepage = "https://nodejs.org";
      changelog = "https://github.com/nodejs/node/releases/tag/v${version}";
      license = licenses.mit;
      maintainers = with maintainers; [ goibhniu gilligan cko marsam ];
      platforms = platforms.linux ++ platforms.darwin;
      mainProgram = "node";
    };

    passthru.python = python; # to ensure nodeEnv uses the same version
}
