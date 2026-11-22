# Packaging the loop for Homebrew

The loop is released as a plain `mix release` tarball (bundled ERTS, no Elixir
or Erlang needed), installed by the formula `packaging/codemyspec-loop.rb` as
the `workflow` command.

## Build (Apple silicon Mac, with Elixir and just installed)

1. Check out the commit tagged `v3.0.0`, so the release reports version 3.0.0.
2. In the repository's root, run, giving the CodeMySpec app's repository:

       just package /path/to/code_my_spec-phx-new-generator

   It copies that repository's `plugins/phoenix` (into the release as
   `plugin/`) and `plugins/claude/directory/skills/interview/SKILL.md` (as
   `instructions.md`), which `workflow init` names by default. With no path, a
   path that does not exist, or a path missing either one, it stops, names what
   is missing, and builds no tarball. Check both for secrets, personal paths,
   emails and names before you build, since the tarball is public.

   It builds the prod release, makes
   `_build/codemyspec-loop-darwin-arm64.tar.gz` from it, and prints the
   tarball's path (`tarball: ...`) and its sha256 (`sha256: ...`).
3. Upload `codemyspec-loop-darwin-arm64.tar.gz` where Homebrew can download it.
4. In `packaging/codemyspec-loop.rb`, set the two placeholder lines and
   nothing else:
   - `url`: the uploaded tarball's url.
   - `sha256`: the sha256 that `just package` printed.
5. Hand `packaging/codemyspec-loop.rb` off to the tap that holds the formula.

The tarball is built for the architecture and macOS of the machine that builds it.

## Install and run

    brew install codemyspec-loop      # from the tap that holds the formula
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

    brew services start codemyspec-loop
    brew services stop codemyspec-loop

It listens on 127.0.0.1:4010 (`WORKFLOW_PORT` overrides). Logs: `$(brew --prefix)/var/log/codemyspec-loop.log`.
To run it by hand without the service: `WORKFLOW_PORT=4099 workflow start`.
