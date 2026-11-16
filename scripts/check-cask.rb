# frozen_string_literal: true

# Loads a rendered Homebrew cask without Homebrew and checks what it declares.
#   ruby scripts/check-cask.rb <cask file> key=value...
#
# Keys: token, version, sha256, url, name, app, quit, macos, arch and zap. An empty arch means none.
# zap lists paths joined by "|". scripts/check-release.sh passes them.
#
# The cask runs against a small stand-in for Homebrew's DSL that records each stanza. A stanza this
# file does not know fails the check, so a new stanza needs a line here too. The livecheck block
# runs against made-up release data. The checks follow Homebrew's own rules for the order of
# stanzas, the description and the homepage, as found in Homebrew's rubocops. On a Mac with
# Homebrew, brew style on a copy of the cask under a Casks folder runs the real rules.

PROBLEMS = []

def problem(message)
  PROBLEMS << message
end

# The livecheck block's stanzas.
class LivecheckStub
  attr_reader :url_value, :regex_value, :strategy_name, :strategy_block

  def url(value)
    @url_value = value
  end

  def regex(value)
    @regex_value = value
  end

  def strategy(name, &block)
    @strategy_name = name
    @strategy_block = block
  end

  def method_missing(name, *_args)
    problem("livecheck uses #{name}, which this check does not know")
  end

  def respond_to_missing?(_name, _include_private = false)
    false
  end
end

# The cask's stanzas, in the order they appear.
class CaskStub
  attr_reader :order, :values

  def initialize
    @order = []
    @values = Hash.new { |hash, key| hash[key] = [] }
  end

  def record(name, value)
    @order << name
    @values[name] << value
  end

  # Without an argument, version returns the value, as in "#{version}" inside the url.
  def version(value = nil)
    return @values[:version].first if value.nil?

    record(:version, value)
  end

  def sha256(value)
    record(:sha256, value)
  end

  def url(value, **options)
    record(:url, [value, options])
  end

  def name(value)
    record(:name, value)
  end

  def desc(value)
    record(:desc, value)
  end

  def homepage(value)
    record(:homepage, value)
  end

  def livecheck(&block)
    stub = LivecheckStub.new
    stub.instance_eval(&block)
    record(:livecheck, stub)
  end

  def auto_updates(value)
    record(:auto_updates, value)
  end

  def depends_on(**options)
    record(:depends_on, options)
  end

  def app(value)
    record(:app, value)
  end

  def uninstall(**options)
    record(:uninstall, options)
  end

  def zap(**options)
    record(:zap, options)
  end

  def method_missing(name, *_args)
    problem("the cask uses #{name}, which this check does not know")
  end

  def respond_to_missing?(_name, _include_private = false)
    false
  end
end

def cask(token, &block)
  stub = CaskStub.new
  stub.instance_eval(&block)
  $loaded = [token, stub] # rubocop:disable Style/GlobalVars
end

path = ARGV.fetch(0) { abort "usage: ruby check-cask.rb <cask file> key=value..." }
expect = {}
ARGV.drop(1).each do |pair|
  key, value = pair.split("=", 2)
  abort "check-cask: expected key=value, got #{pair}" if value.nil?
  expect[key] = value
end

begin
  load File.expand_path(path)
rescue ScriptError, StandardError => e
  abort "check-cask: #{path} does not load: #{e.class}: #{e.message}"
end
token, stub = $loaded # rubocop:disable Style/GlobalVars
abort "check-cask: #{path} declares no cask" if stub.nil?

def one(stub, name)
  values = stub.values[name]
  problem("expected one #{name} stanza, found #{values.size}") unless values.size == 1
  values.first
end

def same(what, actual, wanted)
  problem("#{what} is #{actual.inspect}, expected #{wanted.inspect}") unless actual == wanted
end

