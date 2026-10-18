# User Constraints & Environment Facts (main session)

Authoritative addendum to `docs/requirements.md`. The planner and all workers must honor these.

> **The requirements file is `docs/requirements.md`** (renamed by the user from `docs/main.md` on 2026-10-18;
> content is unchanged). Any older reference to `docs/main.md` in scout output means the same file.
>
> ⚠️ **CLEANUP REQUIRED:** `docs/main.md` currently exists only as a **symlink → `requirements.md`**, added so
> scouts launched before the rename wouldn't break. **Delete `docs/main.md`** once all scouts/planner/workers are
> done. Use `docs/requirements.md` in every new task and file from now on.

## Temporary test remote — MUST be removable later

> "I configured my machine so that `ssh localhost` works without having to use a password. For now,
> you can use localhost as a remote for implementing and evaluating the implementation, but in the
> future it should be removed."

Interpretation for the plan:

- `localhost` is a **dev/CI fixture remote only**. It is for implementing + evaluating the remote code paths now.
- **Do NOT hardcode `localhost`** anywhere in product code, default config, theme list, or docs as a supported
  feature assumption.
- Any place that needs a remote host list for local testing must come from **user config / `~/.ssh/config`**, not a
  compiled-in constant. If a test fixture is required, put it in a **separate, clearly-labelled test-only file**
  (e.g. `dev/test-remote.md` or an env var like `HERDR_SESSION_TEST_REMOTE`) that is trivially deletable.
- **Acceptance requirement:** grep for the test remote must be removable in one action. Track as a deliverable:
  "test-remote is isolated behind one env var / one config file; deleting it leaves remote support intact and generic."
- The remote feature itself is permanent and must be **generic** (any SSH target). Only the *fixture* is temporary.

## Verified environment facts (checked by main session, 2026-10-18)

| Fact | Value |
|---|---|
| Passwordless `ssh localhost` | **Works** (`BatchMode=yes` succeeds, no prompt) |
| Host | `gmktec`, `x86_64` (Linux) |
| `herdr` on "remote" (= same box) | `/home/alexfneves/.nix-profile/bin/herdr`, **version 0.8.2** |
| `herdr` locally | installed, `/home/alexfneves/.nix-profile/bin/herdr` 0.8.2 |
| `odin` compiler in PATH | **NOT installed** — must come from nix (see scout-nix-packaging.md) |
| Repo state | greenfield: nix flake skeleton with `hello` only + untracked `docs/requirements.md` |
| Working dir | `/home/alexfneves/gits/herdr_session` |

Note: because local and "remote" are the same machine, local-vs-remote list/attach code paths can be tested
against the same herdr install — but be careful that a bug which ignores the host field can still pass tests
locally. Plan at least one check that distinguishes host identity in the session table.

## Existing files of reference

- Requirements: `docs/requirements.md` (was `docs/main.md`; a temporary symlink of the old name exists — delete later)
- Nix flake: `flake.nix` (devenv skeleton), `.envrc` (nix-direnv 3.1.0)
- Odin+Clay experiment: `/home/alexfneves/gits/tui_experiment/{main.odin,clay-odin/clay.odin}`
  (user warned: "not enough content and possibly a wrong structure")
- Replacement target: `/home/alexfneves/.config/home-manager/herdr/herdr-cycle.sh` (+ `test-herdr-cycle.sh`)
- Home-manager wiring: `modules/packages.nix`, `modules/activation.nix`, `modules/editors/alacritty.nix`, `modules/spotatui.nix`
