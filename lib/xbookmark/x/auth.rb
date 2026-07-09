# frozen_string_literal: true

require "securerandom"
require "digest"
require "base64"
require "uri"
require "socket"
require "faraday"
require "faraday/retry"
require "json"
require "fileutils"
require_relative "../keystore"
require_relative "../paths"

module Xbookmark
  module X
    class Auth
      AUTH_HOST  = "https://twitter.com"
      AUTH_PATH  = "/i/oauth2/authorize"
      TOKEN_URL  = "https://api.twitter.com/2/oauth2/token"
      SCOPES     = %w[tweet.read users.read bookmark.read offline.access].freeze
      LOCAL_PORT = 7799
      DEFAULT_CALLBACK_TIMEOUT = 600 # seconds — bound the OAuth callback wait

      AuthResult = Struct.new(:env_file, :access_token, :refresh_token, :expires_at, keyword_init: true)

      def initialize(config, opener: nil, env_path: :auto, keystore: :auto)
        @config = config
        @opener = opener
        @keystore = resolve_keystore(keystore)
        @env_path = resolve_env_path(env_path)
      end

      def login
        verifier = SecureRandom.urlsafe_base64(64)
        challenge = pkce_challenge(verifier)
        state = SecureRandom.hex(16)

        url = build_authorize_url(state: state, challenge: challenge)
        warn "Opening browser to authorize xbookmark..."
        warn url
        try_open(url)

        code = wait_for_callback(state: state)
        token = exchange_code_for_token(code: code, verifier: verifier)
        write_tokens!(token)
        AuthResult.new(
          env_file: token_destination,
          access_token: token["access_token"],
          refresh_token: token["refresh_token"],
          expires_at: token_expires_at(token)
        )
      end

      # Refresh tokens using the saved refresh_token; persist rotated tokens.
      def refresh!
        raise AuthError, "Missing refresh token; run `xbookmark auth login` first." if @config.x_refresh_token.to_s.empty?

        body = {
          grant_type: "refresh_token",
          refresh_token: @config.x_refresh_token,
          client_id: @config.x_client_id
        }

        res = refresh_token_response(body)

        unless res.success?
          error_class = transient_token_response?(res) ? TransientAuthError : AuthError
          raise error_class, token_response_error("Token refresh failed", res)
        end

        token = parse_success_token!(res.body, operation: "Token refresh")
        write_tokens!(token, preserve_refresh: token["refresh_token"].nil?)
        AuthResult.new(
          env_file: token_destination,
          access_token: token["access_token"],
          refresh_token: token["refresh_token"] || @config.x_refresh_token,
          expires_at: token_expires_at(token)
        )
      end

      def pkce_challenge(verifier)
        digest = Digest::SHA256.digest(verifier)
        Base64.urlsafe_encode64(digest, padding: false)
      end

      def build_authorize_url(state:, challenge:)
        params = {
          response_type: "code",
          client_id: @config.x_client_id,
          redirect_uri: @config.x_redirect_uri,
          scope: SCOPES.join(" "),
          state: state,
          code_challenge: challenge,
          code_challenge_method: "S256"
        }
        "#{AUTH_HOST}#{AUTH_PATH}?#{URI.encode_www_form(params)}"
      end

      def try_open(url)
        return if @opener == false
        if @opener
          @opener.call(url)
        elsif which("xdg-open")
          system("xdg-open", url, out: File::NULL, err: File::NULL)
        elsif which("open")
          system("open", url, out: File::NULL, err: File::NULL)
        end
      rescue StandardError
        # Headless / SSH — printed URL is the fallback.
      end

      def wait_for_callback(state:, timeout: DEFAULT_CALLBACK_TIMEOUT)
        port = URI(@config.x_redirect_uri).port || LOCAL_PORT
        host = URI(@config.x_redirect_uri).host || "127.0.0.1"
        captured = nil
        server = TCPServer.new(host, port)

        prev_int_handler = Signal.trap("INT") do
          warn "[xbookmark] auth login interrupted; shutting down callback server."
          close_callback_server(server)
        end

        timed_out = false
        begin
          server_thread = Thread.new do
            captured = serve_callback_once(server, state)
          rescue IOError, SystemCallError
            nil
          ensure
            close_callback_server(server)
          end

          if server_thread.join(timeout).nil?
            timed_out = true
            close_callback_server(server)
            server_thread.join(5)
          end
        ensure
          Signal.trap("INT", prev_int_handler) if prev_int_handler
        end

        raise AuthError, "OAuth callback timed out after #{timeout}s — re-run `xbookmark auth login`." if timed_out
        raise AuthError, "OAuth flow returned no code." unless captured
        captured
      end

      def serve_callback_once(server, expected_state)
        client = server.accept
        request_line = client.gets.to_s
        drain_request_headers(client)
        status, body, query = callback_response(request_line, expected_state)
        client.write(http_response(status, body))
        status == 200 ? query["code"] : nil
      ensure
        client&.close
      end

      def callback_response(request_line, expected_state)
        _method, target, = request_line.split(" ", 3)
        uri = URI(target.to_s)
        query = URI.decode_www_form(uri.query.to_s).to_h

        if uri.path != "/callback"
          [404, "Not found.", query]
        elsif query["state"] != expected_state
          [400, "State mismatch — refusing.", query]
        elsif query["code"].to_s.empty?
          [400, "Missing code parameter.", query]
        else
          [200, "Authorization complete. You can close this tab.", query]
        end
      rescue URI::InvalidURIError
        [400, "Invalid callback request.", {}]
      end

      def drain_request_headers(client)
        while (line = client.gets)
          break if line == "\r\n" || line == "\n"
        end
      end

      def http_response(status, body)
        reason = {
          200 => "OK",
          400 => "Bad Request",
          404 => "Not Found"
        }.fetch(status)
        [
          "HTTP/1.1 #{status} #{reason}",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Length: #{body.bytesize}",
          "Connection: close",
          "",
          body
        ].join("\r\n")
      end

      def close_callback_server(server)
        server.close unless server.closed?
      rescue IOError
        nil
      end

      def exchange_code_for_token(code:, verifier:)
        body = {
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @config.x_redirect_uri,
          client_id: @config.x_client_id,
          code_verifier: verifier
        }

        res = token_exchange_response(body)

        unless res.success?
          error_class = transient_token_response?(res) ? TransientAuthError : AuthError
          raise error_class, token_response_error("Token exchange failed", res)
        end

        parse_success_token!(res.body, operation: "Token exchange")
      end

      def write_tokens!(token, preserve_refresh: false)
        access  = token["access_token"]
        refresh = token["refresh_token"] || (preserve_refresh ? @config.x_refresh_token : nil)
        expires = token_expires_at(token).to_i

        updates = {
          "X_ACCESS_TOKEN" => access,
          "X_TOKEN_EXPIRES_AT" => expires.to_s
        }
        updates["X_REFRESH_TOKEN"] = refresh if refresh

        if @env_path
          atomic_update_env(@env_path, updates)
        else
          write_tokens_to_keystore!(updates)
        end
      end

      private

      SECRET_LIKE_VALUE = /[A-Za-z0-9_\-.~+\/=]{32,}/
      SECRET_FIELD = /
        \b(access_token|refresh_token|client_secret|authorization|token)
        (["']?\s*[:=]\s*["']?)
        [^"',}\s]+
      /ix

      def basic_auth(user, pass)
        "Basic " + Base64.strict_encode64("#{user}:#{pass}")
      end

      def token_response_error(prefix, response)
        detail = token_error_detail(response.body)
        message = "#{prefix} (#{response.status})"
        detail ? "#{message}: #{detail}" : message
      end

      def transient_token_response?(response)
        response.status.to_i == 429 || response.status.to_i >= 500
      end

      def parse_success_token!(body, operation:)
        parsed = JSON.parse(body)
        unless parsed.is_a?(Hash)
          raise AuthError, "#{operation} returned an invalid token response."
        end

        if parsed["error"]
          detail = [parsed["error"], parsed["error_description"]]
                   .compact
                   .map { |value| redact_secret_like_values(value) }
                   .reject(&:empty?)
                   .uniq
                   .join(": ")
          raise AuthError, "#{operation} returned error#{detail.empty? ? "" : ": #{detail}"}"
        end

        if parsed["access_token"].to_s.empty?
          raise AuthError, "#{operation} returned no access token."
        end
        unless positive_integer?(parsed["expires_in"])
          raise AuthError, "#{operation} returned invalid expires_in."
        end

        parsed
      rescue JSON::ParserError
        raise AuthError, "#{operation} returned invalid JSON."
      end

      def positive_integer?(value)
        Integer(value, exception: false).to_i.positive?
      end

      def token_error_detail(body)
        parsed = JSON.parse(body)
        return unless parsed.is_a?(Hash)

        [parsed["error"], parsed["error_description"]]
          .compact
          .map { |value| redact_secret_like_values(value) }
          .reject(&:empty?)
          .uniq
          .join(": ")
          .yield_self { |detail| detail.empty? ? nil : detail }
      rescue JSON::ParserError, TypeError
        nil
      end

      def redact_secret_like_values(value)
        value.to_s
             .gsub(/[[:cntrl:]]+/, " ")
             .gsub(SECRET_FIELD, "\\1\\2[REDACTED]")
             .gsub(SECRET_LIKE_VALUE, "[REDACTED]")
             .strip[0, 240]
      end

      def token_expires_at(token)
        Time.now.to_i + (token["expires_in"] || 0).to_i
      end

      def token_conn
        @token_conn ||= Faraday.new do |f|
          f.request :retry, max: 1, interval: 0.5,
                    retry_statuses: [429, 500, 502, 503, 504]
          f.options.open_timeout = 5
          f.options.timeout = 30
          f.adapter Faraday.default_adapter
        end
      end

      def token_exchange_response(body)
        post_token_request(body)
      rescue Faraday::Error => e
        raise TransientAuthError, "Token exchange transport failed: #{e.message}"
      end

      def refresh_token_response(body)
        post_token_request(body)
      rescue Faraday::Error => e
        raise TransientAuthError, "Token refresh transport failed: #{e.message}"
      end

      def post_token_request(body)
        token_conn.post(TOKEN_URL) do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          if @config.x_client_secret && !@config.x_client_secret.to_s.empty?
            req.headers["Authorization"] = basic_auth(@config.x_client_id, @config.x_client_secret)
          end
          req.body = URI.encode_www_form(body)
        end
      end

      def resolve_keystore(keystore)
        return nil if keystore.nil?
        return keystore unless keystore == :auto

        Xbookmark::Keystore.default
      rescue StandardError
        nil
      end

      def resolve_env_path(env_path)
        return env_path unless env_path == :auto
        return @config.env_file if @config.env_file

        # The macOS `security` CLI accepts generic-password values only as
        # argv, so keep rotating OAuth tokens in the stable 0600 user env file.
        return Xbookmark::Paths.user_env_path if @keystore.nil? || @keystore.backend_name == "keychain"

        nil
      end

      def token_destination
        @env_path || "keystore: #{@keystore.backend_name}"
      end

      def write_tokens_to_keystore!(updates)
        raise AuthError, "No token store available; set XBOOKMARK_ENV_FILE and retry auth login." unless @keystore

        updates.each { |key, value| @keystore.set(key, value) }
      end

      def atomic_update_env(path, updates)
        FileUtils.mkdir_p(File.dirname(path))
        existing = File.exist?(path) ? File.read(path).each_line.to_a : []
        keys = updates.keys
        out_lines = []
        seen = {}
        existing.each do |line|
          if (m = line.match(/^([A-Z0-9_]+)=/)) && updates.key?(m[1])
            out_lines << "#{m[1]}=#{updates[m[1]]}\n"
            seen[m[1]] = true
          else
            out_lines << line
          end
        end
        keys.each do |k|
          next if seen[k]
          out_lines << "\n" if out_lines.any? && !out_lines.last.end_with?("\n")
          out_lines << "#{k}=#{updates[k]}\n"
        end
        tmp = "#{path}.tmp.#{Process.pid}.#{rand(10_000)}"
        # Tighten permissions BEFORE writing secrets so OAuth tokens never
        # touch disk under the default 0644 umask.
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(out_lines.join)
        end
        File.rename(tmp, path)
        File.chmod(0o600, path)
      end

      def which(cmd)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          full = File.join(dir, cmd)
          return full if File.executable?(full) && !File.directory?(full)
        end
        nil
      end
    end
  end
end
