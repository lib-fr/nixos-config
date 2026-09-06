# The Nextcloud "facerecognition" app, built from git.
#
# Upstream has not tagged a release since v0.9.70 (2025-04-22), which supports
# Nextcloud 31 only, and the appstore publishes nothing for newer platforms. So
# unlike nixpkgs' recognize.nix and memories.nix -- which just fetchurl a
# prebuilt release tarball -- this has to build the frontend itself: upstream
# .gitignore lists js/*, so the git tree ships zero JavaScript.
#
# This reproduces upstream's `make build` (minus composer, which has no runtime
# dependencies here) and `make appstore` targets.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  fetchurl,
  runCommand,
  bzip2,
  nodejs_24,
}:

let
  # `make javascript-deps` wgets these two from the tip of their default
  # branches. Pin them so the build is reproducible and needs no network.
  autocompleteJs = fetchurl {
    name = "autocomplete.js";
    url = "https://raw.githubusercontent.com/realsuayip/autocomplete/c87059294df1b05a12f5f3bc4f47bbaf103d563d/dist/autocomplete.js";
    hash = "sha256-54kOGkNbYtk8d0nmig4aYcPfRyDufs1bihACHmaScak=";
  };

  eggJs = fetchurl {
    name = "egg.js";
    url = "https://raw.githubusercontent.com/mikeflynn/egg.js/6f8c86649c77ad23bb57014bc6def2509da87bf9/egg.js";
    hash = "sha256-DjaYC8g2JUvrCzwTJWbNiqTOiHpEKetOPIMlpZrbgto=";
  };

  # URLs and target filenames copied verbatim from
  # lib/Model/DlibCnnModel/DlibCnn5Model.php and lib/Model/DlibHogModel/DlibHogModel.php.
  modelFiles = {
    mmod_human_face_detector = fetchurl {
      url = "https://github.com/davisking/dlib-models/raw/94cdb1e40b1c29c0bfcaf7355614bfe6da19460e/mmod_human_face_detector.dat.bz2";
      hash = "sha256-256eQPCSwRjV6z5kOTWyFoOBcHk1WVFVQcVqK1DZ/IQ=";
    };
    shape_predictor_5_face_landmarks = fetchurl {
      url = "https://github.com/davisking/dlib-models/raw/4af9b776281dd7d6e2e30d4a2d40458b1e254e40/shape_predictor_5_face_landmarks.dat.bz2";
      hash = "sha256-bnh7vr9cnv23k/bNHwIyMMRBMwZgXyTymfEoaflapHI=";
    };
    dlib_face_recognition_resnet_model_v1 = fetchurl {
      url = "https://github.com/davisking/dlib-models/raw/2a61575dd45d818271c085ff8cd747613a48f20d/dlib_face_recognition_resnet_model_v1.dat.bz2";
      hash = "sha256-q7H2EEHkNEZYVc6Bwr1UboMNKLy+2NJ/++W7QIsRVTo=";
    };
  };

  # `occ face:setup -m N` normally downloads these into appdata at runtime. Point
  # the `facerecognition.model_path` system setting at this instead: install() is a
  # no-op once isInstalled() sees the files, and ModelService skips its mkdir when
  # the directory already exists, so a read-only store path works.
  #
  # Layout is what ModelService::getFileModelPath() expects: <root>/<modelId>/<filename>
  models =
    runCommand "facerecognition-models"
      {
        nativeBuildInputs = [ bzip2 ];
        meta.description = "dlib models for the Nextcloud facerecognition app";
      }
      ''
        mkdir -p $out/1 $out/3

        # Model 1: DlibCnn5Model, upstream's default.
        bunzip2 -c ${modelFiles.mmod_human_face_detector} > $out/1/mmod_human_face_detector.dat
        bunzip2 -c ${modelFiles.shape_predictor_5_face_landmarks} > $out/1/shape_predictor_5_face_landmarks.dat
        bunzip2 -c ${modelFiles.dlib_face_recognition_resnet_model_v1} > $out/1/dlib_face_recognition_resnet_model_v1.dat

        # Model 3: DlibHogModel. Same two blobs; seeding it also completes
        # model 4 (DlibCnnHogModel), which composes models 1 and 3.
        cp $out/1/shape_predictor_5_face_landmarks.dat $out/3/
        cp $out/1/dlib_face_recognition_resnet_model_v1.dat $out/3/
      '';
in

