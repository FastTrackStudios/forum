# Applies the FastTrackStudio look to this Discourse.
#
# Run inside the pod, with the assets already copied to /tmp/fts-theme:
#
#   kubectl -n forum exec -i deploy/forum -- \
#     bundle exec rails runner - < theme/apply.rb
#
# Idempotent: re-running updates the existing colour scheme, theme and
# uploads in place rather than accumulating duplicates. That matters
# because the alternative — configuring this by hand in /admin — is not
# reproducible, and a forum rebuilt from nothing would come up as stock
# Discourse.
#
# The palette is lifted from fasttrackstudio.app's src/styles/theme.css.
# When those tokens move, move these.

# Baked into the image; see nix/image.nix. The old hand-staged
# /tmp/fts-theme is still honoured so the scripts can be run
# against a pod by hand while iterating.
ASSETS = ENV.fetch("FORUM_THEME_DIR", "/tmp/fts-theme")

def log(msg) = STDOUT.puts("RESULT #{msg}")

# ── Uploads ──────────────────────────────────────────────────────────────
# Everything is served from this forum's own origin. The site self-hosts
# its fonts and keeps no external dependencies; a forum that pulled Archivo
# off a CDN would quietly break that promise (and leak every reader's IP to
# a third party).
def upload(filename, type)
  path = File.join(ASSETS, filename)
  return nil unless File.exist?(path)

  existing = Upload.find_by(original_filename: filename)
  return existing if existing

  File.open(path) do |f|
    UploadCreator.new(f, filename, type: type, for_theme: true).create_for(Discourse.system_user.id)
  end
end

# Archivo is no longer uploaded here — it ships as a theme ASSET in
# about.json, so Discourse uploads it and exposes the URL to the
# stylesheet as $archivo. Only the site icon remains, because a logo is a
# SITE setting rather than anything the theme owns.
icon = upload("icon.png", "site_setting")
log("uploads icon=#{icon&.url.inspect}")

# ── Theme ────────────────────────────────────────────────────────────────
# A real Discourse REMOTE THEME, imported from this repo's orphan `theme`
# branch, rather than a theme this script builds field by field.
#
# That is the difference between Discourse hosting our stylesheet and
# Discourse *managing* a theme: with a remote it tracks the upstream
# commit, can check for and pull updates on its own schedule, shows the
# source in /admin, and carries the colour scheme and the font asset from
# about.json. None of that is true of a theme assembled by a script.
#
# The branch is orphan and published by theme/publish-theme.sh, because
# Discourse requires about.json at the ROOT of the repo it clones and does
# not support a subdirectory.
THEME_REPO = "https://github.com/FastTrackStudios/forum.git"
THEME_BRANCH = "theme"

theme = Theme.find_by(name: "FastTrackStudio")

if theme&.remote_theme.nil? && theme
  # An earlier run built this by hand. Remove it so the remote import owns
  # the name, rather than leaving two themes a maintainer has to tell
  # apart in /admin.
  log("removing the hand-built theme id=#{theme.id}")
  theme.destroy!
  theme = nil
end

if theme.nil?
  theme = RemoteTheme.import_theme(THEME_REPO, Discourse.system_user, branch: THEME_BRANCH)
  log("imported theme id=#{theme.id} from #{THEME_BRANCH}")
else
  # `update_from_remote`, not `update_from_remote!` — this model has no
  # bang variant, and calling one aborts the whole run.
  theme.remote_theme.update_from_remote
  theme.save!
  log("updated theme id=#{theme.id} commit=#{theme.remote_theme.remote_version.to_s[0, 8]}")
end

# Let Discourse pull later changes itself. This is the point of the whole
# exercise: publishing the branch is enough, and nothing has to re-run
# here for a stylesheet tweak to land.
# Note: auto_update lives on Theme, not on RemoteTheme — the remote row
# holds the URL, branch and version, the theme holds the policy.
theme.update!(auto_update: true)

theme.update!(user_selectable: true)
theme.set_default!

scheme = theme.color_schemes.first || ColorScheme.find_by(name: "FastTrackStudio")
if scheme
  theme.update!(color_scheme_id: scheme.id)
  log("colour scheme id=#{scheme.id} name=#{scheme.name.inspect} colors=#{scheme.colors.count}")
end

log("theme id=#{theme.id} default=#{theme.id == SiteSetting.default_theme_id} auto_update=#{theme.auto_update} branch=#{theme.remote_theme.branch}")

# ── Identity ─────────────────────────────────────────────────────────────
if icon
  SiteSetting.logo = icon
  SiteSetting.logo_small = icon
  SiteSetting.favicon = icon
  SiteSetting.large_icon = icon
end

# Dark only. The site declares `color-scheme: dark` outright — there is no
# light variant to match, so offering one would invent a look that does not
# exist anywhere else in FTS.
SiteSetting.interface_color_selector = "disabled" if SiteSetting.respond_to?(:interface_color_selector=)
SiteSetting.title = "FastTrackStudio"
SiteSetting.site_description = "Audio-visual software for live performance and production"

# Both appear on /about and in system mail, and both were empty. An
# unattributed forum with no way to reach anyone reads as abandoned, and
# once the doors are open they are a legal expectation as much as a
# courtesy.
SiteSetting.contact_email = "info@fasttrackstudio.app"
SiteSetting.company_name = "FastTrackStudio"

# No default. With a category per product and three kinds of conversation
# under each, the composer should make someone choose rather than quietly
# filing everything into General.
SiteSetting.default_composer_category = ""

log("identity logo=#{SiteSetting.logo&.url.inspect} title=#{SiteSetting.title.inspect}")
log("DONE")
