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
  # Order is presentation order everywhere: the categories page, the
  # positions written below, and the sidebar. Session leads.
  {
    slug: "session",
    name: "Session",
    color: "2e9bff",
    description: "Setlists, songs, notation, the guide, and the Session app that runs the show.",
  },
  {
    slug: "signal",
    name: "Signal",
    color: "2fd673",
    description: "The Signal Suite — the audio engine, instrument rigs, sampler, and the CLAP/VST3 plugin set.",
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
    suffix: "discussions",
    name: "Discussions",
    # The middle level: neither asking for something nor reporting a
    # fault, so it sits between the two tints rather than at either end.
    tint: ["ededf1", 0.12],
    type: nil,
    description: ->(p) { "Everything else about #{p[:name]} — how people are using it, what they are building, and what it should become." },
  },
  {
    suffix: "feature-requests",
    name: "Feature Requests",
    # Discourse category TYPE, from discourse-topic-voting: turns the
    # category into an idea board where topics are voted on.
    type: :ideas,
    # Lifted toward the house white: asking for something is the forward,
    # brighter half of the conversation.
    tint: ["ededf1", 0.34],
    description: ->(p) { "Ideas and requests for #{p[:name]}. Say what you are trying to do, not only what you want added." },
  },
  {
    suffix: "support",
    name: "Support",
    # From discourse-solved: a reply can be marked as the answer, and the
    # topic reads as solved or unsolved.
    type: :support,
    # Settled back toward the deck. Still legible on the dark ground, but
    # it does not compete with the request category next to it.
    tint: ["131318", 0.30],
    description: ->(p) { "Help with #{p[:name]} — something broken, confusing, or not behaving the way you expected." },
  },
].freeze

admin = User.find_by(admin: true) || Discourse.system_user

# ── Category types ───────────────────────────────────────────────────────
# Discourse has a real notion of a category TYPE, contributed by plugins
# and held in Categories::TypeRegistry. Both of the ones used here ship in
# Discourse core but are OFF by default, and a type cannot be applied while
# its plugin is disabled — `configure_category` would write a setting row
# that nothing reads.
#
#   :ideas   -> discourse-topic-voting. Topics get votes, so the loudest
#               request is visible rather than merely the most recent.
#   :support -> discourse-solved. A reply can be marked as the answer and
#               the topic reads solved / unsolved.
#
# enable_ideas_category_type_setup is what makes :ideas visible as a type
# at all — without it the registry hides it and the admin UI never offers
# it either.
SiteSetting.topic_voting_enabled = true
SiteSetting.solved_enabled = true
SiteSetting.enable_ideas_category_type_setup = true

def apply_type(category, type_id, admin)
  return "plain" if type_id.nil?

  klass = ::Categories::TypeRegistry.get(type_id)
  return "MISSING(#{type_id})" if klass.nil?

  klass.enable_plugin unless klass.plugin_enabled?
  return "already:#{type_id}" if klass.category_matches?(category)

  klass.configure_category(category, guardian: Guardian.new(admin))
  type_id.to_s
rescue => e
  "FAILED(#{type_id}: #{e.class})"
end

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

# ── Form templates ───────────────────────────────────────────────────────
# A bug report that arrives without a version, a platform or steps costs a
# round trip before anyone can even start. These make the composer ask, so
# the first post already contains what a maintainer needs.
#
# Only the two typed categories get one. Discussions deliberately has none:
# a template on open conversation is a barrier, not a help.
#
# Field rules, from FormTemplateYamlValidator: every field needs a `type`
# (checkbox, dropdown, input, multi-select, textarea, upload, tag-chooser,
# composer) and a unique `id`.
TEMPLATES = {
  "FTS Support" => [
    { "type" => "dropdown", "id" => "platform", "choices" => ["macOS", "Windows", "Linux"],
      "attributes" => { "label" => "Platform", "required" => true } },
    { "type" => "input", "id" => "version",
      "attributes" => { "label" => "Version", "required" => true,
                        "placeholder" => "e.g. 0.4.2, or a build date" } },
    { "type" => "textarea", "id" => "what-happened",
      "attributes" => { "label" => "What happened?", "required" => true,
                        "description" => "What you saw, and what you expected instead." } },
    { "type" => "textarea", "id" => "steps",
      "attributes" => { "label" => "Steps to reproduce",
                        "description" => "The shortest sequence that shows the problem. If it is intermittent, say so." } },
    { "type" => "upload", "id" => "attachments", "attributes" => { "label" => "Screenshots or logs" } },
  ],
  "FTS Feature Request" => [
    { "type" => "textarea", "id" => "goal",
      "attributes" => { "label" => "What are you trying to do?", "required" => true,
                        "description" => "The problem, not the solution. This is the part that decides whether an idea gets built." } },
    { "type" => "textarea", "id" => "proposal",
      "attributes" => { "label" => "What would you like to see?" } },
    { "type" => "textarea", "id" => "workaround",
      "attributes" => { "label" => "How do you handle it today?",
                        "description" => "Existing workarounds tell us how much this hurts." } },
  ],
}.freeze

