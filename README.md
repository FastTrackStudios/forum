# forum

The FastTrackStudio community forum — [Discourse](https://www.discourse.org/),
served at `forum.fasttrackstudio.app`, signed in to with the same account as
Task, Session, Signal, Keyflow and Ignition.

This repo is the *deployment*, not the software. Discourse is upstream; what
lives here is the image build, the Helm chart, and the FastTrackStudio-specific
configuration. The Argo CD `Application`, the database and the secrets are
declared in the cluster repo (`~/.starcommand`, `modules/services/forum`) — so
this repo holds the code and the chart, and the cluster holds what actually
runs. Same split as [`fts-auth`](https://github.com/FastTrackStudios/fts-auth).

## Why this shape

Three obvious paths were rejected, and it is worth writing down why so nobody
re-litigates them:

**The Bitnami chart.** Effective 28 August 2025 Broadcom restructured the
Bitnami catalogue: only the `:latest` tag stays free, and every pinned version
moved to `bitnamilegacy/*`, which is frozen and receives no security patches.
A public forum running frozen images is a liability, and the charts no longer
deploy without overriding every image reference anyway.

**The upstream `discourse/base` image.** `discourse/base` is a *build* base,
not a runnable application. The supported path is `launcher bootstrap`, which
runs `bundle install` and an asset precompile inside a privileged container
and commits the result. That needs a Docker daemon, and the `nix-host` CI
runner deliberately has none — it executes as the `github-runner` user, which
is not in the `docker` group, because putting it there would give CI
effectively-root access to the workstation.

**A NixOS host service.** nixpkgs has a perfectly good `services.discourse`,
but every route in this cluster resolves to a `*.svc` address, and the ask was
for GitOps. A host service is neither.

So: nixpkgs already builds Discourse — gems, assets, plugins — as an ordinary
derivation. `nix build .#image` wraps that in an OCI image with no daemon in
sight, skopeo pushes it to the LAN registry, and the whole `launcher bootstrap`
step disappears. The plugin set becomes a line in `flake.nix` instead of a
`app.yml` on a pet VM.

The cost is that the Discourse version tracks nixpkgs rather than upstream
releases. `nixos-unstable` currently carries **2026.7.1**, which is current;
if it ever lags a security release, the fix is to bump `flake.lock` (or
override the `src` and gemset), not to switch strategies.

## Layout

```
flake.nix                      # nixpkgs pin + the plugin set
nix/image.nix                  # dockerTools.streamLayeredImage
nix/entrypoint.sh              # the NixOS unit's preStart, rewritten for a pod
deploy/chart/forum/            # what Argo CD syncs
.github/workflows/deploy.yml   # build -> LAN registry (self-hosted runner)
```

### The entrypoint is load-bearing

The nixpkgs package is laid out for the NixOS module: the store path is
read-only, so it ships `config.dist` / `public.dist` and hard-codes symlinks
out of the store to the paths systemd would have created (`/run/discourse/…`,
`/var/lib/discourse/tmp`, `/var/log/discourse`). Nothing creates those in a
container. `nix/entrypoint.sh` is that unit's `RuntimeDirectory` +
`StateDirectory` + `preStart`, rewritten for a pod. **When bumping nixpkgs,
diff `nixos/modules/services/web-apps/discourse.nix` against it.**

`nixos_site_settings.json` is the sharp edge. nixpkgs *patches* Discourse to
load that file as an extra site-settings source, and a missing file is fatal
before any migration runs (`URGENT: Failed to initialize site default:
Errno::ENOENT`). The NixOS unit writes it in `preStart`, so nothing upstream
ever meets it absent. The entrypoint writes it from the chart's
`siteSettings` value.

The image also carries a **postgres client**. `db:migrate` against an empty
database does not run migrations at all — it loads `db/structure.sql` by
shelling out to `psql`. `discourse.runtimeDeps` does not include it, because
the NixOS module gets a client from `services.postgresql` on the same host,
and a container has no such neighbour.

You will also see `Permission denied @ dir_s_mkdir` for a plugin's `public`
directory at boot. Discourse tries to create plugin asset symlinks inside its
own tree, which here is the read-only Nix store. It is a warning, not a
failure — the NixOS module has the same layout — and it only affects bundled
plugins that are not enabled.

**mini_racer does not survive the fork here**, and this is the one that cost
the most. Discourse defaults `mini_racer_single_threaded = true`, which takes
the branch in `Discourse.before_fork` that only sends `low_memory_notification`
and *keeps* the V8 contexts, trusting single-threaded V8 across `fork()`. In
this build it does not survive: every pitchfork worker died with

```
[BUG] Segmentation fault
mini_racer_extension.so(v8::Context::Enter)
mini_racer_extension.so(v8_single_threaded_enter)
```

The deployment therefore sets `DISCOURSE_MINI_RACER_SINGLE_THREADED=false`,
taking the other branch — whose own comment reads *"V8 does not support
forking, make sure all contexts are disposed"* — so each worker builds a fresh
context after fork.

The symptom is worth remembering because it is so misleading: `/srv/status`
kept answering 200, since it touches no JavaScript. The pod looked healthy
while every real page render killed a worker, which respawned every 4-6
seconds forever, and the homepage simply never returned.

**`force_https` is not optional.** Caddy terminates TLS and forwards plain
HTTP, so without it Discourse builds `http://` URLs — including the OAuth
`redirect_uri`, which the issuer refuses as unregistered before drawing a
login page. It is pinned in the cluster module's site settings.

One container, not two: `unicorn_launcher` supervises both unicorn and the
sidekiq workers, so `UNICORN_SIDEKIQS` is the knob rather than a second
Deployment. That is also why `replicaCount` is 1 and not a scaling dial — two
pods race `db:migrate` on boot and double the background workers against the
same queues. To scale, raise `unicorn.workers`, then split sidekiq out into
its own Deployment with `FORUM_RUN_MIGRATIONS=0` before ever raising replicas.

Configuration is environment, not a rendered `discourse.conf`: Discourse's
`GlobalSetting` reads `DISCOURSE_<KEY>` for every key in
`config/discourse_defaults.conf`, which lets secrets arrive as ordinary
`secretKeyRef`s.

## Single sign-on

One account across the forum and the apps, via
[`fts-auth`](https://github.com/FastTrackStudios/fts-auth) at
`auth.fasttrackstudio.app`. The plugin is **`discourse-oauth2-basic`**, and
the choice is forced:

- `discourse-openid-connect` verifies the `id_token`. fts-auth signs HS256
  with its own server-wide `AUTH_SECRET`, not with the client secret, so the
  verification cannot succeed. Fixing that properly means RS256/ES256 support
  upstream in `architect-auth`.
- `discourse-oauth2-basic` never touches the `id_token` — it exchanges the
  code and then reads `/oauth2/userinfo`, which fts-auth serves as
  `{sub, email, email_verified, name, picture}`. That maps straight onto the
  plugin's JSON-path settings.

Two details that will otherwise cost an afternoon:

- **The token endpoint reads `client_secret` from the form body only**, never
  from an `Authorization: Basic` header. Set `oauth2_send_auth_header = false`
  and `oauth2_send_auth_body = true`.
- **PKCE.** `discourse-oauth2-basic` does not implement it, and fts-auth's
  `require_pkce` defaults to true with no env override, so `/oauth2/authorize`
  rejects the forum before a login page is ever drawn. This needs a change in
  `architect`: require PKCE for *public* clients, treat it as optional for
  confidential ones — which is the standard rule, and correct regardless of
  this deployment.

Site settings to apply once the client is registered:

| Setting | Value |
|---|---|
| `oauth2_client_id` | `forum` |
| `oauth2_client_secret` | from `forum-secrets` |
| `oauth2_authorize_url` | `https://auth.fasttrackstudio.app/oauth2/authorize` |
| `oauth2_token_url` | `https://auth.fasttrackstudio.app/oauth2/token` |
| `oauth2_user_json_url` | `https://auth.fasttrackstudio.app/oauth2/userinfo` |
| `oauth2_json_user_id_path` | `sub` |
| `oauth2_json_email_path` | `email` |
| `oauth2_json_name_path` | `name` |
| `oauth2_json_avatar_path` | `picture` |
| `oauth2_scope` | `openid email profile` |
| `oauth2_send_auth_header` | `false` |
| `oauth2_send_auth_body` | `true` |
| `oauth2_button_title` | `Sign in with FastTrackStudio` |

**Leave `oauth2_email_verified` off.** fts-auth runs with
`AUTH_REQUIRE_EMAIL_VERIFICATION=false`, so an address at the issuer is not
proof of control of that mailbox. Turning this on would let anyone who signs
up at the issuer with your email address walk into the forum as you. Revisit
only after the issuer verifies email.

Once SSO works, turn `enable_local_logins` off so the forum has exactly one
door.

## Theme

`theme/` holds the FastTrackStudio look: `common.scss` plus an idempotent
`apply.rb` that creates the colour scheme, theme and uploads and sets it
default. Applied with the assets staged in the pod:

```sh
kubectl -n forum cp <asset> forum/<pod>:/tmp/fts-theme/
kubectl -n forum exec -i deploy/forum --   env TMPDIR=/tmp/discourse bundle exec rails runner - < theme/apply.rb
```

`TMPDIR` is required: `kubectl exec` starts a fresh process that does not
inherit the one the entrypoint exports, and rake dies without it.

**The theme is part of the image, and applied on DEPLOY — not on boot.**
`theme/` is copied into the store by `nix/image.nix` and exposed as
`FORUM_THEME_DIR`. An Argo CD **PostSync hook Job** runs the same image
with `FORUM_MODE=seed`, which builds the runtime scaffolding, runs the
three scripts, and exits.

It used to run in the entrypoint on every pod boot. That was wrong twice
over: it coupled "the site is up" to "configuration has converged" — so
enabling two plugins took the forum down for three minutes — and it re-ran
identical work on every unrelated restart. Configuration changes on
deploy, so it converges on deploy.

Seed mode shares `entrypoint.sh` rather than re-implementing the
scaffolding, because everything the scripts need (the config tree from
`config.dist`, `nixos_site_settings.json`, a TMPDIR Ruby will accept) is
built there, and a second copy would drift.

Site settings are separate and need no script at all: nixpkgs patches
Discourse to read `nixos_site_settings.json`, so the chart's
`siteSettings` value is genuinely declarative.

`theme/emoji.rb` then `theme/categories.rb` build the product categories —
Signal, Session, Ignition and Keyflow, each with Feature Requests and
Support beneath it. Run emoji.rb FIRST and as its own process:
`Category#emoji` is validated by `Emoji.exists?`, which reads a per-process
memo, so an emoji created and assigned in one run fails validation for an
emoji that provably exists a line earlier.

The category badge is the app's shipped icon, registered as a custom emoji
rather than a category logo. `style_type: "icon"` only accepts FontAwesome
names, and a category *logo* renders as a full-width plate that buries the
list — the emoji renders at badge size everywhere a category is named.

The palette and type roles are lifted from `fasttrackstudio.app`'s
`src/styles/{theme,base,fonts}.css` — that file is the source of truth, and
these move when it moves. Archivo is uploaded to this forum and served from
its own origin, matching the site's no-CDN stance; JetBrains Mono already
ships with Discourse.

Chrome is greyscale on purpose. Signal green, Session blue, Ignition amber
and Keyflow purple mean "this product" and nothing else, so a forum serving
all of them gets none of them in its furniture — hierarchy comes from
weight, spacing and rules. Only danger/success/love keep colour, because "your
post failed" is not a branding decision.

## Managing it

Two ways in, for two different jobs.

**The boot scripts** (above) are the source of truth for anything that must
survive a rebuild. An API key configures a forum that already exists; only
the image can bring one back from an empty database.

**The REST API** is better for everything interactive or external — moving
a topic, filing a bug from another service, poking at settings. It also
fails legibly: a bad setting comes back as a 422 with a message, where a
script dies partway and silently leaves everything after it unapplied
(which happened twice here — `category_featured_topics` no longer exists,
and `categories_topics` rejects anything below 5).

The key lives at `starcommand/selfhost/apps/forum/discourse_api_key` in
nix-secrets:

```sh
K=$(sops -d --output-type json ~/nix-secrets/sops/users/starcommand.yaml \
     | jq -r .starcommand.selfhost.apps.forum.discourse_api_key)
curl -H "Api-Key: $K" -H "Api-Username: cody" \
     https://forum.fasttrackstudio.app/categories.json
```

Discourse reveals a key only at creation and stores a hash, so a lost value
cannot be recovered — revoke it in `/admin/api/keys` and mint another.

## Deploying

Argo CD syncs `deploy/chart/forum`. Image builds run on push to `main` (see
the workflow); `argocd-image-updater` rolls the Deployment by digest.

First-run checklist, in the cluster repo:

1. **Database.** A CNPG `Database` + owner role for `discourse` on `pg-main`,
   in the `databases` service.
2. **Secrets.** `forum-secrets` with `secret-key-base`, `database-password`,
   `smtp-username`, `smtp-password`, `oauth2-client-secret` — from nix-secrets
   via `just gen-secrets`. Never committed here. `secret-key-base` is
   deliberately *not* derived from `AUTH_SECRET`: separate blast radii.
3. **OIDC client.** A confidential client `forum` registered in fts-auth's
   `AUTH_OIDC_CLIENTS`, redirect URI
   `https://forum.fasttrackstudio.app/auth/oauth2_basic/callback`.
4. **Mail.** Discourse cannot finish its own install without working outbound
   mail — the admin activation email is step one. There is no in-cluster
   relay, so this points at a transactional provider, whose DKIM/SPF/DMARC
   records must be published for `mail.domain`.
5. **Ingress target.** The external-dns annotation comes from
   `constants.tunnelTarget` in the cluster module, so the hostname resolves
   through the Cloudflare tunnel.
6. **Argo CD access.** This repo is public, like `fts-auth`, so Argo reads the
   chart without a credential. Nothing secret is in here — the secrets are all
   cluster-side, which is what makes that safe. Keep it that way: no SMTP
   credentials, no client secret, no `secret_key_base` in this tree, ever.

## Backups

Postgres is covered by the cluster's nightly `pg-dumpall` to the NAS. The
uploads PVC is **not** — it is the one volume whose loss cannot be recovered
from a dump, and its `Prune=false,Delete=false` annotation only protects it
from Argo, not from the NAS. Discourse's own `/admin/backups` writes into the
same PVC, which is not a backup either.

## Operating

```sh
# Rails console
kubectl -n forum exec -it deploy/forum -- discourse-rake console

# Update remote themes (deliberately not run at boot — an unreachable theme
# repository would turn into a crash-looping pod)
kubectl -n forum exec deploy/forum -- discourse-rake themes:update

# Make someone an admin before SSO is wired up
kubectl -n forum exec -it deploy/forum -- discourse-rake admin:create
```

## Eventually: Task

The long-term intent is to move this onto Task's own `threads` feature
(`task/features/threads`), which is already a universal conversation
primitive — `Thread` anchored to any `(entity_type, entity_id)`, `Message`
with reply chains and provenance for ingesting forge, email and chat
conversations. The payoff is that a forum thread and a Task issue become the
same entity rather than a copy-paste.

That is not a reason to delay this. Discourse earns its keep now, and
`Thread.source_kind` already has a `"forge"` case for ingesting conversations
from elsewhere when the time comes.

## Licence

The deployment code here is GPL-3.0-or-later, like the rest of FTS. Discourse
itself is GPL-2.0-or-later and belongs to its authors.
