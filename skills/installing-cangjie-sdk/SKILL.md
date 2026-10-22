---
name: installing-cangjie-sdk
description: Use when the user asks to install or update the Cangjie (仓颉) toolchain on WSL Ubuntu — nightly sdk/stdx/docs from gitcode.com/Cangjie/nightly_build, an official SDK version from cangjie-lang.cn, to update the version numbers in cangjie.sh, to query the latest nightly/STS/LTS versions, or to change the Cangjie install root directory. Triggers: 仓颉 nightly 更新、安装仓颉 SDK、更新 stdx、更新 cangjie-doc、改 cangjie.sh 版本号、cj env、nightly_build releases、cangjie-lang.cn 下载、查询最新版本、仓颉 LTS、仓颉 STS、最新 nightly 完整版本、配置/更换仓颉安装目录.
---

# Installing Cangjie SDK (WSL Ubuntu)

## Overview

Installs Cangjie toolchain assets into a **fixed layout** on the D: drive via WSL Ubuntu 24.04, using one bundled script (`scripts/install.sh`) with three subcommands: `nightly`, `official <version>`, `setenv <sdk_ver> <stdx_ver>`. Run the script inside WSL — do not reimplement its logic Windows-side.

## Install root — config.env (first use)

The install root is persisted in `config.env` next to SKILL.md as `CANGJIE_ROOT=<absolute POSIX path visible from WSL>`; every destination below hangs off it (`$CANGJIE_ROOT/cangjie-linux-bin/...`, `$CANGJIE_ROOT/cangjie-doc/...`, `$CANGJIE_ROOT/cangjie.sh`).

- **If `config.env` exists: use it silently. Do NOT ask.**
- **If it is missing (first use in a new environment): ask the user** for the install root (e.g. `/mnt/d/docs/work/cangjie`), then run `install.sh set-root <path>` ONCE — the script validates the path and persists it; all later runs skip asking.
- This environment is already seeded with `CANGJIE_ROOT=/mnt/d/docs/work/cangjie` — never ask here.
- `set-root` may be re-run to relocate a broken/new root; it does not migrate existing installs.

| Asset | Destination | Extracted shape |
|---|---|---|
| sdk | `$CANGJIE_ROOT/cangjie-linux-bin/sdk/<ver>/` | `cangjie/` subdir |
| stdx | `$CANGJIE_ROOT/cangjie-linux-bin/stdx/<ver>/` | `linux_x86_64_cjnative/` (or arch variant) |
| docs | `$CANGJIE_ROOT/cangjie-doc/<ver>/` | html at top level |
| stdx-docs | `$CANGJIE_ROOT/cangjie-doc/stdx/<ver>/` | html at top level |

Archives are **deleted right after successful extraction** — only the extracted content remains. A `.installed-<archive>` marker records the installed release for idempotency; stale `cangjie-*` archives left by earlier installs are removed too.

`<ver>` = first `[0-9]+(\.[0-9]+)+` match of the asset filename's version: `cangjie-sdk-linux-x64-1.3.0-alpha.20261015001050.tar.gz` → `1.3.0`; `cangjie-stdx-linux-x64-1.0.4.1.zip` → `1.0.4.1`; `cangjie-sdk-linux-x64-1.2.0.tar.gz` → `1.2.0`. Works for future `1.4.0`/`1.5.0`/`2.0.0` without changes.

## THE GATE — never auto-run setenv

`setenv` (task 3) rewrites the last line of `cangjie.sh`. After running `nightly` or `official` (tasks 1/2), **STOP and ask the user** whether to run `setenv`.

- Auto-run is allowed ONLY when the user's original request already says so (e.g. "装完顺便把 cangjie.sh 也更新了" / "自动执行任务3").
- "They'll obviously want it", "saves a round trip", "the release notes recommend it" — none of these are authorization. ASK.
- `setenv` needs TWO numbers: `cj env <sdk_ver> <stdx_ver>`. If only one was installed this run, ask the user for the other (suggest keeping the currently installed version). `setenv` refuses to edit if the last non-empty line isn't `cj env ...` — report the refusal, don't edit by hand.

## WSL invocation

1. Find the distro: `wsl.exe -l -v | tr -d '\0'` (output is UTF-16LE; the `tr` is required). Use `Ubuntu-24.04` — the user's standard. If absent, ask the user for the distro name.
2. Run the bundled script inside WSL (Windows path `C:\...` → `/mnt/c/...`). **Always pass the command via `bash -c`** — a bare POSIX path argument to `wsl.exe` gets MSYS-mangled by Git Bash (prefixed with the Git root, e.g. `D:/.../PortableGit/mnt/c/...` — verified pitfall):
   `wsl.exe -d Ubuntu-24.04 -- bash -c "bash /mnt/c/Users/74414/.workbuddy/skills/installing-cangjie-sdk/scripts/install.sh nightly"`
