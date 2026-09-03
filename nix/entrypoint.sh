#!/usr/bin/env bash
#
# Container entrypoint for the Nix-built Discourse.
#
# The nixpkgs Discourse package is laid out for the NixOS module, not for a
# container: the store path is read-only, so the package ships its mutable
# directories as `config.dist` / `public.dist` and hard-codes symlinks out
# of the store to the paths systemd would have created:
#
#   share/discourse/config              -> /run/discourse/config
#   share/discourse/public              -> /run/discourse/public
#   share/discourse/app/assets/generated -> /run/discourse/assets-generated
#   share/discourse/tmp                 -> /var/lib/discourse/tmp
#   share/discourse/log                 -> /var/log/discourse
#
# Nothing creates those in a container, so this script is the systemd
# `RuntimeDirectory` + `StateDirectory` + `preStart` of the NixOS unit,
# rewritten for a pod. Keep it in step with
# nixos/modules/services/web-apps/discourse.nix when bumping nixpkgs.
#
# Configuration is env, not a generated discourse.conf: Discourse's
# GlobalSetting reads `DISCOURSE_<KEY>` for every key in
# config/discourse_defaults.conf, which lets secrets arrive as ordinary
# secretKeyRefs instead of a file this script would have to render.
set -o errexit -o pipefail -o nounset

# ── Runtime + state directories ──────────────────────────────────────────
# /run/discourse is an emptyDir (rebuilt every start, cheap and local).
# /var/lib/discourse/{uploads,backups} is the PVC — the only data here that
# is not in Postgres, and the reason the pod is not stateless.
mkdir -p /run/discourse/{config,home,public,sockets,assets-generated} \
         /var/log/discourse \
         /var/lib/discourse/{uploads,backups,tmp}

# tmp survives a crash but must not survive a restart: stale sprockets
# locks there make the next boot hang instead of fail.
rm -rf /var/lib/discourse/tmp/* || true

# ── Seed the mutable trees from the store ────────────────────────────────
# `cp -r` off a store path lands read-only; Discourse writes into all three.
cp -r "$DISCOURSE_ROOT"/share/discourse/config.dist/* /run/discourse/config/
cp -r "$DISCOURSE_ROOT"/share/discourse/public.dist/* /run/discourse/public/
cp -r "$DISCOURSE_ASSETS_GENERATED"/* /run/discourse/assets-generated/
chmod -R u+w /run/discourse/config /run/discourse/public /run/discourse/assets-generated

# Uploads and backups are the PVC, reached through the public tree the way
# the NixOS module does it — Discourse computes URLs under /uploads and
# expects the files to be there.
ln -sfn /var/lib/discourse/uploads /run/discourse/public/uploads
ln -sfn /var/lib/discourse/backups /run/discourse/public/backups
# Discourse generates images into this directory; the dist copy is u=rx.
chmod 750 /run/discourse/public/images

# ── Migrations ───────────────────────────────────────────────────────────
# Guarded by an env flag rather than run unconditionally: the Deployment is
# a single replica today, but a second one racing `db:migrate` corrupts the
# schema_migrations table. Set FORUM_RUN_MIGRATIONS=0 on any pod that is
# not the migrator.
if [ "${FORUM_RUN_MIGRATIONS:-1}" = "1" ]; then
  echo "entrypoint: running db:migrate"
  discourse-rake db:migrate
  chmod -R u+w /var/lib/discourse/tmp/
fi

# `themes:update` reaches out to git over the network for every installed
# remote theme. It is deliberately NOT run at boot: a slow or unreachable
# theme repository would turn into a crash-looping pod. Run it by hand:
#   kubectl -n forum exec deploy/forum -- discourse-rake themes:update

echo "entrypoint: starting unicorn (sidekiqs=${UNICORN_SIDEKIQS:-1})"
cd "$DISCOURSE_ROOT/share/discourse"
# unicorn_launcher supervises BOTH unicorn and the sidekiq workers, which
# is why this is one container and not two. UNICORN_SIDEKIQS controls how
# many background workers it forks.
exec bundle exec config/unicorn_launcher -E production -c config/unicorn.conf.rb
