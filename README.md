# workflow

## Install

On an Apple silicon Mac:

    brew install codemyspec           # from the tap that holds the formula
    workflow init --repo /path/to/repo
    workflow sign-in                  # only when init was given a server

`workflow init` writes `~/.workflow/config.json` and refuses to overwrite one.
Init leaves the packaged plugin and chat instructions out of config.json: the
loop finds them in the installed package at each start, so the package alone is
enough and they follow the installed version across upgrades; `brew upgrade`
needs no new init. It also takes `--plugin DIR` (a plugin of your own, written
into config.json, which wins over the packaged one) and `--server URL --project ID`.

A config.json written by 3.0.1's init names that version's Cellar folder for
`"plugin"` and `"instructions"`. Once an upgrade removes it, the service stops
at start naming the missing path: delete those two keys from config.json and
start it again to use the installed version's.

Then install Claude Code (the `claude` command), which brew does not provide,
and run `claude` once to sign in:

    curl -fsSL https://claude.ai/install.sh | bash

Then start the service:

    brew services start codemyspec

How the package is built: `packaging/README.md`.

## Running from source

The loop service. Start it with:

    mix run --no-halt

It serves on 127.0.0.1:4010 and keeps its own files in `~/.workflow/`
(works in flight in `works/`, inboxes in `inbox/`).

## Configuration file

At boot it reads its manager and recipients settings from
`~/.workflow/config.json` (beside the works directory, wherever `:works_dir`
points). With no file it starts without a manager or recipients, and
POST /manager answers 404. A file that is not valid JSON stops the boot with a
message naming the file. A setting also given with `-e` code wins over the file.

Example `~/.workflow/config.json`:

```json
{
  "manager": {
    "agent": {"provider": "claude-code"},
    "repo": "/path/to/repo",
    "cap": 3
  },
  "recipients": {
    "me": {"kind": "chat"},
    "dev": {"kind": "claude-code", "socket": "/tmp/dev.sock"},
    "other": {"kind": "codex", "thread": "thread-id"}
  }
}
```

`"manager"` is as described in `Workflow.Manager`; `"recipients"` as in
`Workflow.Messages`.

Work lands in the repository's primary checkout on this machine (the first
line of `git worktree list`), on whatever branch it has checked out, even when
`manager.repo` names a linked worktree of it. The manager is told that folder
and branch, and names them to the person before the first work it hands in.

## Recipes, evidence and events

The loop analyses a project by running `just <recipe> <dir>` (`run`, `certify`,
`demo`, ...), where `<dir>` is that run's own analysis folder. The verdict is
the recipe's exit code.

Each `just run` and `just certify` is given `EVIDENCE_CONTEXT` (`run/<work id>`
or `certify/<work id>`) and one `EVIDENCE_CORRELATION` uuid. Afterwards each new
`.code_my_spec/evidence/*.sarif` file and each file in a new
`.code_my_spec/evidence/<guid>/` folder is sent over the server channel: the
loop pushes `presign` `{project_id, files}`, PUTs each file to the url in the
reply's `puts`, pushes `uploaded` `{project_id, guids}`, and deletes what it
sent. With no server or no reply it logs one line and goes on.

A work's last step, `ci`, is an external step: the work waits there, holding
only its record, until a `ci` event is recorded for it. The server pushes
`event` `{work, name, payload}` on `loop:<project>`; locally the same is
`POST /works/:id/events {"name", "payload"}`. A ci payload is `{verdict, tree,
commit, failing, flaky}`: green is done, flaky is done and hands in one issue
per flaky test, red sends the work back to its coder with the failing tests.
A journey's `approve` waits on an event named `approve` the same way. After it
pushes the main copy, the loop pushes `pushed` `{branch, commit}`.

## MCP endpoints

- `POST /mcp` is the chat's endpoint: it offers only `say` and `inbox`, and
  refuses any other tool as unknown.
- `POST /mcp/manager` is for whoever acts as the manager: it offers the
  manager's own tools (`hand_in`, `decide`, `look`, `tell`, `stop` and
  `message_chat`, which sends the person's chat a message over the server
  line, with the same inputs the service-run manager has) plus `say` and
  `inbox`. Their calls do what the
  service-run manager's tools do, with the `"repo"`, `"project"`, `"cap"` and
  `"agents"` from the manager settings, and answer what those tools answer.
  With no manager settings it answers 404.

The manager's `"agent"` is optional. With a repo and no agent the service
boots and `POST /mcp/manager` works, but no manager turn is ever run: a `say`
to the manager is delivered by its recipient kind (a `"manager"` recipient of
kind claude-code or codex, or otherwise kept in the manager's inbox).

`"push"` names where the main copy's branch is pushed after a work lands:
`{"remote": "origin", "branch": "dev"}`, which are also the defaults. A main
copy without that remote pushes nothing. A refused push does not stop the work
landing; the promote result's note carries the remote's message.

`"instructions"` is the path of a text file: the brief a chat is given when it
connects. The file is read at boot, and the answer to an MCP `initialize` on
POST /mcp carries its contents as `instructions`. If the file starts with a
block between two `---` lines (a skill's front matter), that block is dropped.
A file that is not there stops the boot with a message naming it. With no
`"instructions"`, `initialize` carries no instructions.

```json
{"instructions": "/path/to/brief.md"}
```

## License

Apache License 2.0. See `LICENSE`.
