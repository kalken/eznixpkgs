# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**eznixpkgs** is a NixOS modules and packages collection. It provides reusable NixOS modules and standalone packages for networking, development tooling, and system configuration. Everything is written in the Nix language; there is no traditional build system.

## Common Commands

```bash
# Validate flake inputs and outputs
nix flake check

# Build all packages
nix build .

# Build a specific package
nix build .#ezman

# Apply to a NixOS system (run on target machine)
sudo nixos-rebuild switch --flake .
```

There are no test suites, linters, or CI pipelines in this project.

## Architecture

The repo has two top-level layers:

### `modules/` — NixOS configuration fragments
Each `.nix` file is a self-contained NixOS module (e.g., `services.ezrouter`, `programs.ezsh`). `modules/default.nix` auto-discovers and imports all `.nix` files in the directory via `builtins.readDir`, so adding a new module requires only creating the file — no registration needed.

### `pkgs/` — Standalone packages
Each subdirectory is a package exposed via a Nix overlay. `pkgs/default.nix` auto-discovers subdirectories and calls `callPackage` on each, making them available as `pkgs.ezconf`, `pkgs.ezman`, etc. External projects (eznetns, prettysocks, wg-tools) are fetched from GitHub via `fetchFromGitHub` and wrapped with Nix-managed dependencies.

### `flake.nix`
Minimal entry point — imports `modules/` and `pkgs/`, exports `nixosModules.default` (all modules combined) and the package overlay.

## Key Patterns

**Smart defaults**: `ezrouter` derives VLAN addresses from VLAN IDs (e.g., `id=30` → `192.168.30.1/24`) and uses helper functions (`mkVlanNetdev`, `mkVlanNetwork`) to generate systemd-networkd configs dynamically.

**systemd integration**: `eznetns` uses `systemd.sockets` + `systemd-socket-proxyd` for port forwarding via socket activation. Services can be attached to arbitrary systemd units via the `netnsService` mapping.

**Documentation**: Each module has a companion `.md` file (e.g., `ezrouter.md`, `ezconf.md`) with full option tables and usage examples. Keep these in sync when changing module options.

## Branch Strategy

Always make changes on the `develop` branch, never directly on `master`.

## Commits

Never add `Co-Authored-By` or any Claude/Anthropic attribution to commit messages.

## Adding New Modules or Packages

- **Module**: Create `modules/<name>.nix`. It will be auto-imported.
- **Package**: Create `pkgs/<name>/default.nix`. It will be auto-included in the overlay.
- Add a `<name>.md` documentation file alongside the module or inside the package directory.
