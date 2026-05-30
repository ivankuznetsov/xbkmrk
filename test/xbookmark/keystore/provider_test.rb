# frozen_string_literal: true

require "test_helper"
require "xbookmark/keystore/provider"

describe Xbookmark::Keystore::Provider do
  it "round-trips a name into env_key and account" do
    p = described_class.parse("openrouter")
    assert_equal "openrouter", p.account
    assert_equal "XBOOKMARK_OPENROUTER_KEY", p.env_key
    assert_equal "XBOOKMARK_OPENROUTER_API_KEY", p.legacy_env_key
  end

  it "lowercases uppercase input" do
    p = described_class.parse("X")
    assert_equal "x", p.name
    assert_equal "XBOOKMARK_X_KEY", p.env_key
  end

  it "accepts digits, hyphens, and underscores" do
    p = described_class.parse("anthropic-2024_v1")
    assert_equal "anthropic-2024_v1", p.name
  end

  it "translates hyphens to underscores in env_key so shells can set the var" do
    p = described_class.parse("foo-bar")
    assert_equal "XBOOKMARK_FOO_BAR_KEY", p.env_key
    assert_equal "XBOOKMARK_FOO_BAR_API_KEY", p.legacy_env_key
  end

  it "rejects path traversal characters" do
    assert_raises(Xbookmark::Error) { described_class.parse("../foo") }
    assert_raises(Xbookmark::Error) { described_class.parse("a/b") }
    assert_raises(Xbookmark::Error) { described_class.parse("a b") }
    assert_raises(Xbookmark::Error) { described_class.parse("a.b") }
  end

  it "rejects empty input" do
    assert_raises(Xbookmark::Error) { described_class.parse("") }
    assert_raises(Xbookmark::Error) { described_class.parse("   ") }
  end
end
