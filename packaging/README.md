# Packaging the loop for Homebrew

The loop is released as a plain `mix release` tarball (bundled ERTS, no Elixir
or Erlang needed), the same shape as the `codemyspec` formula's.

## Build (Apple silicon Mac, with Elixir installed)

    cd workflow
    elixir -S mix deps.get
    MIX_ENV=prod elixir -S mix release --overwrite
    tar -C _build/prod/rel/workflow -czf codemyspec-loop-darwin-arm64.tar.gz .
    shasum -a 256 codemyspec-loop-darwin-arm64.tar.gz

Upload the tarball, then put its URL, sha256 and version into
`codemyspec-loop.rb` (the marked placeholders) and add the file to the tap.
It is built for the architecture and macOS of the machine that builds it.

## Before using it

- The `claude` CLI installed and signed in (`claude` once, interactively).
- The loop signed in to its server: `codemyspec-loop sign-in` (or `mix workflow.sign_in`),
  once `config.json` names the server. It keeps its sign-in in `~/.codemyspec`.
- `~/.workflow/config.json`, for example:

      {
        "manager": {"agent": {"provider": "claude-code"}, "repo": "/path/to/your/repo", "cap": 3},
        "server": {"url": "wss://YOUR-SERVER/socket/websocket", "project_id": "YOUR-PROJECT-ID"}
      }

## Install and run

    brew install codemyspec-loop      # from the tap that holds the formula
    brew services start codemyspec-loop
    brew services stop codemyspec-loop

It listens on 127.0.0.1:4010 (`WORKFLOW_PORT` overrides). Logs: `$(brew --prefix)/var/log/codemyspec-loop.log`.
To run it by hand without the service: `WORKFLOW_PORT=4099 codemyspec-loop start`.
