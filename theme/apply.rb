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

ASSETS = "/tmp/fts-theme"

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

archivo = upload("Archivo-latin.woff2", "theme_include")
icon = upload("icon.png", "site_setting")
log("uploads archivo=#{archivo&.url.inspect} icon=#{icon&.url.inspect}")

# ── Colour scheme ────────────────────────────────────────────────────────
# Greyscale, deliberately. Signal green / Session blue / Ignition amber /
# Keyflow purple mean "this product" and nothing else — a forum serving all
# of them gets none of them in its furniture.
COLORS = {
  # The room, darkest to lightest.
  "secondary" => "0a0a0c", # page background   (--color-bg)
  "primary" => "ededf1", # body text         (--color-fg)
  "tertiary" => "ededf1", # links, accents    (--color-fg)
  "quaternary" => "9c9ca8", # secondary accent  (--color-fg-muted)
  "header_background" => "0a0a0c",
  "header_primary" => "ededf1",
  "highlight" => "26262f", # (--color-line)
  "selected" => "16161c", # (--color-surface)
  "hover" => "131318", # (--color-deck)
  # The three states keep their meaning — a failed post must read as
  # failed, and that is not a branding decision.
  "danger" => "e04b4b",
  "success" => "2fd673",
  "love" => "ff8a2b",
}.freeze

scheme = ColorScheme.find_by(name: "FastTrackStudio")
if scheme
  COLORS.each do |name, hex|
    c = scheme.colors.find_by(name: name)
    c ? c.update!(hex: hex) : scheme.colors.create!(name: name, hex: hex)
  end
  scheme.save!
else
  scheme =
    ColorScheme.create!(
      name: "FastTrackStudio",
      colors: COLORS.map { |name, hex| { name: name, hex: hex } },
    )
end
log("scheme id=#{scheme.id} colors=#{scheme.colors.count}")

# ── Theme ────────────────────────────────────────────────────────────────
theme = Theme.find_by(name: "FastTrackStudio")
theme ||= Theme.create!(name: "FastTrackStudio", user_id: Discourse.system_user.id)
theme.color_scheme_id = scheme.id
theme.user_selectable = true
theme.save!

scss = File.read(File.join(ASSETS, "common.scss"))
scss = scss.sub("$ARCHIVO_URL", archivo&.url.to_s)
theme.set_field(target: :common, name: :scss, value: scss)
theme.save!

theme.set_default!
log("theme id=#{theme.id} default=#{theme.id == SiteSetting.default_theme_id} scss=#{scss.length}b")

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

log("identity logo=#{SiteSetting.logo&.url.inspect} title=#{SiteSetting.title.inspect}")
log("DONE")
