# frozen_string_literal: true

require "test_helper"
require "xbookmark/keystore/one_password"

describe Xbookmark::Keystore::OnePassword do
  let(:backend) { described_class.new }

  it "reports its backend name" do
    assert_equal "1password", backend.name
  end

  it "detects op on PATH via available?" do
    Dir.mktmpdir do |dir|
      tool = File.join(dir, "op")
      File.write(tool, "#!/bin/sh\n")
      File.chmod(0o755, tool)
      with_env(ENV.to_h.merge("PATH" => dir)) do
        assert described_class.available?
      end
    end
  end

  it "available? is false when op is not on PATH" do
    with_env(ENV.to_h.merge("PATH" => "/nonexistent-path-#{SecureRandom.hex(4)}")) do
      refute described_class.available?
    end
  end

  it "returns stdout from op read on success" do
    status = process_status(success: true)
    Open3.expects(:capture3).with(
      "op", "read", "--no-newline", "op://Personal/X/cred"
    ).returns(["sk-abc", "", status])

    assert_equal "sk-abc", backend.read("op://Personal/X/cred")
  end

  it "surfaces stderr in a raised Xbookmark::Error on failure" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "some op error", status])

    error = assert_raises(Xbookmark::Error) { backend.read("op://Personal/bad/ref") }
    assert_match(/some op error/, error.message)
  end

  it "maps 'not signed in' stderr to a friendly hint" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "[ERROR] not signed in", status])

    error = assert_raises(Xbookmark::Error) { backend.read("op://Personal/X/cred") }
    assert_match(/op signin/i, error.message)
    assert_match(/OP_SERVICE_ACCOUNT_TOKEN/, error.message)
  end
end

require "securerandom"
