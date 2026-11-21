# Homebrew formula for the CodeMySpec loop (macOS, Apple silicon).
#
# Installs the plain `mix release` tarball (bundled ERTS, no Elixir/Erlang
# needed). Named `codemyspec-loop` so it cannot collide with `codemyspec`.
class CodemyspecLoop < Formula
  desc "CodeMySpec loop: runs agents on works, dials the CodeMySpec server"
  homepage "https://codemyspec.com"
  # PLACEHOLDER: set to the released version.
  version "0.0.0"
  # PLACEHOLDER: the uploaded tarball's URL and sha256. Nothing is uploaded yet.
  url "https://example.invalid/REPLACE_ME/codemyspec-loop-darwin-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  depends_on arch: :arm64
  # The release's crypto NIF links Homebrew's OpenSSL.
  depends_on "openssl@3"

  def install
    # The tarball extracts to bin/, lib/, releases/, erts-*.
    libexec.install Dir["*"]
    # A wrapper, not a symlink, so the launcher resolves its root from libexec.
    (bin/"codemyspec-loop").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/workflow" "$@"
    SH
    chmod 0755, bin/"codemyspec-loop"
  end

  service do
    run [opt_bin/"codemyspec-loop", "start"]
    keep_alive true
    # launchd gives a bare PATH; the loop shells out to the `claude` CLI.
    environment_variables PATH: "#{HOMEBREW_PREFIX}/bin:#{Dir.home}/.local/bin:/usr/bin:/bin"
    log_path var/"log/codemyspec-loop.log"
    error_log_path var/"log/codemyspec-loop.log"
  end

  def caveats
    <<~EOS
      Needs the `claude` CLI installed and signed in, and ~/.workflow/config.json
      (see the README). The loop listens on 127.0.0.1:4010; set WORKFLOW_PORT to change it.
    EOS
  end

  test do
    assert_match "workflow", shell_output("#{bin}/codemyspec-loop version")
  end
end
