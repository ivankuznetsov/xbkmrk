# frozen_string_literal: true

require "test_helper"

require "xbookmark/x/auth"

describe Xbookmark::X::Auth do
  def fake_config(env_path:, refresh_token: nil, expires_at: nil)
    Xbookmark::Config.send(:remove_const, :ALREADY) if false # noop guard
    Struct::XbookmarkConfig.new(
      vault_path: "/tmp/v",
      state_db_path: "/tmp/v/.xbookmark/state.db",
      logs_dir: "/tmp/logs",
      scratch_dir: "/tmp/v/.xbookmark/scratch",
      x_client_id: "client123",
      x_client_secret: nil,
      x_redirect_uri: "http://127.0.0.1:7799/callback",
      x_user_id: "42",
      x_access_token: "old-access",
      x_refresh_token: refresh_token,
      x_token_expires_at: expires_at,
      codex_bin: "codex",
      whisper_bin: nil,
      whisper_model: "base.en",
      qmd_bin: "qmd",
      daily_sync_time: "06:00",
      min_run_interval_hours: 20.0,
      aux_summaries: false,
      env_file: env_path,
      verbose: false
    )
  end

  it "writes tokens to .env after a successful exchange" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123\nX_REDIRECT_URI=http://127.0.0.1:7799/callback\n")
      config = fake_config(env_path: env_path)
      auth = described_class.new(config, opener: false, env_path: env_path)
      auth.write_tokens!({
        "access_token" => "ACC", "refresh_token" => "REF", "expires_in" => 7200
      })
      contents = File.read(env_path)
      assert_includes contents, "X_ACCESS_TOKEN=ACC"
      assert_includes contents, "X_REFRESH_TOKEN=REF"
      assert_match(/X_TOKEN_EXPIRES_AT=\d+/, contents)
    end
  end

  it "appends token keys to env files that do not end with a newline and tightens permissions" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123")
      config = fake_config(env_path: env_path)
      auth = described_class.new(config, opener: false, env_path: env_path)

      auth.write_tokens!({ "access_token" => "ACC", "expires_in" => 10 })

      assert_includes File.read(env_path), "X_CLIENT_ID=client123\nX_ACCESS_TOKEN=ACC"
      assert_equal "600", format("%o", File.stat(env_path).mode & 0o777)
    end
  end

  it "preserves the refresh token when the response omits it" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "KEEP")
      auth = described_class.new(config, opener: false, env_path: env_path)
      auth.write_tokens!({ "access_token" => "ACC2", "expires_in" => 60 }, preserve_refresh: true)
      assert_includes File.read(env_path), "X_REFRESH_TOKEN=KEEP"
    end
  end

  it "writes tokens to the keystore when no env file is loaded" do
    keystore = Xbookmark::Keystore.new(backend: Xbookmark::Keystore::Memory.new)
    config = fake_config(env_path: nil)
    auth = described_class.new(config, opener: false, keystore: keystore)

    auth.write_tokens!({ "access_token" => "ACC", "refresh_token" => "REF", "expires_in" => 7200 })

    assert_equal "ACC", keystore.get("X_ACCESS_TOKEN")
    assert_equal "REF", keystore.get("X_REFRESH_TOKEN")
    assert_match(/\A\d+\z/, keystore.get("X_TOKEN_EXPIRES_AT"))
  end

  it "keeps rotating tokens out of Keychain argv by using the stable user env file" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      backend = stub(name: "keychain")
      keychain = Xbookmark::Keystore.new(backend: backend)
      Xbookmark::Paths.stubs(:user_env_path).returns(env_path)

      auth = described_class.new(fake_config(env_path: nil), opener: false, keystore: keychain)
      auth.write_tokens!({ "access_token" => "ACC", "refresh_token" => "REF", "expires_in" => 7200 })

      assert_includes File.read(env_path), "X_ACCESS_TOKEN=ACC"
    end
  end

  it "PKCE challenge is base64url(SHA256(verifier)) without padding" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    challenge = auth.pkce_challenge("a" * 64)
    assert_match(/\A[A-Za-z0-9_-]+\z/, challenge)
    refute_includes challenge, "="
  end

  it "builds the OAuth authorize URL with the configured redirect, state, challenge, and scopes" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")

    uri = URI(auth.build_authorize_url(state: "STATE", challenge: "CHALLENGE"))
    params = URI.decode_www_form(uri.query).to_h

    assert uri.to_s.start_with?("https://twitter.com/i/oauth2/authorize")
    assert_hash_includes({
      "response_type" => "code",
      "client_id" => "client123",
      "redirect_uri" => "http://127.0.0.1:7799/callback",
      "state" => "STATE",
      "code_challenge" => "CHALLENGE",
      "code_challenge_method" => "S256"
    }, params)
    assert_includes params["scope"].split, "tweet.read"
    assert_includes params["scope"].split, "users.read"
    assert_includes params["scope"].split, "bookmark.read"
    assert_includes params["scope"].split, "offline.access"
  end

  it "runs the login flow through opener, callback, exchange, persistence, and result shaping" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123\n")
      opened = nil
      config = fake_config(env_path: env_path)
      auth = described_class.new(config, opener: ->(url) { opened = url }, env_path: env_path)
      auth.stubs(:wait_for_callback).returns("CODE")
      auth.stubs(:exchange_code_for_token)
        .returns({ "access_token" => "ACC", "refresh_token" => "REF", "expires_in" => 20 })

      result = nil
      capture_stderr { result = auth.login }

      assert_includes opened, "https://twitter.com/i/oauth2/authorize"
      assert_equal env_path, result.env_file
      assert_equal "ACC", result.access_token
      assert_equal "REF", result.refresh_token
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=ACC"
    end
  end

  it "does not open a browser when opener is false and swallows opener failures" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    assert_nil auth.try_open("https://example.com")

    broken = described_class.new(fake_config(env_path: "/tmp/.env"), opener: ->(_) { raise "no gui" }, env_path: "/tmp/.env")
    broken.try_open("https://example.com")
  end

  it "uses xdg-open or open when available and falls through when no opener exists" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), env_path: "/tmp/.env")
    auth.stubs(:which).with("xdg-open").returns("/usr/bin/xdg-open")
    auth.expects(:system).with("xdg-open", "https://example.com", out: File::NULL, err: File::NULL).returns(true)
    auth.try_open("https://example.com")

    mac_auth = described_class.new(fake_config(env_path: "/tmp/.env"), env_path: "/tmp/.env")
    mac_auth.stubs(:which).with("xdg-open").returns(nil)
    mac_auth.stubs(:which).with("open").returns("/usr/bin/open")
    mac_auth.expects(:system).with("open", "https://example.com", out: File::NULL, err: File::NULL).returns(true)
    mac_auth.try_open("https://example.com")

    none = described_class.new(fake_config(env_path: "/tmp/.env"), env_path: "/tmp/.env")
    none.stubs(:which).returns(nil)
    assert_nil none.try_open("https://example.com")
  end

  it "refresh! calls token endpoint and persists rotated tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123\nX_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD", expires_at: Time.now.to_i - 100)
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "OLD"))
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "ROTATED", expires_in: 3600 }.to_json,
                   headers: { "Content-Type" => "application/json" })

      auth = described_class.new(config, opener: false, env_path: env_path)
      result = auth.refresh!
      assert_equal "NEW", result.access_token
      assert_equal "ROTATED", result.refresh_token
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=NEW"
      assert_includes File.read(env_path), "X_REFRESH_TOKEN=ROTATED"
    end
  end

  it "sends HTTP basic auth while refreshing confidential-client tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123\nX_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      config.x_client_secret = "secret"
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .with(headers: { "Authorization" => /^Basic / },
              body: hash_including("grant_type" => "refresh_token", "refresh_token" => "OLD"))
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "ROTATED", expires_in: 3600 }.to_json)

      result = described_class.new(config, opener: false, env_path: env_path).refresh!

      assert_equal "NEW", result.access_token
    end
  end

  it "uses bounded token endpoint timeouts" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env", refresh_token: "OLD"), opener: false, env_path: "/tmp/.env")
    conn = auth.send(:token_conn)

    assert_equal 5, conn.options.open_timeout
    assert_equal 30, conn.options.timeout
  end

  it "raises before refresh when no refresh token is configured" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env", refresh_token: nil), opener: false, env_path: "/tmp/.env")

    error = assert_raises(Xbookmark::AuthError) { auth.refresh! }
    assert_match(/Missing refresh token/, error.message)
  end

  it "sends HTTP basic auth for confidential-client token exchange and rejects error bodies" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=client123\n")
      config = fake_config(env_path: env_path)
      config.x_client_secret = "secret"
      auth = described_class.new(config, opener: false, env_path: env_path)

      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .with(headers: { "Authorization" => /^Basic / },
              body: hash_including("grant_type" => "authorization_code", "code" => "CODE", "code_verifier" => "VERIFIER"))
        .to_return(status: 200, body: { access_token: "ACC", expires_in: 10 }.to_json)

      assert_equal "ACC", auth.exchange_code_for_token(code: "CODE", verifier: "VERIFIER")["access_token"]

      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { error: "invalid_request", error_description: "bad code" }.to_json)

      error = assert_raises(Xbookmark::AuthError) { auth.exchange_code_for_token(code: "BAD", verifier: "VERIFIER") }
      assert_match(/Token exchange returned error: invalid_request: bad code/, error.message)

      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 400, body: "bad request")

      error = assert_raises(Xbookmark::AuthError) { auth.exchange_code_for_token(code: "DENIED", verifier: "VERIFIER") }
      assert_match(/Token exchange failed \(400\)/, error.message)
    end
  end

  it "wraps token exchange transport failures as transient auth errors" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    stub_request(:post, "https://api.twitter.com/2/oauth2/token")
      .to_raise(Faraday::TimeoutError.new("execution expired"))

    error = assert_raises(Xbookmark::TransientAuthError) { auth.exchange_code_for_token(code: "CODE", verifier: "VERIFIER") }
    assert_match(/Token exchange transport failed: execution expired/, error.message)
  end

  it "sanitizes token exchange error bodies" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    body = {
      error: "invalid_request",
      error_description: "bad access_token=ACCESSSECRET12345678901234567890"
    }.to_json
    stub_request(:post, "https://api.twitter.com/2/oauth2/token")
      .to_return(status: 400, body: body)

    error = assert_raises(Xbookmark::AuthError) { auth.exchange_code_for_token(code: "BAD", verifier: "VERIFIER") }

    assert_match(/Token exchange failed \(400\): invalid_request: bad access_token=\[REDACTED\]/, error.message)
    refute_includes error.message, "ACCESSSECRET"
    refute_includes error.message, body
  end

  it "rejects malformed token exchange success bodies" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    stub_request(:post, "https://api.twitter.com/2/oauth2/token")
      .to_return(status: 200, body: "not-json")

    error = assert_raises(Xbookmark::AuthError) { auth.exchange_code_for_token(code: "CODE", verifier: "VERIFIER") }

    assert_match(/Token exchange returned invalid JSON/, error.message)
  end

  it "rejects token exchange responses without a positive expiry" do
    auth = described_class.new(fake_config(env_path: "/tmp/.env"), opener: false, env_path: "/tmp/.env")
    stub_request(:post, "https://api.twitter.com/2/oauth2/token")
      .to_return(status: 200, body: { access_token: "ACC", refresh_token: "REF" }.to_json)

    error = assert_raises(Xbookmark::AuthError) { auth.exchange_code_for_token(code: "CODE", verifier: "VERIFIER") }

    assert_match(/Token exchange returned invalid expires_in/, error.message)
  end

  it "raises AuthError when token endpoint returns non-2xx" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 400, body: '{"error":"invalid_grant"}')

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }
      assert_match(/Token refresh failed/, error.message)
    end
  end

  it "raises TransientAuthError when refresh token endpoint is temporarily unavailable" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 503, body: '{"error":"temporarily_unavailable"}')

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::TransientAuthError) { auth.refresh! }

      assert_match(/Token refresh failed \(503\): temporarily_unavailable/, error.message)
    end
  end

  it "sanitizes token endpoint error bodies during refresh" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      body = {
        error: "invalid_request",
        error_description: "bad refresh_token=REFRESHSECRET12345678901234567890"
      }.to_json
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 400, body: body)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh failed \(400\): invalid_request: bad refresh_token=\[REDACTED\]/, error.message)
      refute_includes error.message, "REFRESHSECRET"
      refute_includes error.message, body
    end
  end

  it "rejects malformed refresh success bodies before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: "not-json")

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned invalid JSON/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects non-object refresh success bodies before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: [].to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned an invalid token response/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "omits raw non-json refresh error bodies" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 400, body: "plain token=REFRESHSECRET12345678901234567890")

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_equal "Token refresh failed (400)", error.message
      refute_includes error.message, "REFRESHSECRET"
    end
  end

  it "rejects OAuth error refresh success bodies before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { error: "invalid_grant", error_description: "bad token" }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned error: invalid_grant: bad token/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects OAuth error refresh success bodies even when an access token is present" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200,
                   body: { access_token: "NEW", error: "invalid_grant", expires_in: 3600 }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned error: invalid_grant/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects refresh responses without access tokens before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { refresh_token: "ROTATED", expires_in: 3600 }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned no access token/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects refresh responses without expires_in before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "ROTATED" }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned invalid expires_in/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects refresh responses with zero expires_in before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "ROTATED", expires_in: 0 }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned invalid expires_in/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "rejects refresh responses with non-numeric expires_in before writing tokens" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\nX_ACCESS_TOKEN=KEEP\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "ROTATED", expires_in: "later" }.to_json)

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::AuthError) { auth.refresh! }

      assert_match(/Token refresh returned invalid expires_in/, error.message)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=KEEP"
    end
  end

  it "wraps refresh transport failures as AuthError" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_REFRESH_TOKEN=OLD\n")
      config = fake_config(env_path: env_path, refresh_token: "OLD")
      stub_request(:post, "https://api.twitter.com/2/oauth2/token")
        .to_raise(Faraday::TimeoutError.new("execution expired"))

      auth = described_class.new(config, opener: false, env_path: env_path)
      error = assert_raises(Xbookmark::TransientAuthError) { auth.refresh! }
      assert_match(/Token refresh transport failed: execution expired/, error.message)
    end
  end

  it "receives a matching OAuth callback code from the local server" do
    config = fake_config(env_path: "/tmp/.env")
    config.x_redirect_uri = "http://127.0.0.1:#{unused_local_port}/callback"
    auth = described_class.new(config, opener: false, env_path: "/tmp/.env")

    request_callback_async(config.x_redirect_uri, "state=ok&code=CODE")
    assert_equal "CODE", auth.wait_for_callback(state: "ok", timeout: 5)
  end

  it "shuts down the callback server when the interrupt handler runs" do
    config = fake_config(env_path: "/tmp/.env")
    config.x_redirect_uri = "http://127.0.0.1:#{unused_local_port}/callback"
    auth = described_class.new(config, opener: false, env_path: "/tmp/.env")
    Signal.stubs(:trap).with("INT").yields.returns("old-handler")
    Signal.stubs(:trap).with("INT", "old-handler").returns("old-handler")

    assert_includes capture_stderr {
      assert_raises(Xbookmark::AuthError) { auth.wait_for_callback(state: "ok", timeout: 5) }
    }, "auth login interrupted"
  end

  it "defaults to the keystore when no env file is loaded and resolves PATH lookups" do
    config = fake_config(env_path: nil)
    config.env_file = nil

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        auth = described_class.new(config, opener: false)
        assert_nil auth.instance_variable_get(:@env_path)
        assert_equal "keystore: memory", auth.send(:token_destination)

        tool = File.join(dir, "tool")
        File.write(tool, "#!/bin/sh\n")
        File.chmod(0o755, tool)
        with_env(ENV.to_h.merge("PATH" => dir)) do
          assert_equal tool, auth.send(:which, "tool")
        end

        with_env(ENV.to_h.merge("PATH" => "/no/such/dir")) do
          assert_nil auth.send(:which, "missing")
        end
      end
    end
  end

  it "falls back to the user env file when the automatic keystore is unavailable" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      config = fake_config(env_path: nil)
      config.env_file = nil
      Xbookmark::Keystore.stubs(:default).raises(StandardError, "no backend")
      Xbookmark::Paths.stubs(:user_env_path).returns(env_path)

      auth = described_class.new(config, opener: false)
      auth.write_tokens!({ "access_token" => "ACC", "expires_in" => 10 })

      assert_equal env_path, auth.instance_variable_get(:@env_path)
      assert_includes File.read(env_path), "X_ACCESS_TOKEN=ACC"
    end
  end

  it "rejects mismatched state and missing callback code" do
    [
      ["wrong-state", "state=bad&code=CODE"],
      ["missing-code", "state=ok"]
    ].each do |_case_name, query|
      config = fake_config(env_path: "/tmp/.env")
      config.x_redirect_uri = "http://127.0.0.1:#{unused_local_port}/callback"
      auth = described_class.new(config, opener: false, env_path: "/tmp/.env")

      request_callback_async(config.x_redirect_uri, query)
      error = assert_raises(Xbookmark::AuthError) { auth.wait_for_callback(state: "ok", timeout: 5) }
      assert_match(/no code/, error.message)
    end
  end

  it "times out when the OAuth callback never arrives" do
    config = fake_config(env_path: "/tmp/.env")
    config.x_redirect_uri = "http://127.0.0.1:#{unused_local_port}/callback"
    auth = described_class.new(config, opener: false, env_path: "/tmp/.env")

    error = assert_raises(Xbookmark::AuthError) { auth.wait_for_callback(state: "ok", timeout: 0.01) }
    assert_match(/timed out/, error.message)
  end

  def unused_local_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def request_callback_async(redirect_uri, query)
    uri = URI(redirect_uri)
    Thread.new do
      deadline = Time.now + 2
      begin
        socket = TCPSocket.new(uri.host, uri.port)
        socket.write("GET #{uri.path}?#{query} HTTP/1.1\r\nHost: #{uri.host}\r\nConnection: close\r\n\r\n")
        socket.read
      rescue Errno::ECONNREFUSED
        raise if Time.now >= deadline
        sleep 0.01
        retry
      ensure
        socket&.close
      end
    end
  end
end
