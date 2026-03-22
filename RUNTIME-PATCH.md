# 1.6.x Runtime Patch

This file explains the temporary runtime patch used by `appwrite-updater.sh` when an upgrade crosses Appwrite `1.6.x`.

## Why This File Exists

Appwrite `1.6.x` can fail during migration on projects that contain function and deployment data.

The failure we reproduced included:

- `Cannot execute queries while other unbuffered queries are active`
- `SQLSTATE[HY000]: General error: 2014`

## Where The Issue Is

Target Appwrite file:

`src/Appwrite/Migration/Migration.php`

Relevant code:

- Coroutine-based document
  updates: https://github.com/appwrite/appwrite/blob/1.6.2/src/Appwrite/Migration/Migration.php#L180-L199
- Iterator used by that migration
  path: https://github.com/appwrite/appwrite/blob/1.6.2/src/Appwrite/Migration/Migration.php#L211-L244

## How This Repo Patches It

For Appwrite `1.6.x`, the updater temporarily patches `src/Appwrite/Migration/Migration.php` inside the running Appwrite
container before migration.

It replaces the coroutine-based document update block with a synchronous loop for that migration step.

In plain terms:

- Old path: `go(function (...) { ... updateDocument(...) ... })`
- Patched path: update documents inline in the loop

The patch is temporary and only applies to the `1.6.x` migration step.
