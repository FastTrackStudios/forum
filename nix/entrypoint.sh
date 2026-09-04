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

# ── A temporary directory Ruby will accept ───────────────────────────────
# Ruby's Dir.tmpdir walks $TMPDIR, /tmp and the cwd, and REJECTS any
# candidate that is world-writable without the sticky bit. An emptyDir
# mount is 0777 with no sticky bit and is owned by root, so the container
# cannot chmod it — which is why merely HAVING a /tmp was not enough:
#
#   /tmp is world-writable: /tmp
#   . is not writable: /nix/store/...-discourse/share/discourse
#   rake aborted! ArgumentError: could not find a temporary directory
#
# A subdirectory we create ourselves is owned by us and 0700, so it
# passes. Everything Ruby does — including the schema load — goes here.
export TMPDIR=/tmp/discourse
mkdir -p "$TMPDIR"
chmod 700 "$TMPDIR"

# ── Site settings ────────────────────────────────────────────────────────
# nixpkgs PATCHES Discourse to load this file as an extra site-settings
# source (app/models/site_setting.rb -> SiteSettings::YamlLoader), and it
# is not optional: a missing file is a hard
#   URGENT: Failed to initialize site default:
#   Errno::ENOENT ... config/nixos_site_settings.json
# before any migration runs. The NixOS unit generates it in preStart, so
# nothing upstream ever sees it absent.
#
# Shape is { category = { setting = value; } }, e.g.
#   {"login":{"enable_local_logins":false}}
# `{}` is the valid empty form. FORUM_SITE_SETTINGS_JSON lets the chart
# supply settings without rebuilding the image.
printf '%s' "${FORUM_SITE_SETTINGS_JSON:-{\}}" > /run/discourse/config/nixos_site_settings.json

# ── Migrations ───────────────────────────────────────────────────────────
# Guarded by an env flag rather than run unconditionally: the Deployment is
# a single replica today, but a second one racing `db:migrate` corrupts the
# schema_migrations table. Set FORUM_RUN_MIGRATIONS=0 on any pod that is
# not the migrator.
if [ "${FORUM_RUN_MIGRATIONS:-1}" = "1" ]; then
  echo "entrypoint: running db:migrate"
  discourse-rake db:migrate
  # Best-effort. The NixOS unit owns this directory outright; here it is
  # an emptyDir whose MOUNT ROOT belongs to root, so chmod on it fails
  # with EPERM and, under `set -e`, killed the boot immediately after a
  # successful migration. The files inside are ours — we created them —
  # so there is nothing this needs to fix.
  chmod -R u+w /var/lib/discourse/tmp/ 2>/dev/null || true
fi

# `themes:update` reaches out to git over the network for every installed
# remote theme. It is deliberately NOT run at boot: a slow or unreachable
# theme repository would turn into a crash-looping pod. Run it by hand:
#   kubectl -n forum exec deploy/forum -- discourse-rake themes:update

# ── The FastTrackStudio look ─────────────────────────────────────────────
# Reapplied on every boot, not configured once by hand. All three scripts
# are idempotent, so this converges rather than accumulating: a forum
# rebuilt from an empty database comes up already themed, with its product
# categories, instead of as stock Discourse.
#
# emoji.rb runs as its OWN process and first. Category#emoji is validated
# by `Emoji.exists?`, which reads a per-process memo, so an emoji created
# and assigned in one run fails validation for an emoji that provably
# exists a line earlier — and Emoji.clear_cache does not help.
#
# Set FORUM_APPLY_THEME=0 to boot without touching any of it.
# Runs in the BACKGROUND, after unicorn is told to start. Three Rails
# boots is roughly two minutes, and blocking on them meant every restart —
# including one triggered by toggling a plugin from the admin UI — took the
# forum down for that whole window with a 502. The theme converging a
# minute after the site is back is a far better trade than the site being
# gone until the theme is perfect.
#
# The scripts are idempotent, so on an already-configured forum this is a
# no-op that nobody sees. On a genuinely fresh database the first minute
# looks like stock Discourse and then corrects itself.
if [ "${FORUM_APPLY_THEME:-1}" = "1" ] && [ -d "${FORUM_THEME_DIR:-}" ]; then
  (
    echo "entrypoint: applying theme from $FORUM_THEME_DIR (background)"
    bundle exec rails runner "$FORUM_THEME_DIR/emoji.rb" || echo "entrypoint: emoji step failed, continuing"
    bundle exec rails runner "$FORUM_THEME_DIR/apply.rb" || echo "entrypoint: theme step failed, continuing"
    bundle exec rails runner "$FORUM_THEME_DIR/categories.rb" || echo "entrypoint: categories step failed, continuing"
    echo "entrypoint: theme applied"
  ) &
fi

echo "entrypoint: starting unicorn (sidekiqs=${UNICORN_SIDEKIQS:-1})"
cd "$DISCOURSE_ROOT/share/discourse"
# unicorn_launcher supervises BOTH unicorn and the sidekiq workers, which
# is why this is one container and not two. UNICORN_SIDEKIQS controls how
# many background workers it forks.
exec bundle exec config/unicorn_launcher -E production -c config/unicorn.conf.rb
