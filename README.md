# herdr-usage-popup

Model usage percentages as plain bars in a Herdr popup panel.

A Herdr plugin that opens a popup showing the quota windows
[oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`) already tracks for every
authenticated provider account. Bars only: no theme colors, no brand styling,
no writes to your Herdr config.

```
Model usage · 09:41

OpenAI Codex · plus · you@example.com
  5h             ████████████████████████   96%  resets 49m
  7d             ████████████████░░░░░░░░   67%  resets 3d19h
  7d/gpt-reserve ░░░░░░░░░░░░░░░░░░░░░░░░    0%  resets 6d23h

OpenCode Go · OpenCode Go
  5h             ████░░░░░░░░░░░░░░░░░░░░   17%  resets 46m
  7d             ████████████░░░░░░░░░░░░   52%  resets 2d12h
  mo             ████████░░░░░░░░░░░░░░░░   36%  resets 17d22h

r refresh · q close
```

## Requirements

- Herdr 0.7.4 or newer (popup plugin panes). Tested on Herdr 0.9.0.
- Linux or macOS, with `bash`.
- [`omp`](https://github.com/can1357/oh-my-pi) on the Herdr server's `PATH`,
  with at least one authenticated provider.
- `jq` on the Herdr server's `PATH`.

## Install

```sh
herdr plugin install Kamyil/herdr-usage-popup
```

Bind a key (optional but recommended) in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = ["prefix+u", "ctrl+u"]
type = "plugin_action"
command = "herdr-usage-popup.open"
description = "open model usage"
```

Apply it:

```sh
herdr server reload-config
```

Without a keybinding, open the popup from the CLI:

```sh
herdr plugin action invoke open --plugin herdr-usage-popup
```

## Controls

| Key | Action |
| --- | --- |
| `r` | Refresh now |
| `q`, `Esc`, `Enter`, `Ctrl-C` | Close |

The panel also re-fetches automatically every 60 seconds while it is open.

## Configuration

Environment variables are read from the Herdr server's environment, because
plugin commands run there:

| Variable | Default | Effect |
| --- | --- | --- |
| `HERDR_USAGE_OMP_BIN` | `omp` | Path to the `omp` binary. |
| `HERDR_USAGE_REFRESH_SECONDS` | `60` | Auto-refresh interval. |
| `HERDR_USAGE_BAR_WIDTH` | `24` | Bar width in cells. |

## How it works

Each render shells out to `omp usage --json` and keeps OMP's own window labels
and percentages. OMP's five-minute usage cache stays authoritative; this plugin
adds no cache of its own. The plugin never opens OMP's credential database and
never generates a model request — it only reads CLI output.

Provider display names and window tokens (`5h`, `7d`, `mo`, plus a
`windowId/modelId` disambiguator when a provider exposes a scoped meter) are
derived from that JSON. Unknown providers still render, using their raw provider
id.

## License

MIT — see [LICENSE](LICENSE).
