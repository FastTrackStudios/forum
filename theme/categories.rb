# The product categories: one per app, each with Feature Requests and
# Support beneath it.
#
#   kubectl -n forum exec -i deploy/forum -- \
#     env TMPDIR=/tmp/discourse bundle exec rails runner - < theme/categories.rb
#
# Idempotent — matches on slug, so re-running updates colours, logos and
# descriptions in place rather than making a second "Signal".
#
# On the colours: the site's tokens say the product colours mean "this
# product" and nothing else, which is why the forum's CHROME is greyscale.
# A category *for* a product is that product's identity, so this is the one
# place they belong. Each is taken from src/styles/theme.css, which took it
# from that app's shipped icon — so the category badge, the icon above it
# and the beam lighting it on the marketing site are all one colour.

# Baked into the image; see nix/image.nix. The old hand-staged
# /tmp/fts-theme is still honoured so the scripts can be run
# against a pod by hand while iterating.
ASSETS = ENV.fetch("FORUM_THEME_DIR", "/tmp/fts-theme")

def log(msg) = STDOUT.puts("RESULT #{msg}")

# Mix toward white / toward the void, keeping the hue. The children read as
# the parent at two different levels rather than as three unrelated colours
# — the same trick the site plays with one type family at two widths.
def mix(hex, target, amount)
  a = hex.scan(/../).map { |c| c.to_i(16) }
  b = target.scan(/../).map { |c| c.to_i(16) }
  a.zip(b).map { |x, y| (x + (y - x) * amount).round.clamp(0, 255) }.map { |v| "%02x" % v }.join
end

# White on a dark badge, void on a light one. Discourse does not work this
# out for you, and an unreadable badge is worse than a plain one.
def text_for(hex)
  r, g, b = hex.scan(/../).map { |c| c.to_i(16) }
  luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
  luminance > 0.6 ? "0a0a0c" : "ffffff"
end

PRODUCTS = [
  {
    slug: "signal",
    name: "Signal",
    color: "2fd673",
    description: "The Signal Suite — the audio engine, instrument rigs, sampler, and the CLAP/VST3 plugin set.",
  },
  {
    slug: "session",
    name: "Session",
    color: "2e9bff",
    description: "Setlists, songs, notation, the guide, and the Session app that runs the show.",
  },
  {
    slug: "ignition",
    name: "Ignition",
    color: "ff8a2b",
    description: "The lighting console, the real-time DMX visualizer, and projection mapping.",
  },
  {
    slug: "keyflow",
    name: "Keyflow",
    color: "a78bfa",
    description: "The chart language — writing, reading and sharing Keyflow charts.",
  },
].freeze

CHILDREN = [
  {
    suffix: "feature-requests",
    name: "Feature Requests",
    # Lifted toward the house white: asking for something is the forward,
    # brighter half of the conversation.
    tint: ["ededf1", 0.34],
    description: ->(p) { "Ideas and requests for #{p[:name]}. Say what you are trying to do, not only what you want added." },
  },
  {
    suffix: "support",
    name: "Support",
    # Settled back toward the deck. Still legible on the dark ground, but
    # it does not compete with the request category next to it.
    tint: ["131318", 0.30],
    description: ->(p) { "Help with #{p[:name]} — something broken, confusing, or not behaving the way you expected." },
  },
].freeze

admin = User.find_by(admin: true) || Discourse.system_user

def upsert(name:, slug:, color:, description:, parent: nil, admin:)
  scope = Category.where(slug: slug)
  scope = parent ? scope.where(parent_category_id: parent.id) : scope.where(parent_category_id: nil)
  category = scope.first

  attrs = {
    name: name,
    color: color,
    text_color: text_for(color),
    parent_category_id: parent&.id,
  }

  if category
    category.update!(attrs)
  else
    category = Category.create!(attrs.merge(slug: slug, user_id: admin.id))
  end

  # The description is the category's "About" topic's first post, not a
  # column — writing it any other way silently does nothing.
  category.update_column(:description, description)

  # The badge IS the app icon, rather than a coloured square with the icon
  # dumped into the description as a plate.
  #
  # Discourse's `style_type: "icon"` only takes FontAwesome names, so a
  # shipped product icon cannot go there. A CUSTOM EMOJI can: it renders as
  # a real image at badge size in every place a category is named — topic
  # lists, breadcrumbs, the sidebar, the composer — which a category logo
  # never does.
  #
  # The emoji itself is registered by theme/emoji.rb, which MUST have run
  # in an earlier process: `Emoji.exists?` reads a per-process memo, so an
  # emoji created in this run would still fail validation here.
  emoji_name = "fts_#{slug}"
  if Emoji.exists?(emoji_name)
    category.update!(style_type: "emoji", emoji: emoji_name, uploaded_logo_id: nil)
  else
    # Children keep the plain swatch, so the tint does the work and two
    # sibling categories are not competing for the eye with artwork.
    category.update!(style_type: "square", emoji: nil, icon: nil)
  end

  category
end

PRODUCTS.each do |product|
  parent =
    upsert(
      name: product[:name],
      slug: product[:slug],
      color: product[:color],
      description: product[:description],
      admin: admin,
    )

  kids =
    CHILDREN.map do |child|
      target, amount = child[:tint]
      c =
        upsert(
          name: child[:name],
          slug: "#{product[:slug]}-#{child[:suffix]}",
          color: mix(product[:color], target, amount),
          description: child[:description].call(product),
          parent: parent,
          admin: admin,
        )
      "#{c.slug}=##{c.color}"
    end

  log("#{parent.name} ##{parent.color} style=#{parent.style_type}/#{parent.emoji.inspect} -> #{kids.join(" ")}")
end

# Subcategories are only visible on the categories page if the parent is
# allowed to show them.
SiteSetting.max_category_nesting = 3 if SiteSetting.max_category_nesting < 3
SiteSetting.desktop_category_page_style = "categories_with_featured_topics"

Emoji.clear_cache
log("custom emoji=#{CustomEmoji.pluck(:name).join(",")}")
log("total categories=#{Category.count}")
log("DONE")
