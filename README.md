# Statable visitors — an Omarchy bar widget

Visitors on your site in the [Omarchy](https://omarchy.org) bar: a live count as a
pill, and the last seven days when you click it. It polls the
[`statable`](https://github.com/key-arg/statable-cli) CLI, which prints and exits, so
the widget holds no state and runs no daemon.

![the popup panel: site and live count, last 7 days with change against the previous week, and top pages](docs/panel.png)

## Requires

- Omarchy with the Quickshell bar — the one that reads `~/.config/omarchy/shell.json`.
- The [`statable`](https://github.com/key-arg/statable-cli) CLI on the shell's
  `PATH`, signed in to an account:

  ```bash
  # install: pick the archive for your machine from the releases page
  #   https://github.com/key-arg/statable-cli/releases
  # or, on a system with Go:
  go install github.com/key-arg/statable-cli/cmd/statable@latest

  statable auth login          # paste an API key with the read scope
  statable sites use example.com
  ```

## Install

```bash
omarchy plugin add https://github.com/key-arg/omarchy-statable.git
```

It lands disabled, as every third-party plugin does — read `Widget.qml` (it is
short), then enable **Statable visitors** in the bar settings, or add it to a
section of `~/.config/omarchy/shell.json`:

```jsonc
{ "id": "com.statable.now" }
```

## Settings

| Setting | Default | What it does |
|---|---|---|
| `site` | *(blank)* | Domain or id to read. Blank uses whatever `statable sites use` set as the default. |
| `refreshIntervalSec` | `60` | How often to poll. The now-count changes slowly, and each poll is one API request against your hourly budget. |
| `showIcon` | `true` | Show the visitors glyph before the number. |

## Behaviour

The pill shows a number only when `statable now` exits cleanly. Clicking it opens
a panel with the last seven days — visitors, pageviews, bounce rate and average
visit, each against the previous week — and the top pages; those are fetched when
the panel opens and on the same timer while it stays open.

No key, no default site, the API unreachable, or the binary missing from `PATH` —
each leaves that part blank rather than showing a wrong or stale figure. Every
call runs off the bar's UI thread, so a slow one never freezes the bar, and a
poll still running when the next tick arrives is skipped rather than stacked.

Middle-click re-polls immediately. The panel can also be summoned by script:
`omarchy-shell com.statable.now toggle`.

## Licence

MIT. The widget is unsandboxed QML that runs inside `omarchy-shell`, like every
Omarchy plugin: read it before you enable it.
