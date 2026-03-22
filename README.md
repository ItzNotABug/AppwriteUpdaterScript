# Appwrite Updater Script

Migration-aware upgrades for self-hosted Appwrite.

## Overview

- Plans upgrades boundary by boundary instead of guessing across multiple Appwrite minors.
- Runs `upgrade`, readiness checks, and `migrate --version=...` in sequence for each planned step.
- Supports dry-run planning, explicit targets, and non-default Appwrite directories.
- Stops on migration error markers instead of reporting a false success.
- Applies the temporary `1.6.x` runtime patch automatically when that migration step is part of the plan.

## Requirements

- Docker / Docker Desktop
- `curl`
- `jq`
- An Appwrite directory containing `docker-compose.yml`

## Usage

```bash
./appwrite-updater.sh [options]
```

Options:

- `-v, --version <ver>`: target Appwrite version
- `-d, --appwrite-dir <dir>`: path to the Appwrite installation
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
./appwrite-updater.sh --dry-run --version 1.8.1

# Use a non-default Appwrite directory
./appwrite-updater.sh --appwrite-dir /path/to/appwrite

# Run without confirmation and keep old images
./appwrite-updater.sh --yes --no-cleanup
```

## How It Works

1. Detects the current Appwrite image tag from `docker compose config --images`, with a compose-file fallback.
2. Loads migration boundaries from `versions.json`.
3. Uses `versions.json` to build dry-run previews, or fetches stable Appwrite releases from GitHub for live target
   selection when `--version` is omitted.
4. Builds a sequential upgrade plan across known boundaries only.
5. For each step it:
    - runs Appwrite `upgrade`
    - waits for the Appwrite container to become ready
    - verifies the running Appwrite version
    - runs `migrate --version=<step-version>` when the step crosses a migration boundary
6. Optionally restarts services and removes old Appwrite images after the full run completes.

## 1.6.x Runtime Patch

If the plan crosses Appwrite `1.6.x`, the updater temporarily patches Appwrite’s migration runtime before running that
migration step and restores the original file after a successful migration.

Details:

- `RUNTIME-PATCH.md`

## Notes

- This script is independently maintained and not an official Appwrite product.
- `versions.json` is part of the execution model. Keep it aligned with real Appwrite migration boundaries.
- Always take a backup before running upgrades on a real instance.

## Docker Compatibility

Older Docker Engine / API versions can break newer Appwrite updates.

This usually shows up through Traefik or Appwrite runtime orchestration (`openruntimes` / `executor`) hitting Docker
API compatibility limits.

For newer Appwrite versions, keep the host Docker version current. This script does not manage Docker upgrades, and
these failures do not imply data loss.
