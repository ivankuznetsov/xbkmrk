# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "xbookmark/keystore/one_password"

describe Xbookmark::Keystore::OnePassword do
  let(:backend) { described_class.new }

  # Fake `Open3.popen3`'s return shape ([stdin, stdout, stderr, wait_thr]).
  # `wait_thr.join` returns a non-nil thread so the read is treated as having
  # completed before the timeout; `value` carries the exit status.
  def stub_op_popen3(out: "", err: "", success: true)
    status = process_status(success: success)
    wait_thr = mock("wait_thr")
    wait_thr.stubs(:join).returns(wait_thr)
    wait_thr.stubs(:value).returns(status)
    Open3.stubs(:popen3).returns([StringIO.new, StringIO.new(out), StringIO.new(err), wait_thr])
    wait_thr
  end

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
    wait_thr = mock("wait_thr")
    wait_thr.stubs(:join).returns(wait_thr)
    wait_thr.stubs(:value).returns(status)
    Open3.expects(:popen3).with(
      "op", "read", "--no-newline", "op://Personal/X/cred"
    ).returns([StringIO.new, StringIO.new("sk-abc"), StringIO.new, wait_thr])

    assert_equal "sk-abc", backend.read("op://Personal/X/cred")
  end

  it "passes DEFAULT_TIMEOUT to the wait join when no timeout is given" do
    assert_equal 10, described_class::DEFAULT_TIMEOUT
    status = process_status(success: true)
    wait_thr = mock("wait_thr")
    wait_thr.expects(:join).with(described_class::DEFAULT_TIMEOUT).returns(wait_thr)
    wait_thr.stubs(:value).returns(status)
    Open3.stubs(:popen3).returns([StringIO.new, StringIO.new("sk-abc"), StringIO.new, wait_thr])

    assert_equal "sk-abc", backend.read("op://Personal/X/cred")
  end

  it "rejects blank output even when op exits successfully" do
    stub_op_popen3(out: "   \n", success: true)

    error = assert_raises(Xbookmark::Error) { backend.read("op://Personal/Empty/field") }
    assert_match(/empty value/, error.message)
  end

  it "raises a NotSignedInError (an Xbookmark::Error) when op is not signed in" do
    stub_op_popen3(err: "[ERROR] not signed in", success: false)

    assert_raises(Xbookmark::Keystore::OnePassword::NotSignedInError) do
      backend.read("op://Personal/X/cred")
    end
  end

  it "treats a case/wording variant of not-signed-in as NotSignedInError" do
    stub_op_popen3(err: "[ERROR] You are not currently signed-in", success: false)

    assert_raises(Xbookmark::Keystore::OnePassword::NotSignedInError) do
      backend.read("op://Personal/X/cred")
    end
  end

  it "surfaces stderr in a raised Xbookmark::Error on failure" do
    stub_op_popen3(err: "some op error", success: false)

    error = assert_raises(Xbookmark::Error) { backend.read("op://Personal/bad/ref") }
    assert_match(/some op error/, error.message)
  end

  it "TERMs and reaps the op child and raises TimeoutError on timeout" do
    wait_thr = mock("wait_thr")
    wait_thr.stubs(:join).with(1).returns(nil)                              # read timed out
    wait_thr.stubs(:join).with(described_class::TERM_GRACE).returns(wait_thr) # exits on TERM
    wait_thr.stubs(:pid).returns(4242)
    Open3.stubs(:popen3).returns([StringIO.new, StringIO.new, StringIO.new, wait_thr])
    Process.expects(:kill).with("TERM", 4242)

    error = assert_raises(Xbookmark::Keystore::OnePassword::TimeoutError) do
      backend.read("op://Personal/Slow/cred", timeout: 1)
    end
    assert_match(/timed out after 1s/, error.message)
    assert_match(/op signin/i, error.message)
  end

  it "escalates to KILL and reaps when the op child ignores TERM" do
    wait_thr = mock("wait_thr")
    wait_thr.stubs(:join).with(1).returns(nil)                          # read timed out
    wait_thr.stubs(:join).with(described_class::TERM_GRACE).returns(nil) # ignores TERM
    wait_thr.stubs(:join).with.returns(wait_thr)                        # reaped after KILL
    wait_thr.stubs(:pid).returns(4242)
    Open3.stubs(:popen3).returns([StringIO.new, StringIO.new, StringIO.new, wait_thr])
    kill_seq = sequence("kill_seq")
    Process.expects(:kill).with("TERM", 4242).in_sequence(kill_seq)
    Process.expects(:kill).with("KILL", 4242).in_sequence(kill_seq)

    assert_raises(Xbookmark::Keystore::OnePassword::TimeoutError) do
      backend.read("op://Personal/Slow/cred", timeout: 1)
    end
  end

  it "TimeoutError is an Xbookmark::Error so callers can rescue uniformly" do
    assert_operator Xbookmark::Keystore::OnePassword::TimeoutError, :<, Xbookmark::Error
  end

  it "lets a missing op CLI (Errno::ENOENT) propagate uncaught out of read" do
    Open3.stubs(:popen3).raises(Errno::ENOENT, "op")

    assert_raises(Errno::ENOENT) { backend.read("op://Personal/X/cred") }
  end

  it "maps 'not signed in' stderr to a friendly hint" do
    stub_op_popen3(err: "[ERROR] not signed in", success: false)

    error = assert_raises(Xbookmark::Error) { backend.read("op://Personal/X/cred") }
    assert_match(/op signin/i, error.message)
    assert_match(/OP_SERVICE_ACCOUNT_TOKEN/, error.message)
  end
end
