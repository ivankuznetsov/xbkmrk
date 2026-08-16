# frozen_string_literal: true

require_relative "../paths"

module Xbookmark
  module System
    module PackageManager
      module_function

      # Detect the host's primary package manager.
      # Returns one of: :brew, :pacman, :apt, :dnf, :zypper, :unknown
      def detect
        return :brew   if Xbookmark::Paths.macos? && which("brew")
        return :pacman if which("pacman")
        return :apt    if which("apt-get") || which("apt")
        return :dnf    if which("dnf")
        return :zypper if which("zypper")
        :unknown
      end

      # Return the shell command (as an Array) that installs `tool` via the
      # host package manager, or nil if we don't know how. The tool name is
      # the package name commonly used; we resolve aliases per manager
      # (e.g., whisper -> whisper-cpp on pacman).
      def install_command(tool, manager: detect)
        package = package_name(tool, manager)
        return nil if package.nil?

        case manager
        when :brew   then ["brew",   "install", package]
        when :pacman then ["sudo", "pacman", "-S", "--needed", package]
        when :apt    then ["sudo", "apt-get", "install", "-y", package]
        when :dnf    then ["sudo", "dnf",    "install", "-y", package]
        when :zypper then ["sudo", "zypper", "install", "-y", package]
        else nil
        end
      end

      PACKAGE_TABLE = {
        "ffmpeg"      => { default: "ffmpeg" },
        "whisper"     => { brew: "whisper-cpp", pacman: "whisper-cpp" },
        "secret-tool" => { pacman: "libsecret", apt: "libsecret-tools", dnf: "libsecret", zypper: "libsecret-tools" },
        # qmd has no standard package; users install it manually.
        "qmd"         => {}
      }.freeze

      def package_name(tool, manager)
        entry = PACKAGE_TABLE[tool.to_s]
        return nil unless entry
        entry[manager] || entry[:default]
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
