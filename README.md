# Appwrite Updater Script

Migration-aware upgrades for self-hosted Appwrite.

## Overview

- Plans upgrades boundary by boundary instead of guessing across multiple Appwrite minors.
- Runs `upgrade`, readiness checks, and `migrate --version=...` in sequence for each planned step.
- Supports dry-run planning, explicit targets, and Appwrite directories in other locations.
- Stops on migration error markers instead of reporting a false success, and retries that migration on the next run.
- Applies the temporary `1.6.x` runtime patch automatically when that migration step is part of the plan.
- Runs Appwrite's `upgrade` headlessly, so it never waits on a prompt or the web installer.

## Requirements

- Docker / Docker Desktop
- `curl`
- `jq`
- An Appwrite directory named `appwrite` containing `docker-compose.yml`, because Appwrite's `upgrade` always uses the
  compose project name `appwrite`. Do not just rename a live folder: compose would point it at new, empty volumes.

## Get the Script

Run this from the parent directory that contains your `appwrite/` folder:

```bash
curl -o appwrite-updater.sh https://raw.githubusercontent.com/ItzNotABug/AppwriteUpdaterScript/master/appwrite-updater.sh && chmod +x appwrite-updater.sh
```

## Usage

```bash
./appwrite-updater.sh [options]
```

Options:

- `-v, --version <ver>`: target Appwrite version
- `-d, --appwrite-dir <dir>`: path to the Appwrite installation, in a folder named `appwrite`
- `--dry-run`: preview the plan without applying changes
- `-y, --yes`: skip the confirmation prompt
- `--no-cleanup`: keep previous Appwrite images
- `--no-restart`: skip the final `docker compose restart`
- `--verbose`: stream Docker/Appwrite output to the terminal
- `-h, --help`: show help

## Examples

```bash
# Preview the upgrade path
./appwrite-updater.sh --dry-run

# Preview a specific target
./appwrite-updater.sh --dry-run --version 2.7.1

# Use a non-default Appwrite directory
./appwrite-updater.sh --appwrite-dir /path/to/appwrite

# Run without confirmation and keep old images
./appwrite-updater.sh --yes --no-cleanup
```

## How It Works

1. Detects the current Appwrite image tag from `docker compose config --images`, with a compose-file fallback.
2. Loads the required stops from `boundaries` and the newest supported release from `latest` in `versions.json`.
3. Uses `versions.json` to build dry-run previews, or fetches stable Appwrite releases from GitHub for live target
   selection when `--version` is omitted.
4. Builds a sequential upgrade plan across known boundaries only.
5. For each step it:
    - runs Appwrite `upgrade --interactive=N`, adding `--http-port` and `--https-port` on `1.9.0` and later
    - waits for the Appwrite container to become ready
    - verifies the running Appwrite version
    - runs `migrate --version=<step-version>` when the step changes minor version, reaches a migration boundary, or
      targets `1.9.0` or later
6. Optionally restarts services and removes old Appwrite images after the full run completes.

## 1.9.x and 2.x

Appwrite's upgrade path changes around these releases, following
the [official upgrade guide](https://appwrite.io/docs/advanced/self-hosting/production/updates):

- `1.9.6` added a new migration class in a patch release, and each class only runs its own changes. From `1.8.x` or
  earlier the path to `2.7.1` is `1.9.5`, then `1.9.10`, then `2.7.1`.
- From `1.9.6` onward releases share one migration class that keeps growing, so `2.x` versions can be skipped. The
  class name does not mean there are no schema changes, so every step from `1.9.0` onward runs `migrate`.
- Targets `2.0.x` and `2.1.x` are refused when upgrading from `1.x`. An upgrade from `1.x` could fail to start
  containers on MariaDB until `2.2.0`.
- From `2.2.0`, executions stored only in the project database are no longer listed, and the migration does not copy
  them. `2.x` also adds ClickHouse services to the stack.
- Nightly and pre-release image tags are refused, because they cannot be placed on the upgrade path.
- Before `2.5.0`, Appwrite's `upgrade` only accepts ports of up to 4 characters. A plan that crosses those versions
  with a longer port is refused before anything changes, so move to shorter ports first.

Read the [release notes](https://github.com/appwrite/appwrite/releases) for every version you cross. Some releases
tighten defaults or ask you to check settings before upgrading.

From `1.9.6` or later, a single Appwrite command can also do the upgrade and migration: use the web installer, or
pass `--migrate` to `upgrade`. This script remains useful for older instances, dry runs, and migration output checks.

## 1.6.x Runtime Patch

If the plan crosses Appwrite `1.6.x`, the updater temporarily patches Appwrite’s migration runtime before running that
migration step and restores the original file after a successful migration.

Details:

- `RUNTIME-PATCH.md`

## Notes

- This script is independently maintained and not an official Appwrite product.
- `versions.json` is part of the execution model. Keep `boundaries` aligned with the stops Appwrite requires, and move
  `latest` forward as releases are verified. Leave `versions` frozen: older copies of this script read it and cannot
  run newer upgrades.
- Always take a backup before running upgrades on a real instance.
- A migration step that fails or is interrupted leaves a file in `~/.appwrite-updater/`. The next run restarts Appwrite
  to stop any migration still running, then repeats that step first, because each migration only runs its own changes.
  Run the updater as the same user each time, because the file is per user. Delete it only if you finish the step by
  hand, or if a step keeps stopping on an error marker and you have checked the data is fine.
- With no `--version`, no `--yes` and no terminal, a plan that crosses into `2.x` is refused.

## Docker Compatibility

Older Docker Engine / API versions can break newer Appwrite updates.

This usually shows up through Traefik or Appwrite runtime orchestration (`openruntimes` / `executor`) hitting Docker
API compatibility limits.

For newer Appwrite versions, keep the host Docker version current. This script does not manage Docker upgrades, and
these failures do not imply data loss.