template_ids = {}
TEMPLATES.each do |name, fields|
  ft = FormTemplate.find_by(name: name) || FormTemplate.new(name: name)
  ft.template = fields.to_yaml
  ft.save!
  template_ids[name] = ft.id
end
log("form templates=#{template_ids.inspect}")

# ── Tags ─────────────────────────────────────────────────────────────────
# Categories are per-PRODUCT; tags are per-CONCERN. Without them there is
# no way to ask "every audio crash on Windows" across Signal and Session,
# because the two live in different category trees.
#
# Deliberately few and closed. An open tag field on a public forum becomes
# a thousand one-use tags within a month, and then means nothing.
TAG_GROUPS = {
  "Platform" => %w[macos windows linux],
  "Release" => %w[stable beta nightly],
}.freeze

TAG_GROUPS.each do |group_name, tag_names|
  tags = tag_names.map { |t| Tag.find_by_name(t) || Tag.create!(name: t) }
  group = TagGroup.find_by(name: group_name) || TagGroup.create!(name: group_name)
  group.tags = tags
  group.save!
end
log("tag groups=#{TagGroup.pluck(:name).inspect}")

# Which template each category TYPE gets. Discussions (nil) gets none.
TEMPLATE_FOR = {
  support: template_ids["FTS Support"],
  ideas: template_ids["FTS Feature Request"],
}.freeze

# Discourse only honours `position` when told to; left alone it orders
# categories by activity, which would shuffle these three around as people
# post. The order here is the shape of the conversation — talk about it,
# ask for something, report a fault — and it should not move.
SiteSetting.fixed_category_positions = true
position = 0

PRODUCTS.each do |product|
  parent =
    upsert(
      name: product[:name],
      slug: product[:slug],
      color: product[:color],
      description: product[:description],
      admin: admin,
    )
  parent.update_column(:position, position += 1)

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
      c.update_column(:position, position += 1)
      if (tid = TEMPLATE_FOR[child[:type]])
        c.update!(form_template_ids: [tid])
      end
      "#{c.slug}=##{c.color}/#{apply_type(c, child[:type], admin)}"
    end

  log("#{parent.name} ##{parent.color} style=#{parent.style_type}/#{parent.emoji.inspect} -> #{kids.join(" ")}")
end

# ── Everything that is not a product ─────────────────────────────────────
# The stock categories sort BELOW the four products, in this order. They
# are housekeeping: someone arriving at a product forum is here about a
# product, and General/Site Feedback/Staff are where the leftovers go.
# Listed by slug and positioned only if present, so a Discourse that seeds
# a different set does not break this.
%w[general site-feedback staff].each do |slug|
  c = Category.find_by(slug: slug, parent_category_id: nil)
  next unless c
  c.update_column(:position, position += 1)
  log("trailing #{slug} position=#{c.position}")
end

# ── The landing page ─────────────────────────────────────────────────────
# The front page IS the product list. Someone arriving here is almost
# always here about one app — a bug in Ignition, a request for Signal — so
# the first screen should be "which product", not a firehose of every
# recent post across all of them.
#
# `subcategories_with_featured_topics` renders each parent WITH its
# children and their recent topics, so Signal → Feature Requests / Support
# and what is live in each is visible without a click. The alternatives
# either hide the children (categories_only, categories_with_featured_topics)
# or bury them under a global latest list (categories_and_latest_topics,
# the Discourse default).
SiteSetting.max_category_nesting = 3 if SiteSetting.max_category_nesting < 3
SiteSetting.desktop_category_page_style = "subcategories_with_featured_topics"
SiteSetting.mobile_category_page_style = "subcategories_with_featured_topics"

# top_menu's FIRST entry is the homepage. Categories leads; latest and the
# rest stay reachable as tabs. "unread" is deliberately absent — it is
# meaningless to a logged-out visitor, which is most of a public forum.
SiteSetting.top_menu = "categories|latest|new|hot"

# How many topics appear under each subcategory. FIVE is the floor —
# Discourse validates this and raises Discourse::InvalidParameters
# ("Value must be 5 or greater") for anything lower, which killed this
# script partway through twice: once on 3 here, and once on
# `category_featured_topics`, which no longer exists at all. Both left the
# categories built and every setting below them untouched.
SiteSetting.categories_topics = 5

# ── The sidebar ──────────────────────────────────────────────────────────
# The four products are pinned into every visitor's navigation menu, so
# "which app am I here about" is answerable from anywhere without going
# back to the front page. This is the DEFAULT for new and anonymous users;
# anyone signed in can still edit their own.
product_ids = PRODUCTS.map { |p| Category.find_by(slug: p[:slug], parent_category_id: nil)&.id }.compact
SiteSetting.default_navigation_menu_categories = product_ids.join("|")
log("sidebar categories=#{product_ids.inspect}")

Emoji.clear_cache
log("custom emoji=#{CustomEmoji.pluck(:name).join(",")}")
log("total categories=#{Category.count}")
log("DONE")
