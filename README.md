# herdr-usage-popup

Model usage percentages as plain bars in a Herdr popup panel.

A Herdr plugin that opens a popup showing the quota windows your agent CLIs
already track, provider by provider. Bars only: no theme colors, no brand
styling, no writes to your Herdr config, no credential handling.

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
- `jq` on the Herdr server's `PATH`.
- The CLI for each provider you want to see. A provider is skipped when its CLI
  is not installed.

## Providers

| Provider | Source | Credential owner |
| --- | --- | --- |
| OpenAI Codex | `codex app-server` → `account/read`, `account/rateLimits/read` | Codex CLI |
| OpenCode Go | `omp usage --json --provider opencode-go` | oh-my-pi |

Codex is queried over its own app-server JSON-RPC surface, so the plugin never
reads `~/.codex/auth.json` and never refreshes a token — the Codex CLI stays the
only thing that touches its credentials. OpenCode Go's key exists only inside
oh-my-pi (the `opencode` CLI reports zero credentials), so `omp` is the only
supported way to read it.

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
| `HERDR_USAGE_CODEX_BIN` | `codex` | Path to the Codex CLI. |
| `HERDR_USAGE_OMP_BIN` | `omp` | Path to `omp`, used for OpenCode Go. |
| `HERDR_USAGE_REFRESH_SECONDS` | `60` | Auto-refresh interval. |
| `HERDR_USAGE_BAR_WIDTH` | `24` | Bar width in cells. |

## How it works

Each provider has a collector that asks that provider's own tooling for its
limits, so the numbers come from the vendor APIs by way of the CLI that owns the
credentials:

- **Codex** — the plugin starts `codex -s read-only -a untrusted app-server`,
  sends `initialize`, `account/read`, and `account/rateLimits/read` over stdio,
  then shuts the server down. Nothing is written and no model request is made.
- **OpenCode Go** — the plugin runs `omp usage --json --provider opencode-go`
  and reuses OMP's own usage cache.

Percentages are used-percent, exactly as each API reports them; no rescaling is
applied. Window tokens come from the reported window length (`300` minutes →
`5h`, `10080` → `7d`) plus a qualifier when a provider exposes a scoped meter
(`7d/gpt-reserve`). A failed fetch renders as a status line under that provider
instead of a zero, so a broken token can never look like an empty quota.

The plugin never reads or writes a credential file or database, and never
refreshes a token.

## License

MIT — see [LICENSE](LICENSE).