3. If the sandbox reports `PROGRAM BLOCKED BY SECURITY POLICY ... wsl.exe`, rerun that command with the sandbox disabled; if still blocked, tell the user to remove `wsl.exe` from Security Center → Command Security → Program Blacklist.
4. Large downloads (500MB+) may exceed the foreground command timeout — run in the background and report progress.
5. If bash complains `` $'\r': command not found ``: the script got CRLF endings — strip once with `sed -i 's/\r$//'` on the WSL path, then rerun.
6. Set `CJ_DRY_RUN=1` to preview release picking / URL resolution / target dirs without downloading or editing anything (useful for a quick sanity check or when the network is constrained).

## Task 1 — nightly (sdk + stdx + docs + stdx-docs)

Run: `install.sh nightly`

- Arch auto-detected via `uname -m` (`x86_64`→`x64`, `aarch64`→`aarch64`).
- Queries `https://gitcode.com/api/v5/repos/Cangjie/nightly_build/releases?per_page=30&direction=desc`. **`direction=desc` is mandatory** — the default order returns an old window of releases (verified pitfall 2026-10-15: "latest" resolved to a month-old build).
- Picks the newest release containing ALL four assets. Some releases are partial (e.g. `1.3.0-alpha.20260916010055` lacks stdx-linux-x64); the scan falls back to older complete releases automatically.
- sdk asset excludes `-sanitizer` / `-android` / `-ohos` variants.
- Idempotent: a `.installed-<archive>` marker skips re-download of an already-installed release.
- Output ends with `INSTALLED_TAG=`, `SDK_VER=`, `STDX_VER=`, `SUGGESTED_ENV=cj env <sdk_ver> <stdx_ver>` — use these for the report and the setenv ask.

## Task 2 — official SDK (cangjie-lang.cn)

Run: `install.sh official <version>` (e.g. `official 1.2.0`; optional second arg overrides arch).

- Resolves the real download URL automatically: page HTML → extract the `csdnimg.cn/.../chunk/organization/download/version.<hash>.js` chunk URL → grep the `/v1/files/auth/downLoad?nsId=...&fileName=cangjie-sdk-linux-<arch>-<ver>.tar.gz&objectKey=...` path. The `objectKey` is per-file and per-deployment — **never hardcode it**; always re-resolve from the current page/chunk.
- Downloads anonymously (no cookies needed), installs to `sdk/<version>/`.
- Output ends with `SDK_VER=` and a NOTE that stdx_ver must come from the user.

## Query — versions (report only, no install)

Run: `install.sh versions`

- `NIGHTLY=<tag>` — newest release tag matching `\d+(\.\d+)+-alpha.\d{14}` (e.g. `1.3.0-alpha.20261015001050`), from the same `direction=desc` API.
- `STS=<ver>` / `LTS=<ver>` — from cangjie-lang.cn: channel cards on `/download` give the bootstrap link per channel; then the typed version dropdown on the versioned page (`/download/<sts>`) is authoritative (first `STS` / first `LTS` entry, newest first); a disagreement with the channel cards logs a WARN and the selector wins.
- When the user asks for "最新 STS/LTS" installs, chain: `versions` → `official <STS 或 LTS 的值>`. This subcommand installs nothing and is NOT gated by THE GATE.

## Task 3 — setenv (gated, see THE GATE)

Run: `install.sh setenv <sdk_ver> <stdx_ver>`

- Backs up to `/tmp/cangjie.sh.bak.<timestamp>` first; prints before → after.
- Afterward, suggest the user `source $CANGJIE_ROOT/cangjie.sh` then `cjc -v` (i.e. `source /mnt/d/docs/work/cangjie/cangjie.sh` in this environment).

## Verify after install

`ls` the destination dirs: `sdk/<ver>/cangjie/`, `stdx/<ver>/linux_x86_64_cjnative/` (x64) or `linux_aarch64_cjnative/`, `cangjie-doc/<ver>/` contains top-level html, `cangjie-doc/stdx/<ver>/` likewise. Report what was installed + `SUGGESTED_ENV`, then (per THE GATE) ask about setenv.

## Common mistakes

| Mistake | Consequence |
|---|---|
| API without `direction=desc` | Installs a ~1-month-old nightly |
| Scraping the gitcode releases page HTML | Empty SPA shell, no assets — use the `/api/v5/...` JSON API |
| Guessing cangjie-lang.cn direct URLs | `objectKey` unpredictable — resolve from the JS chunk each time |
| Trusting the newest release blindly | Partial releases exist (missing stdx-linux-x64); script scans for a complete one |
| `python3 -m zipfile -e` for stdx | Loses executable bits — script restores permissions from zip metadata |
| Hardcoding arch | Wrong build on aarch64 hosts — script uses `uname -m` |
| Hardcoding `/mnt/d/...` install paths | Roots come from `config.env` (`CANGJIE_ROOT`) — never inline them; ask + `set-root` when unconfigured |
| Editing cangjie.sh when its last line isn't `cj env` | Broken env bootstrap — script refuses; report instead |
| Expecting archives in version dirs | Deleted after install by design; only extracted content + `.installed-*` markers remain |