buildNpmPackage (finalAttrs: {
  pname = "nextcloud-app-facerecognition";
  # appinfo/info.xml says 0.9.95, but upstream has never tagged it.
  version = "0.9.95-unstable-2026-08-04";

  src = fetchFromGitHub {
    owner = "matiasdelellis";
    repo = "facerecognition";
    rev = "b6451bb58e18167c987084399c875cd81dd6e98b";
    hash = "sha256-ES6IaxlJNUhOHWM2BU/Y4C6Pqh824sHxwGNJDspPOiA=";
  };

  nodejs = nodejs_24; # package.json: engines.node = "^24.0.0"

  # nix run nixpkgs#prefetch-npm-deps -- <src>/package-lock.json
  npmDepsHash = "sha256-0ZapLtm85T7vYZZ7q8tAR5wmejAEqWUDnwBQZK15d1Q=";

  # Nothing here needs a native rebuild -- webpack, babel, terser and vue-loader
  # are all pure JS, and the lockfile has no git dependencies. Skipping the
  # lifecycle scripts keeps `npm rebuild` from reaching for the network.
  npmRebuildFlags = [ "--ignore-scripts" ];

  postPatch = ''
    # webpack's ProgressPlugin emits a line per module when stdout is not a tty,
    # which buries the real build log. `npm ci` diffs package-lock.json and the
    # dependency fields of package.json, never `scripts`, so this does not
    # invalidate npmDepsHash.
    substituteInPlace package.json \
      --replace-fail 'webpack --node-env production --progress' \
                     'webpack --node-env production'
  '';

  env = {
    BROWSERSLIST_IGNORE_OLD_DATA = "1"; # caniuse-lite is pinned by the lockfile
    NODE_OPTIONS = "--max-old-space-size=4096"; # @nextcloud/vue 8 + terser is hungry
  };

  # Has to run via `npm run`: @nextcloud/webpack-vue-config takes the bundle name
  # prefix from npm_package_name, which only npm exports. Invoking webpack
  # directly would silently emit undefined-admin.js and friends.
  npmBuildScript = "build";

  # The rest of upstream's `build` target: javascript-deps and js-templates.
  # These must come after webpack -- webpack.config.js sets
  # output.clean = { keep: /vendor\// }, so anything else already in js/ is wiped.
  postBuild = ''
    mkdir -p js/vendor
    install -m644 node_modules/handlebars/dist/handlebars.js js/vendor/handlebars.js
    install -m644 node_modules/lozad/dist/lozad.js js/vendor/lozad.js
    install -m644 ${autocompleteJs} js/vendor/autocomplete.js
    install -m644 ${eggJs} js/vendor/egg.js

    node node_modules/handlebars/bin/handlebars src/templates \
      -f js/facerecognition-templates.js
  '';

  # This is a Nextcloud app tree, not an installable npm package: $out is the app
  # root, so that services.nextcloud.extraApps finds $out/appinfo/info.xml.
  dontNpmInstall = true;

  # $out is an app tree, not an FHS prefix. Left alone, move-docs.sh relocates the
  # app's own doc/ to share/doc/, but upstream ships it at the app root. Listing
  # the other two rather than [ ] is deliberate: the hook expands
  # ${forceShare:-man doc info}, so an empty value falls back to the default.
  forceShare = [
    "man"
    "info"
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    # Mirrors the rsync filter of upstream's `make appstore`. Dotfiles are dropped
    # implicitly because bash's `*` does not match them (i.e. --exclude='.*').
    for entry in *; do
      case "$entry" in
        build | cli | composer* | translation* | node_modules | Makefile | package*json | phpunit*xml | psalm.xml | screenshots | src | tests | webpack* | vendor)
          continue
          ;;
      esac
      cp -r "$entry" "$out/"
    done
    rm -f "$out"/js/*.map
    rm -rf "$out"/js/templates

    # Fail loudly rather than ship a half-built app. Every file below is requested
    # by the app's own PHP: templates/settings/{personal,admin}.php and
    # lib/Listener/LoadSidebarListener.php.
    for f in appinfo/info.xml \
      js/facerecognition-{admin,personal,sidebar,dialogs,templates}.js \
      js/vendor/{handlebars,lozad,autocomplete,egg}.js; do
      if [ ! -f "$out/$f" ]; then
        echo "ERROR: expected build output $f is missing from \$out" >&2
        ls -la "$out/js" >&2 || true
        exit 1
      fi
    done

    runHook postInstall
  '';

  passthru = { inherit models; };

  meta = {
    description = "Nextcloud app that detects and groups faces in your photos";
    longDescription = ''
      Built from git master: upstream's newest release (v0.9.70) supports only
      Nextcloud 31, while master targets Nextcloud 34.

      Needs the pdlib and bz2 PHP extensions at runtime, see
      services.nextcloud.phpExtraExtensions. The dlib models are available as
      the `models` passthru; point the `facerecognition.model_path` system
      setting at it to avoid downloading them at setup time.
    '';
    homepage = "https://github.com/matiasdelellis/facerecognition";
    changelog = "https://github.com/matiasdelellis/facerecognition/blob/${finalAttrs.src.rev}/CHANGELOG.md";
    license = lib.licenses.agpl3Plus;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    platforms = lib.platforms.all;
  };
})
