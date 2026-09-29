# TIM-30 — dotfiles installer rework: get the entrypoint out of `$HOME` root and fix the backup path

Surface: fast install (`PietjePuh/dotfiles`). Rank: 1 for this surface — highest
blast radius on the board. A wrong merge here breaks a fresh box, and this repo
has **no CI**, so nothing is proven by a green check. The diff gets read by hand.

Repo: `PietjePuh/dotfiles`. **Starting branch: `cowork/beautiful-keller-2y092i`**
(the branch behind draft PR #2). Work on a new branch off that one and open ONE
new pull request against `main`. It supersedes PR #2.

Your branch is based on the PR #2 branch, so your PR must be **based on `main`**, not
on `cowork/beautiful-keller-2y092i` — it carries PR #2's work plus the fixes and
replaces it outright. If the PR is opened against the starting branch instead,
retarget it to `main` and say so; if you cannot retarget it, say that plainly in the
PR description so a human can.

**Do not push to `main`. Do not merge anything. Do not close PR #2** — say in your
PR description that it supersedes #2 and leave it to the repo owner.

**You must NOT ask any questions.** Every decision is made below. If something
still looks ambiguous, pick the option below and note it in the PR description.

---

## Context you need before reading the defects

`PietjePuh/dotfiles` is a **bare repo checked out over `$HOME`**:

    git --git-dir=$HOME/.dotfiles --work-tree=$HOME <cmd>

So **a repo-root path *is* a `$HOME` path**. `README.md` at the repo root becomes
`~/README.md` on every machine that checks this repo out. Every tracked root entry
today is dot-prefixed, and that is deliberate:

    .bashrc  .claude  .config  .dotfiles.md  .local

The repo also sets `status.showUntrackedFiles=no`, so anything this repo drops in
`$HOME` never shows up as drift. Pollution here is silent and permanent.

PR #2 adds `install.sh` and `README.md` at the repo root. Both break that rule.

---

## Defect 1 — root-level non-dot files land in `$HOME`

`install.sh` and `README.md` at the root mean every future checkout drops
`~/install.sh` and `~/README.md` into the home directory.

## Defect 2 — the backup path cannot see those files, and then dies

`install.sh` step 3 (`step_dotfiles`) parses git's collision list out of the error
text:

```bash
dot checkout 2>&1 | grep -E '^\s+\.' | awk '{print $1}' | while read -r f; do
```

`grep -E '^\s+\.'` requires the first non-whitespace character to be a literal `.`.
`.bashrc` and `.config/foo` match. `README.md` and `install.sh` **do not** — they
are silently dropped, never moved to the backup dir, the retry `dot checkout` fails
identically, and the script hits `die "checkout still failing after backup"`.

**This fires on the documented happy path.** The header comments say `./install.sh`,
implying the script was curled into the current directory. If that directory is
`$HOME` — the obvious choice — then `~/install.sh` already exists when step 3 runs,
and the installer bricks partway through with the dotfiles half-applied. That is the
worst possible failure mode for this script: it dies *after* it has started writing
to `$HOME`.

---

## The brief

### 1. Move the entrypoint to `.local/bin/omarchy-install`

`git mv install.sh .local/bin/omarchy-install` (no `.sh` suffix). It maps to
`~/.local/bin/omarchy-install`, which is already on `PATH` and already holds
`omarchy-bootstrap`, so the installer ends up next to the thing it hands off to.
Repo root stays dot-only.

**The file mode must be `100755`.** After checkout, `~/.local/bin/omarchy-install`
has to be directly executable. Verify with:

    git ls-tree HEAD .local/bin/omarchy-install

and confirm the mode column reads `100755`. If it does not, `git update-index
--chmod=+x .local/bin/omarchy-install` and commit that.

Update every reference to the old path — the header comment block inside the script
itself, the `.dotfiles.md` restore section, and the docs file from item 3. The curl
one-liner becomes:

    bash <(curl -fsSL https://raw.githubusercontent.com/PietjePuh/dotfiles/main/.local/bin/omarchy-install)

That URL still resolves — `raw.githubusercontent.com` serves any path in the tree.

### 2. Replace the error-text parse with a deterministic enumeration

In `step_dotfiles`, replace the `grep`/`awk` pipeline with this:

```bash
local moved=0
dot ls-tree -r --name-only HEAD | while read -r f; do
    [[ -e "$HOME/$f" ]] || continue
    mkdir -p "$bak/$(dirname "$f")"
    mv "$HOME/$f" "$bak/$f"
    printf '    backed up %s\n' "$f"
done
```

Exact requirements, none of them negotiable:

- **Keep it inside the failure branch.** It must stay in the `else` of the first
  `dot checkout` attempt. Running this unconditionally would move every tracked file
  out of a working `$HOME` on a re-run, which turns an idempotent script into a
  destructive one.
- **Do not add a content-equality skip.** Do not try to be clever and skip files
  whose contents already match `HEAD`. `git checkout` refuses to overwrite an
  untracked file at a target path, and reasoning about whether it makes an exception
  for identical content is exactly the kind of guess that produces a half-applied
  `$HOME`. Move every tracked path that exists. It is a move, not a delete —
  everything is recoverable from `$bak`.
- **Never use `checkout -f`, anywhere, for any reason.** Not as a fallback, not in a
  comment, not in the docs. Forcing the checkout is precisely the clobbering
  behaviour this design exists to avoid.
- Because the `while` body runs in a subshell, `moved` will not survive the pipe.
  If you want the count for the final message, restructure with a process
  substitution (`while read -r f; do … done < <(dot ls-tree -r --name-only HEAD)`)
  rather than exporting state out of a pipeline.
- Improve the failure message: if the retry `dot checkout` still fails, `die` with
  how many paths were backed up and where, e.g.
  `"checkout still failing after backing up N path(s) to $bak — inspect it"`.
  A zero there tells the reader immediately that collisions were not the problem.

### 3. `README.md` — the decision is made, do not re-open it

**Move it to `.github/README.md`.** Not the repo root, and do not delete it.

Reasoning, which you should restate briefly in the PR description: GitHub renders a
repo landing page from `README.md` at the root, in `docs/`, **or in `.github/`**.
`.github/` is dot-prefixed, so it maps to `~/.github/README.md` — a hidden directory
in `$HOME` that no `ls` shows and nothing trips over — while GitHub still renders it
as the repo's landing page. Root stays dot-only and the repo keeps a rendered front
page. Both constraints are satisfied; neither has to be traded away.

Keep `.dotfiles.md` as the documentation of record and keep updating its restore
section as PR #2 already does. `.github/README.md` is the landing page; it should
point at `.dotfiles.md` for detail rather than duplicating it wholesale.

### 4. `add_pkg github-cli || add_pkg gh`

Drop the fallback. `gh` is not an Arch package name — `github-cli` is the package
that provides the `gh` binary. The `|| add_pkg gh` branch can only ever produce a
second, more confusing failure message. Make it plain `add_pkg github-cli`.

### 5. Make the script sourceable so item 6 can test it

Right now the four `step_*` calls run at the top level, so the file cannot be loaded
without running the whole installer. Wrap them:

```bash
main() {
    banner "Omarchy fast setup"
    step_prereqs
    step_gh_auth
    step_dotfiles
    # Forward any args (e.g. `omarchy-install all`) straight to the bootstrap.
    # exec replaces this process, so it must run last.
    step_bootstrap "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Behaviour when executed directly must be identical to today. Do not change
`set -uo pipefail`, the colour helpers, the `dot()` wrapper, `DOTFILES_REPO`
overridability, or the `exec "$BOOTSTRAP" "$@"` handoff.

### 6. Verification — this is the bar, and you must paste the transcript

You have to show the installer **surviving the exact case that currently kills it**:
a pre-existing colliding file sitting at the path the entrypoint now ships to,
backed up instead of fatal, with the checkout completing.

Write this harness to `/tmp/collision-test.sh` in your VM. **Do not commit it** —
this repo's root must stay dot-only and there is no CI to run it, so a committed
test file would just be one more tracked path in everyone's `$HOME`.

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
export HOME="$tmp/home"
export DOTFILES_REPO="$REPO_ROOT"
mkdir -p "$HOME/.local/bin"

# The collision that currently bricks the installer: the entrypoint's own path.
printf 'stock content, must survive\n' > "$HOME/.local/bin/omarchy-install"
printf 'stock bashrc, must survive\n'  > "$HOME/.bashrc"

# Load the installer without running it.
source "$REPO_ROOT/.local/bin/omarchy-install"

echo "=== first run ==="
step_dotfiles

echo "=== assertions ==="
bak="$(find "$HOME/.config-backup" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$bak" ]] || { echo "FAIL: no backup dir"; exit 1; }
grep -q 'stock content, must survive' "$bak/.local/bin/omarchy-install" \
  || { echo "FAIL: entrypoint collision not backed up"; exit 1; }
grep -q 'stock bashrc, must survive' "$bak/.bashrc" \
  || { echo "FAIL: .bashrc collision not backed up"; exit 1; }
diff -q "$HOME/.local/bin/omarchy-install" "$REPO_ROOT/.local/bin/omarchy-install" \
  || { echo "FAIL: repo version not checked out"; exit 1; }
[[ -x "$HOME/.local/bin/omarchy-install" ]] \
  || { echo "FAIL: checked-out entrypoint is not executable"; exit 1; }
echo "OK: collision backed up, checkout completed, mode preserved"

echo "=== second run (idempotency) ==="
before="$(find "$HOME/.config-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)"
step_dotfiles
after="$(find "$HOME/.config-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)"
[[ "$before" == "$after" ]] \
  || { echo "FAIL: re-run created a second backup dir ($before -> $after)"; exit 1; }
echo "OK: re-run is a no-op, no new backup dir"
```

Run it and **paste the complete transcript into the PR description**, including the
`=== assertions ===` output. A summary is not acceptable; paste what the terminal
printed.

Also run and paste:

    bash -n .local/bin/omarchy-install
    git ls-tree HEAD .local/bin/omarchy-install
    git ls-tree --name-only HEAD

The last one is the proof of item 1: every entry it prints must start with a `.`.
If shellcheck is available in your VM, run `shellcheck .local/bin/omarchy-install`
and paste that too; if it is not, say so rather than pretending.

If an assertion fails, **fix the script until it passes** — do not relax the
assertion, and do not open the PR with a red harness and a note about it.

### Hard constraints

- No `git checkout -f` against the dotfiles work tree. Anywhere. Ever.
- Never push to `main`. Never merge. Never mark a PR ready for review — leave it a
  draft.
- Every tracked entry at the repo root must stay dot-prefixed. Run
  `git ls-tree --name-only HEAD` before you open the PR and check.
- Keep the design PR #2 got right: no forced checkout, collisions backed up rather
  than clobbered, every step detects work already done and skips it.
- Keep the diff to `.local/bin/omarchy-install`, `.github/README.md`, `.dotfiles.md`
  and the deletion of the two root files. Do not refactor `omarchy-bootstrap`, do not
  touch `packages.conf`, do not reformat unrelated code.

### PR

PR TITLE: `fix(install): move entrypoint to .local/bin/omarchy-install and fix the collision backup path`

The PR description must contain, in this order:

1. Why the root files were a problem (bare repo over `$HOME`, one sentence).
2. Why the old `grep -E '^\s+\.'` parse died on the documented happy path.
3. The `README.md` → `.github/README.md` decision and the one-line reason.
4. The full pasted transcript from item 6.
5. A line saying this supersedes PR #2, which the repo owner should close.
