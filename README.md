# workflow

## Install

On an Apple silicon Mac:

    brew install codemyspec-loop      # from the tap that holds the formula
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

    brew services start codemyspec-loop

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

## Recipes and the evidence folder

The loop analyses a project by running `just <recipe> <dir>` (`run`, `certify`,
`ci`, `demo`, ...), where `<dir>` is that run's own analysis folder.

The `ci` recipe may leave evidence there: a project that wants it writes
`<dir>/evidence/<journey id>/` holding that journey's stage screenshots (`.png`).
After `ci` exits 0, and only when `config.json` has a `"server"`, the loop sends
each sub-folder with at least one `.png`: its `.png` files plus
`stories/<journey id>.yml` from the ci checkout when that file exists, by
`POST <server url>/api/loop/evidence` (the loop's bearer token; body
`{project_id, commit, journey, files}`; answer `{folder, puts: {name: url}}`),
then a PUT of each file to its url. It is sent before the ci checkout can be
pruned. No folder or no `.png` sends nothing. A failure logs one warning and
never changes ci's result.

When `ci` fails, a project may have a `retry` recipe: the loop runs
`just retry <dir2> <dir>` in the same ci checkout, where `<dir2>` is a new run folder
beside the first, so both runs' evidence is kept and neither overwrites the other,
and `<dir>` is the first run's folder (its meta.json and SARIF), which `retry` may
read to learn what failed but must not change.
`retry` runs only what failed (for a mix project, `mix test --failed`) and writes
its SARIF into `<dir2>`, as `ci` does into `<dir>`. A failing retry leaves the
tree red. A passing one is green: each test that failed in the first run's SARIF
is a flake, named (file and test) to the manager and in the work's report to the
server (`"flakes"`). A project with no `retry` recipe has `ci` run once more instead.

## MCP endpoints

- `POST /mcp` is the chat's endpoint: it offers only `say` and `inbox`, and
  refuses any other tool as unknown.
- `POST /mcp/manager` is for whoever acts as the manager: it offers the
  manager's own tools (`hand_in`, `record`, `decide`, `look`, `tell` and
  `stop`, with the same inputs the service-run manager has) plus `say` and
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

`"go"` is the sha256 hex of the owner's word. A waiting prod provision runs
only on the owner's go: POST /work/go from the service's own address, with
`{"id": ..., "root" or "repo": ..., "word": ...}` whose sha256 equals that
hash. With no `"go"`, every prod go is refused. Set it with

    printf %s 'the word' | shasum -a 256

put the hex in `config.json` as `{"go": "<hex>"}`, and restart the service:
the hash is read once at boot. Neither the word nor the hash is logged or
written anywhere by the loop. An agent that can write `config.json` and
restart the service could still replace the hash; this stops a plain call,
not that.

## License

Apache License 2.0. See `LICENSE`.
