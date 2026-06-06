# frozen_string_literal: true

require "test_helper"

require "xbookmark/keystore"
require "xbookmark/keystore/importer"

describe Xbookmark::Keystore do
  let(:memory) { Xbookmark::Keystore::Memory.new }

  describe "facade" do
    it "round-trips set/get/delete via the memory backend" do
      ks = described_class.new(backend: memory)
      assert_nil ks.get("X_CLIENT_ID")
      ks.set("X_CLIENT_ID", "abc")
      assert_equal "abc", ks.get("X_CLIENT_ID")
      ks.delete("X_CLIENT_ID")
      assert_nil ks.get("X_CLIENT_ID")
    end

    it "normalises env-style keys to lowercase account names" do
      ks = described_class.new(backend: memory)
      ks.set("X_USER_ID", "42")
      assert_equal "42", memory.get("x_user_id")
    end

    it "delete_all removes only known keys that exist" do
      ks = described_class.new(backend: memory)
      ks.set("X_CLIENT_ID", "abc")
      ks.set("X_USER_ID", "42")
      ks.set("X_UNKNOWN", "nope") # not in KNOWN_KEYS, ignored
      removed = ks.delete_all
      assert_contains_exactly ["x_client_id", "x_user_id"], removed
      assert_nil ks.get("X_CLIENT_ID")
      assert_nil ks.get("X_USER_ID")
    end

    it "hydrate fills missing env keys without clobbering present ones" do
      ks = described_class.new(backend: memory)
      ks.set("X_CLIENT_ID", "from-keystore")
      env = { "X_USER_ID" => "from-env" }
      ks.hydrate(env)
      assert_equal "from-keystore", env["X_CLIENT_ID"]
      assert_equal "from-env", env["X_USER_ID"]
    end

    it "returns a copy of memory backend values" do
      memory.set("x_client_id", "abc")
      copy = memory.to_h
      copy["x_client_id"] = "changed"

      assert_equal "abc", memory.get("x_client_id")
    end
  end

  describe "backend selection" do
    it "picks Keychain on macOS" do
      stub_platform_macos
      ks = described_class.new
      assert_kind_of Xbookmark::Keystore::Keychain, ks.backend
    end

    it "falls back to EnvFile on Linux when secret-tool / DBUS unavailable" do
      stub_platform_linux
      ENV.delete("DBUS_SESSION_BUS_ADDRESS")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(false)
      ks = described_class.new
      assert_kind_of Xbookmark::Keystore::EnvFile, ks.backend
    end

    it "picks Libsecret on Linux when secret-tool + DBUS are present" do
      stub_platform_linux
      ENV["DBUS_SESSION_BUS_ADDRESS"] = "/run/user/1000/bus"
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      ks = described_class.new
      assert_kind_of Xbookmark::Keystore::Libsecret, ks.backend
    ensure
      ENV.delete("DBUS_SESSION_BUS_ADDRESS")
    end
  end
end

describe Xbookmark::Keystore::Libsecret do
  let(:backend) { described_class.new }

  it "reports its backend name" do
    assert_equal "libsecret", backend.name
  end

  it "detects secret-tool on PATH" do
    Dir.mktmpdir do |dir|
      tool = File.join(dir, "secret-tool")
      File.write(tool, "#!/bin/sh\n")
      File.chmod(0o755, tool)

      with_env(ENV.to_h.merge("PATH" => dir)) do
        assert described_class.available?
        assert_nil described_class.which("missing")
      end
    end
  end

  it "shells out to `secret-tool lookup` for get" do
    status = process_status(success: true)
    Open3.expects(:capture3).with(
      "secret-tool", "lookup",
      "service", "xbookmark",
      "account", "x_client_id"
    ).returns(["abc\n", "", status])

    assert_equal "abc\n", backend.get("x_client_id")
  end

  it "returns nil when secret-tool lookup succeeds with an empty value" do
    status = process_status(success: true)
    Open3.stubs(:capture3).returns(["", "", status])

    assert_nil backend.get("empty")
  end

  it "returns nil when secret-tool exits non-zero with no stderr (item absent)" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "", status])
    assert_nil backend.get("missing")
  end

  it "raises on a transient lookup failure that reports an error on stderr" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "Cannot autolaunch D-Bus", status])

    error = assert_raises(Xbookmark::Error) { backend.get("openrouter") }
    assert_match(/D-Bus/, error.message)
  end

  it "passes value via stdin to secret-tool store" do
    status = process_status(success: true)
    Open3.expects(:capture3).with(
      "secret-tool", "store",
      "--label=xbookmark",
      "service", "xbookmark",
      "account", "x_client_id",
      stdin_data: "secret"
    ).returns(["", "", status])

    backend.set("x_client_id", "secret")
  end

  it "raises when secret-tool store fails" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "denied", status])

    error = assert_raises(Xbookmark::Error) { backend.set("x_client_id", "secret") }
    assert_match(/denied/, error.message)
  end

  it "deletes and lists accounts through secret-tool" do
    delete_status = process_status(success: true)
    list_status = process_status(success: true)
    Open3.expects(:capture3).with(
      "secret-tool", "clear",
      "service", "xbookmark",
      "account", "x_client_id"
    ).returns(["", "", delete_status])
    Open3.expects(:capture3).with(
      "secret-tool", "search", "--all",
      "service", "xbookmark"
    ).returns(["attribute.account = x_client_id\nattribute.account = x_user_id\n", "", list_status])

    assert_equal true, backend.delete("x_client_id")
    assert_contains_exactly ["x_client_id", "x_user_id"], backend.list_accounts
  end

  it "returns an empty account list when secret-tool search fails" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "", status])

    assert_equal [], backend.list_accounts
  end
