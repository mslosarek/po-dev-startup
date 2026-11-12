# dev-startup

Starts the full local dev environment — UI, Admin UI, the core API, the admin
API, and Postgres/Redis via Docker Compose — in one tmux session with a
split-pane layout.

## Prerequisites

- `tmux` (`brew install tmux`)
- AWS CLI configured for SSO (`aws sso login` runs automatically on `start`)
- `nvm`, `yarn`, Docker Desktop
- A checkout of the ProsperOps monorepo. By default the script uses the
  sibling directory `../core` next to `dev-startup/`; pass a different path
  to run from a git worktree instead (see [Using a worktree](#using-a-worktree)).
  Everything it runs lives inside the monorepo as subfolders:
  - `core/core` — the core API (server + server-admin)
  - `core/ui` — the customer console
  - `core/admin-ui` — the internal admin console

## Usage

```sh
./dev-split.sh start   [monorepo-dir]  # start everything, attach to the session
./dev-split.sh stop    [monorepo-dir]  # kill the tmux session and docker-compose down
./dev-split.sh restart [monorepo-dir]  # stop, then start
./dev-split.sh status  [monorepo-dir]  # show whether the session is up + docker-compose ps
./dev-split.sh attach                  # re-attach to an already-running session
./dev-split.sh logs                    # dump each pane's current scrollback to pane-*.log
```

`start` is also how you reconnect day-to-day: if a session is already
running, it just attaches you to it instead of starting a second one.

### Using a worktree

The optional `monorepo-dir` argument points the script at a different
checkout of the monorepo, such as a git worktree, in place of `../core`. It
must contain the `core`, `ui` and `admin-ui` folders.

```sh
./dev-split.sh start ~/Worktrees/my-branch
```

The session remembers which checkout it was started from, so `stop`,
`status` and `restart` run against that same checkout without the argument
being repeated. When the argument is left out, the script uses the running
session's checkout if there is one, and `../core` otherwise.

Only one session (`dev-env`) runs at a time, since every checkout uses the
same ports. To switch checkouts, restart with the new path — this stops the
old checkout's services and starts the new one's:

```sh
./dev-split.sh restart ~/ClaudeWorktrees/core/louisg/other-branch
```

Running `start <path>` while a session from a different checkout is up
prints a warning and attaches to the existing session rather than replacing
it.

## Layout

`start` creates one tmux session (`dev-env`) with two windows:

```
Window 1 "dev"                          Window 2 "control"
┌─────────────┬─────────────┐           ┌─────────────────┐
│  0: UI      │ 1: Admin UI │           │   plain shell    │
├─────────────┼─────────────┤           │  for ad-hoc      │
│ 2: Server   │ 3: Server   │           │  commands        │
│             │    Admin    │           └─────────────────┘
├─────────────┴─────────────┤
│   4: Docker Compose        │
└─────────────────────────────┘
```

Each service pane prints a cyan `==== NAME ====` header when it starts, and
a red "exited with code N" message if the process dies, so a crash is
obvious instead of the pane just going quiet.

## Navigating tmux

tmux commands are a prefix key followed by a letter — the default prefix is
**Ctrl+b** (shown below as `C-b`). If your `~/.tmux.conf` remaps the prefix,
use that key instead.

| Action                                                    | Keys                                                        |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| Switch to window 1 or 2                                   | `C-b 1` / `C-b 2`                                           |
| Switch pane                                               | `C-b` + arrow key                                           |
| Jump to pane by number                                    | `C-b q`, then the number shown                              |
| Resize pane                                               | `C-b` + `Alt` + arrow key                                   |
| Zoom current pane to full screen (toggle)                 | `C-b z`                                                     |
| Scroll back / copy mode                                   | `C-b [`, arrow keys or `PgUp`/`PgDn` to scroll, `q` to exit |
| Detach (leave it running, return to your normal terminal) | `C-b d`                                                     |

### Opening and closing things

- **Detach vs. stop**: `C-b d` detaches you from tmux but leaves every
  service running in the background — run `./dev-split.sh attach` later to
  come back. Use this when you just want your terminal back for a bit.
- **Stop everything**: `./dev-split.sh stop` (from anywhere, doesn't need to
  be run inside tmux) kills the whole session and brings docker-compose
  down. This is the normal way to end a dev session.
- **Restart everything**: `./dev-split.sh restart` — stop, then start again.
  This is simpler than trying to restart individual panes, so there's no
  per-service restart command; just restart the whole thing.
- **Closing a single pane manually**: if a pane's process has exited, it
  waits at "Press Enter to close pane." — pressing Enter closes just that
  pane (`exit` or `C-d` works too for a live shell). Closing all panes in a
  window closes the window.
- **Killing the session outright from inside tmux**: `C-b &` kills the
  current window, or type `tmux kill-session -t dev-env` in any pane — but
  prefer `./dev-split.sh stop` so Docker Compose also gets shut down.

## Troubleshooting

- `start` says the session already exists and just attaches you — if the
  panes look stale or broken, run `stop` first, then `start`.
- AWS SSO login failing stops `start` before anything else runs — fix SSO
  access first.
