# ezcache

Adds the [kalken.cachix.org](https://kalken.cachix.org) binary cache, so machines download eznixpkgs packages that are built on GitHub, such as [ezsocks-rs](ezsocks-rs.md), instead of compiling them. On by default for every machine that imports eznixpkgs; cache.nixos.org stays in use as well.

Packages land in the cache when their repo's "Build cache" workflow is run by hand on GitHub.

## ⚙️ Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `eznixpkgs.cache.enable` | bool | `true` | Use the kalken.cachix.org binary cache |

## 📝 Notes

- A machine starts using the cache after the first rebuild that adds it; that rebuild still compiles what it needs.
- Only builds that match exactly are downloaded. ezsocks-rs is built with its own pinned nixpkgs, so its build is the same on every machine.
