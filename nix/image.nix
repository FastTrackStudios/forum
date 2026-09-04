# OCI image for the forum, built WITHOUT a container daemon.
#
# Why not a Dockerfile: the `nix-host` CI runner executes as the
# `github-runner` user, which has no docker on PATH and is not in the
# `docker` group — reaching a daemon would mean granting CI
# effectively-root access to the workstation. Same constraint, and the same
# answer, as fts-auth: the image is a plain Nix derivation that skopeo
# pushes straight to the in-cluster registry.
#
# This is also why the upstream Discourse image is not used. `discourse/base`
# is a build base, not a runnable app: the supported path is
# `launcher bootstrap`, which runs bundle install and an asset precompile
# inside a privileged container and commits the result. That needs a daemon.
# nixpkgs already does the same work as an ordinary derivation, so the whole
# bootstrap step disappears and the plugin set becomes reproducible.

{
  pkgs,
  discourse,
  name ? "forum",
  tag ? "latest",
  # Commit this image was built from; surfaced as an OCI label.
  rev ? "dev",
}:

let
  # Scratch images have no user database. Ruby resolves the current user at
  # boot (Etc.getpwuid) and Discourse writes into $HOME; without an entry
  # for uid 1000 both fail with errors that name neither cause.
  passwd = pkgs.runCommand "${name}-passwd" { } ''
    mkdir -p $out/etc
    echo 'discourse:x:1000:1000::/run/discourse/home:/bin/sh' > $out/etc/passwd
    echo 'discourse:x:1000:' > $out/etc/group
    echo 'root:x:0:0::/root:/bin/sh' >> $out/etc/passwd
    echo 'root:x:0:' >> $out/etc/group
  '';

  # Matches the CNPG cluster's server major (ghcr.io/cloudnative-pg/postgresql:16).
  # Only the client is used.
  psql = pkgs.postgresql_16;

  # The theme, in the image. Configuring it by hand leaves it living only
  # in the database: a rebuilt forum comes up as stock Discourse, and the
  # assets I staged in a pod's /tmp vanish with the pod. Shipping it here
  # makes the look part of the deployment, and the entrypoint reapplies it
  # on every boot.
  themeDir = pkgs.runCommand "forum-theme" { } ''
    mkdir -p $out
    cp ${../theme}/*.scss ${../theme}/*.rb $out/
    cp ${../theme/assets}/* $out/
  '';

  entrypoint = pkgs.writeShellApplication {
    name = "forum-entrypoint";
    runtimeInputs = [
      pkgs.coreutils
      discourse.rake
      discourse.rubyEnv
      # `db:migrate` on an EMPTY database does not run migrations — it
      # loads db/structure.sql by shelling out to `psql`, and without it
      # the first boot dies with
      #   failed to execute: psql --set ON_ERROR_STOP=1 ... structure.sql
      # discourse.runtimeDeps does not carry it: the NixOS module gets a
      # client from services.postgresql on the same host.
      psql
    ];
    text = builtins.readFile ./entrypoint.sh;
  };
in
pkgs.dockerTools.streamLayeredImage {
  inherit name tag;

  contents = [
    discourse
    discourse.rake
    discourse.rubyEnv
    entrypoint
    passwd
    psql
    pkgs.bashInteractive
    pkgs.coreutils
    # TLS roots: Discourse talks to Postgres, SMTP and the OAuth2 provider
    # at auth.fasttrackstudio.app. Without these every outbound handshake
    # fails with an opaque certificate error.
    pkgs.cacert
  ]
  # ImageMagick, optipng, git and friends — Discourse shells out to all of
  # them for uploads and theme installs. The package lists exactly which,
  # so take that list rather than guessing.
  ++ discourse.runtimeDeps;

  # /run/discourse and /var/lib/discourse are volumes at runtime, but the
  # mount points must exist in the image or the kubelet creates them
  # root-owned and the non-root process cannot write.
  fakeRootCommands = ''
    mkdir -p ./run/discourse ./var/lib/discourse ./var/log/discourse
    chown -R 1000:1000 ./run/discourse ./var/lib/discourse ./var/log/discourse
    # Ruby's Dir.tmpdir falls back through $TMPDIR, /tmp and the cwd. A
    # scratch image has none of them writable — the cwd is this store
    # path — and rake dies with "could not find a temporary directory".
    # The chart also mounts an emptyDir here; this makes the image
    # correct on its own.
    mkdir -p ./tmp && chmod 1777 ./tmp
  '';
  enableFakechroot = true;

  config = {
    Entrypoint = [ "${entrypoint}/bin/forum-entrypoint" ];
    User = "discourse";
    WorkingDir = "${discourse}/share/discourse";
    ExposedPorts."3000/tcp" = { };
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "DISCOURSE_ROOT=${discourse}"
      "DISCOURSE_ASSETS_GENERATED=${discourse.assets.generated}"
      "FORUM_THEME_DIR=${themeDir}"
      "RAILS_ENV=production"
      "HOME=/run/discourse/home"
      # The NixOS module has nginx in front and talks to unicorn over a unix
      # socket. In a pod the Service needs a TCP port, and Rails has to serve
      # the asset tree itself — hence DISCOURSE_SERVE_STATIC_ASSETS in the
      # chart. Caddy terminates TLS and is the only thing in front.
      "UNICORN_LISTENER=0.0.0.0:3000"
      "FORUM_REV=${rev}"
    ];
    Labels = {
      "org.opencontainers.image.title" = "forum";
      "org.opencontainers.image.description" = "The FastTrackStudio community forum (Discourse)";
      "org.opencontainers.image.version" = discourse.version;
      "org.opencontainers.image.revision" = rev;
      "org.opencontainers.image.source" = "https://github.com/FastTrackStudios/forum";
    };
  };
}
