# `fountain::f_probe`

The extension contract module for fprobe: it defines probe agents (`ProbeAgent`), alarm
message channels (`AlarmMessageChannel`), thread-safe registries and stable error codes.
A third-party extension depends only on this module to build a dynamic library, without
pulling in RPC, mail or TUI dependencies.

- Contract reference: [`doc/contract.md`](doc/contract.md)
- Extension guide: [`doc/extension-guide.md`](doc/extension-guide.md)

> This module is still being implemented; the public declarations under `src/` are the
> source of truth for the API.
