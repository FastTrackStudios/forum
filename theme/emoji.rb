# Registers the four shipped product icons as custom emoji.
#
#   kubectl -n forum exec -i deploy/forum -- \
#     env TMPDIR=/tmp/discourse bundle exec rails runner - < theme/emoji.rb
#
# MUST run as its own process, BEFORE theme/categories.rb. Category#emoji
# is validated by `Emoji.exists?`, which reads a registry memoized per
# process — so a custom emoji created and assigned in the same run fails
# with "Validation failed: Emoji is invalid" for an emoji that demonstrably
# exists a line earlier. Creating them in a separate process is the whole
# reason this file is not part of categories.rb.
# Baked into the image; see nix/image.nix. The old hand-staged
# /tmp/fts-theme is still honoured so the scripts can be run
# against a pod by hand while iterating.
ASSETS = ENV.fetch("FORUM_THEME_DIR", "/tmp/fts-theme")
admin = User.find_by(admin: true) || Discourse.system_user

%w[signal session ignition keyflow].each do |slug|
  name = "fts_#{slug}"
  path = File.join(ASSETS, "cat-#{slug}.png")
  next STDOUT.puts("RESULT #{name} SKIP (no #{path})") unless File.exist?(path)
  next STDOUT.puts("RESULT #{name} exists") if CustomEmoji.exists?(name: name)

  upload = File.open(path) { |f| UploadCreator.new(f, "#{name}.png", type: "custom_emoji").create_for(admin.id) }
  CustomEmoji.create!(name: name, upload: upload)
  STDOUT.puts("RESULT #{name} created")
end

Emoji.clear_cache
STDOUT.puts("RESULT custom=#{CustomEmoji.pluck(:name).join(",")}")
STDOUT.puts("RESULT DONE")
