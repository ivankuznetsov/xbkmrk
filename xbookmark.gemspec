require_relative "lib/xbookmark/version"

Gem::Specification.new do |spec|
  spec.name = "xbookmark"
  spec.version = Xbookmark::VERSION
  spec.authors = ["Ivan Kuznetsov"]
  spec.email = ["josh@rabata.io"]

  spec.summary = "Sync X (Twitter) bookmarks into a local Obsidian-ready bookmark wiki."
  spec.description = "Ruby CLI that ingests X bookmarks into a transactional, LLM-enriched markdown bookmark wiki."
  spec.homepage = "https://github.com/ivankuznetsov/xbookmark"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "bin/*", "README.md", "LICENSE", ".env.example"]
  spec.bindir = "bin"
  spec.executables = ["xbookmark"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "dotenv", "~> 3.1"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "faraday", "~> 2.10"
  spec.add_dependency "faraday-retry", "~> 2.2"
  spec.add_dependency "oauth2", "~> 2.0"
  spec.add_dependency "nokogiri", "~> 1.16"
  spec.add_dependency "down", "~> 5.4"
  spec.add_dependency "json-schema", "~> 5.0"
  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "ostruct", "~> 0.6"
  spec.add_dependency "webrick", "~> 1.8"
  spec.add_dependency "tomlrb", "~> 2.0"
end
