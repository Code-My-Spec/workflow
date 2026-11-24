# loop-clones-hosted-repos-with-a-clone-token: decision note

## Where the loop reaches a remote

All in `lib/workflow/checkout.ex`, all through its private `git/3`:

- `fetched/1`: `git fetch --all --quiet` in the main copy, from
  `Checkout.pinned/2`, whose one caller is `Manager.commit/2` (the manager's
  hand-in of a story by id).
- `follow/3`: `git remote update <remote>` before a landing, from
  `Checkout.promote/2` (callers: `Issue`, `Parts`, and tests).
- `pushed/4`: `git push <remote> HEAD:<branch>` after a landing, also from
  `promote/2`.
- Cloning: the loop never cloned. A main checkout is the manager's `"repo"`,
  found by `Checkout.landing/1`. Now, when that path does not exist yet
  (first setup) and the server says it hosts the repo, `landing/1` clones it
  there from `clone_url`. Its callers (`Manager` brief and `absent/3`,
  `Checkout.take_main/2`, `pinned/2`, `show/3`, the diff and log readers) are
  unchanged for a path that exists, and for any path when no server is
  configured or the server refuses.

## The rule: hosted or not (the owner's decision)

The code and config could not tell the two apart, and the owner decided: the
loop does not decide, it asks. With a `"server"` (`url` and `project_id`)
configured, `Workflow.CloneToken.auth/0` POSTs
`<server>/api/repo/clone_token` with the loop's sign-in bearer token
(`Workflow.SignIn.token/2`) and `{"project_id": ...}`.

- A 200 with `token`, `expires_at` (unix seconds or ISO 8601) and `clone_url`:
  hosted. That one git command gets the token.
- Any 4xx: not hosted (for example, on the customer's own GitHub). git runs
  exactly as today, with the same args and no `GIT_CONFIG_*`.
- No server configured: no request, today's path.

**This replaces recorded criterion 4** ("no clone_token request"). Read it as
the owner restated it: a project on the customer's own GitHub may be asked
about once per lifetime and is then left on today's path, with its git
commands exactly as today.

## Kept for one lifetime, never forever

The answer is kept in `:persistent_term` (memory only), keyed by the server's
base URL and the project:

- A token is reused until 300 seconds before its `expires_at`. After that,
  the next git command asks again.
- A refusal is kept for 3600 seconds, about one token's lifetime.
- A server that cannot be reached, or a 5xx, from a project never known to be
  hosted: today's path, nothing kept, asked again next time.
- The same failure for a project known to be hosted fails that git step with
  one line: `No clone token for project <p> from <base>: <why>`. The line
  never holds the token. Each caller treats it as any other git failure:
  `promote` notes the failed push, and `follow` and `fetched` carry on as
  with a failed fetch.

## How the token reaches git

It goes only into the env of that one command, as `GIT_CONFIG_COUNT=1`,
`GIT_CONFIG_KEY_0=http.<scheme>://<host>/.extraHeader` and
`GIT_CONFIG_VALUE_0=Authorization: Basic base64(x-access-token:<token>)`.
This is GitHub's form for an installation token over HTTPS.

- The key is scoped to `clone_url`'s host, so `fetch --all` sends the token to
  no other host.
- A `clone_url` that is not http(s) (a test's local path) uses plain
  `http.extraHeader`.
- Env rather than `-c` keeps the token out of the process's arguments.
- It is never put in a remote URL: the clone's `origin` is `clone_url` as
  given. It is never written to `.git/config` or any file, and never logged.
- The bearer sign-in token goes only in the request's `authorization` header.
- No new config option was added.

## Check

`test/workflow/loop_clones_hosted_repos_test.exs`: a loopback Bandit stands in
for the server, with a sign-in credential in a state dir under tmp. It uses
real git in temporary repos with a local bare remote, and a `:cmd` wrapper
that records each git command's args and env. Five tests:

- a 200 answer makes fetch, remote update and push carry the token through
  `http.extraHeader`, from one request; the token is in no remote URL, no
  file under the tmp dir or the works dir, and no captured log line;
- a refusal leaves those commands exactly as today, and a second fetch asks
  nothing;
- a token near expiry is refreshed, and the fresh one is reused;
- a hosted repo whose refresh gets a 500 fails its push with one line that
  names no token;
- with no main checkout, `landing/1` clones from `clone_url` with the token.

All five fail on the code before the fix.