end

describe Xbookmark::Keystore::Keychain do
  let(:backend) { described_class.new }

  it "reports its backend name" do
    assert_equal "keychain", backend.name
  end

  it "shells out to `security find-generic-password` for get" do
    status = process_status(success: true)
    Open3.expects(:capture3).with(
      "security", "find-generic-password",
      "-s", "xbookmark", "-a", "x_client_id", "-w"
    ).returns(["abc\n", "", status])

    assert_equal "abc", backend.get("x_client_id")
  end

  it "returns nil for missing or empty keychain entries" do
    missing = process_status(success: false)
    empty = process_status(success: true)
    Open3.stubs(:capture3).returns(["", "", missing]).then.returns(["\n", "", empty])

    assert_nil backend.get("missing")
    assert_nil backend.get("empty")
  end

  it "raises on a transient find failure that reports an error on stderr" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "User interaction is not allowed.", status])

    error = assert_raises(Xbookmark::Error) { backend.get("openrouter") }
    assert_match(/User interaction is not allowed/, error.message)
  end

  it "treats errSecItemNotFound (exit 44) as a successful delete" do
    status = process_status(success: false, exitstatus: 44)
    Open3.expects(:capture3).with(
      "security", "delete-generic-password",
      "-s", "xbookmark", "-a", "openrouter"
    ).returns(["", "could not be found", status])

    assert_equal true, backend.delete("openrouter")
  end

  it "adds, deletes, and lists keychain entries" do
    status = process_status(success: true)
    Open3.expects(:capture3).with(
      "security", "add-generic-password",
      "-s", "xbookmark",
      "-a", "x_client_id",
      "-w", "secret",
      "-U"
    ).returns(["", "", status])
    Open3.expects(:capture3).with(
      "security", "delete-generic-password",
      "-s", "xbookmark", "-a", "x_client_id"
    ).returns(["", "", status])

    assert_equal true, backend.set("x_client_id", "secret")
    assert_equal true, backend.delete("x_client_id")

    backend.stubs(:get).returns(nil)
    backend.stubs(:get).with("x_client_id").returns("secret")
    assert_equal ["x_client_id"], backend.list_accounts
  end

  it "raises when adding a keychain entry fails" do
    status = process_status(success: false)
    Open3.stubs(:capture3).returns(["", "denied", status])

    error = assert_raises(Xbookmark::Error) { backend.set("x_client_id", "secret") }
    assert_match(/denied/, error.message)
  end
end

describe Xbookmark::Keystore::EnvFile do
  it "reports its backend name with the env file path" do
    backend = described_class.new(path: "/tmp/xbookmark.env")

    assert_equal "env_file (/tmp/xbookmark.env)", backend.name
  end

  it "returns nil and no accounts when the file is absent" do
    Dir.mktmpdir do |dir|
      backend = described_class.new(path: File.join(dir, ".env"))

      assert_nil backend.get("x_client_id")
      assert_equal [], backend.list_accounts
    end
  end

  it "round-trips set/get/delete and writes with mode 0600" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      backend = described_class.new(path: path)
      backend.set("x_client_id", "abc")
      assert_equal "abc", backend.get("x_client_id")
      assert_includes File.read(path), "X_CLIENT_ID=abc"
      assert_equal 0o600, File.stat(path).mode & 0o777
      backend.delete("x_client_id")
      assert_nil backend.get("x_client_id")
    end
  end

  it "lists accounts present in the file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "X_CLIENT_ID=abc\nX_USER_ID=42\n")
      backend = described_class.new(path: path)
      assert_contains_exactly ["x_client_id", "x_user_id"], backend.list_accounts
    end
  end

  it "round-trips values containing inner double quotes without backslash accumulation" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      backend = described_class.new(path: path)
      secret = %q(s"e"cret)

      backend.set(:x_client_secret, secret)
      assert_equal secret, backend.get(:x_client_secret)

      # Re-write the same value and confirm it still reads back identical —
      # this catches a writer that escapes on every set but a reader that
      # never unescapes (each round adds one backslash).
      backend.set(:x_client_secret, backend.get(:x_client_secret))
      assert_equal secret, backend.get(:x_client_secret)
    end
  end
end

describe Xbookmark::Keystore::Importer do
  it "writes every known key from a fixture .env into the keystore" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=abc\nX_USER_ID=42\nUNUSED=bar\n")
      ks = Xbookmark::Keystore.new(backend: Xbookmark::Keystore::Memory.new)
      migrated = described_class.new(keystore: ks).import(env_path)
      assert_contains_exactly ["X_CLIENT_ID", "X_USER_ID"], migrated
      assert_equal "abc", ks.get("X_CLIENT_ID")
      assert_equal "42", ks.get("X_USER_ID")
      assert File.file?(env_path) # never deletes the source
    end
  end
end
