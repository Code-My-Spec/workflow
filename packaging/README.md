# Packaging the loop for Homebrew

The loop is released as a plain `mix release` tarball (bundled ERTS, no Elixir
or Erlang needed), installed by the formula `packaging/codemyspec.rb` as
the `workflow` command.

## Build (Apple silicon Mac, with Elixir and just installed)

Check out the commit tagged `v<version>`, then, in the repository's root, run,
giving the version and the CodeMySpec app's repository:

    just release <version> <app>

It refuses unless the version is N.N.N and HEAD is tagged `v<version>` (it
never tags). It runs `just package <app>`, which copies the app's
`plugins/phoenix` and interview skill into the release and builds
`_build/codemyspec-darwin-arm64.tar.gz` (the tarball is public: it stops on
personal paths, emails and keys). It uploads the tarball as GitHub release
`v<version>`, fills `packaging/codemyspec.rb`'s `url` and `sha256`
in, and pushes that formula to Code-My-Spec/homebrew-tap.

The tarball is built for the architecture and macOS of the machine that builds it.

## Build by hand (publishes nothing)

In the repository's root, giving the CodeMySpec app's repository, run:

    just package <app>

It prints two lines, `tarball: <path>` and `sha256: <hash>`. Copy
`packaging/codemyspec.rb` and, in the copy, replace `__URL__` with the url the
tarball will be downloaded from (`.../releases/download/v<version>/...`, which
is where Homebrew reads the version from) and `__SHA256__` with the printed
hash. Those two are the only lines to edit. Then
hand off the tarball and the filled-in formula to the owner, who uploads the
tarball and puts the formula in the tap.

## Install and run

    brew install codemyspec           # from the tap that holds the formula
    workflow sign-in                  # once ~/.workflow/config.json names the server

Install Claude Code (the `claude` command) yourself, since brew does not provide
it, and run `claude` once to sign in:

    curl -fsSL https://claude.ai/install.sh | bash

The formula brings `git` and `just`. `~/.workflow/config.json`, for example:

      {
        "manager": {"agent": {"provider": "claude-code"}, "repo": "/path/to/your/repo", "cap": 3},
        "server": {"url": "wss://YOUR-SERVER/socket/websocket", "project_id": "YOUR-PROJECT-ID"}
      }

Run it as a service:

    brew services start codemyspec
    brew services stop codemyspec

It listens on 127.0.0.1:4010 (`WORKFLOW_PORT` overrides). Logs: `$(brew --prefix)/var/log/codemyspec.log`.
To run it by hand without the service: `WORKFLOW_PORT=4099 workflow start`.