same("the token", token, expect.fetch("token"))
same("the version", one(stub, :version), expect.fetch("version"))
sha = one(stub, :sha256)
problem("sha256 is not 64 lowercase hex digits") unless sha.to_s.match?(/\A[0-9a-f]{64}\z/)
same("sha256", sha, expect.fetch("sha256"))

url, url_options = one(stub, :url)
same("the url", url, expect.fetch("url"))
problem("the url does not use https") unless url.to_s.start_with?("https://")
# Homebrew deprecates the url's verified parameter and warns when a cask passes it.
same("the url's parameters", url_options, {})
same("the name", one(stub, :name), expect.fetch("name"))

# Homebrew's description rules.
desc = one(stub, :desc).to_s
problem("desc is longer than 80 characters") if desc.length > 80
problem("desc starts with an article") if desc.match?(/\A(?:the|an?)\s/i)
problem("desc does not start with a capital letter") unless desc.match?(/\A[A-Z]/)
problem("desc starts with the app's name") if desc.downcase.start_with?(expect.fetch("name").downcase)
problem("desc names the platform") if desc.match?(/\b(macOS|Mac(?: ?OS(?: ?X)?)?|OS ?X)\b/i)
problem("desc ends with a full stop") if desc.end_with?(".")
problem("desc has leading or trailing spaces") if desc != desc.strip

homepage = one(stub, :homepage)
problem("the homepage does not use https") unless homepage.to_s.start_with?("https://")
problem("the homepage needs a slash after the domain") if homepage.to_s.match?(%r{\A[^:]+://[^/]+\z})

livecheck = one(stub, :livecheck)
if livecheck
  same("livecheck's url", livecheck.url_value, :url)
  same("livecheck's strategy", livecheck.strategy_name, :github_releases)
  if livecheck.strategy_block.nil? || livecheck.regex_value.nil?
    problem("livecheck needs a regex and a strategy block")
  else
    releases = [
      { "tag_name" => "v9.2.0", "draft" => true, "prerelease" => false },
      { "tag_name" => "v9.1.0", "draft" => false, "prerelease" => true },
      { "tag_name" => "v9.0.0", "draft" => false, "prerelease" => false },
      { "tag_name" => "nightly", "draft" => false, "prerelease" => true },
    ]
    found = Array(livecheck.strategy_block.call(releases, livecheck.regex_value)).compact.map(&:to_s).uniq
    same("livecheck's versions from sample releases", found, ["9.1.0", "9.0.0"])
  end
end

problem("the cask must not claim auto_updates: the app has no updater") unless stub.values[:auto_updates].empty?

depends = stub.values[:depends_on].reduce({}) { |all, options| all.merge(options) }
same("depends_on macos", depends[:macos], expect.fetch("macos").to_sym)
wanted_arch = expect.fetch("arch").empty? ? nil : expect.fetch("arch").to_sym
same("depends_on arch", depends[:arch], wanted_arch)
problem("depends_on names something else: #{depends.keys - %i[macos arch]}") unless (depends.keys - %i[macos arch]).empty?

same("the app", one(stub, :app), expect.fetch("app"))
same("uninstall", one(stub, :uninstall), { quit: expect.fetch("quit") })
zap = one(stub, :zap) || {}
same("zap trash", zap[:trash], expect.fetch("zap").split("|"))
same("zap's keys", zap.keys, [:trash])

# Homebrew's stanza order, from rubocops/cask/constants/stanza.rb, for the stanzas a cask here uses.
ORDER = %i[version sha256 url name desc homepage livecheck auto_updates depends_on app uninstall zap].freeze
seen = stub.order.uniq
unknown = seen - ORDER
problem("stanzas outside the known order: #{unknown}") unless unknown.empty?
same("the stanza order", seen, ORDER & seen)

if PROBLEMS.empty?
  puts "check-cask: OK (#{File.basename(path)}, #{token} #{one(stub, :version)})"
else
  PROBLEMS.each { |message| warn "check-cask: #{message}" }
  exit 1
end
