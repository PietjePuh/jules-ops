Repo: PietjePuh/omarchy-toolbelt. Base branch: main. Work on a new branch `bus/v1-drop-mirror-news-listeners` and open ONE pull request. Do NOT push to main.

PREREQUISITE: Toolbelt slice 5 (`bus/v1-mirror-news-consumers`) must be MERGED. That PR is what moves the extension off `:3877` and `:8096`. Removing the listeners before it merges breaks the bar's Config tab and the news feed. If it is not merged, stop and say so.

You must NOT ask any questions.

GOAL: the subtraction. `:3877` (`bin/toolbelt_mirror.py`) and `:8096` (`bin/news.py`'s serve mode) stop binding their own ports. Both stay reachable as bus acts (shipped in `bus/v1-mirror-news-actions`). Target for the port map: 6 loopback ports → 3 externally (`:3847` gateway, `:8766` MCP, `:4100` CLI bridge), 1 internally.

## The changes

1. Remove the HTTP listener from `bin/toolbelt_mirror.py`. The snapshot generation stays — it is what the `svc.mirror.snapshot` act calls. Delete the server, the port constant, and any systemd unit / npm script / documentation that starts it as a service. Grep the whole repo for `3877` and resolve every hit.

2. Remove the serve mode from `bin/news.py` (`news.serve`, `news.serve.stop`, the `8096` defaults at `bin/news.py:1501-1563`) and every reference to the port. The feed logic stays — it is what the news acts call. Grep for `8096` and resolve every hit.

3. Update `docs/` with the resulting port map: every loopback port this host still binds, what listens on it, and which two are gone. Name the bus act that replaced each removed port so the mapping is traceable.

4. If either port is referenced by a systemd unit, an install script, `omarchy-bootstrap`, or a README, update it in the same PR. A removed listener with a live unit file still trying to start it is a half-finished subtraction.

## Do not

- Do not remove the snapshot or feed LOGIC — only the listeners.
- Do not change any act name.
- Do not change `:3847`, `:8766` or `:4100`.
- Do not leave a commented-out listener behind. Delete it; git history is the archive.

## Verification — paste the output in the PR body

1. `grep -rn '3877\|8096' .` over the repo returns only documentation describing the removal (show the output).
2. `python3 bin/toolbelt_agent.py act svc.mirror.snapshot` and each news act still return live data with the listeners gone.
3. `ss -ltnp | grep -E '3877|8096'` is empty after a restart of whatever previously started them (show the output).
4. Full suite: `python3 test/run_all.py` — paste the summary.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this and your PR will be red. Do **not** add a `// ratchet-ok:` comment to get around the gate. This PR is a subtraction PR — it is the shape the freeze exists to produce.
