# Immich ⇄ Noodle Gallery for community-scripts LXCs

Switch a Proxmox LXC that was built with the community-scripts
[`install/immich-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/install/immich-install.sh)
over to [Noodle Gallery](https://github.com/open-noodle/gallery), keep it updated,
and switch it back to upstream [Immich](https://github.com/immich-app/immich) if you
change your mind.

Noodle Gallery advertises drop-in replacement for the *Docker* deployment — swap two
image names, and a `revert-to-immich.sql` script to go back. This repo provides the
same thing for the **source build** the community scripts use.

## Why it works

Gallery is a rebase fork, not a rename fork. Diffing `immich-app/immich@v3.1.0`
against `open-noodle/gallery@v5.3.1`:

| | Immich | Gallery |
|---|---|---|
| workspace package names | `immich`, `immich-web`, `@immich/sdk`, `@immich/cli`, `@immich/plugin-sdk`, `@immich/plugin-core` | identical |
| root `package.json` name / version | `immich-monorepo` / `3.1.0` | identical |
| `packageManager` | `pnpm@11.13.1` | identical |
| `server/bin/{immich-admin,start.sh}` | — | byte-identical |
| env var prefix | `IMMICH_*` | identical |
| DB name / user / extensions | `immich` / `immich` / vchord | identical |
| ML extras | `--extra cpu`, `--extra openvino` | identical |

So the whole build pipeline from `immich-install.sh` works unchanged against the
Gallery tarball — only the GitHub repo and tag differ. `lib/build.func` is therefore
a single implementation used by the switch, the rollback and the updater.

**Not touched by a switch in either direction:** your photos in
`/opt/immich/upload`, PostgreSQL + VectorChord, Redis, `.env`, both systemd units,
jellyfin-ffmpeg, and the compiled image libraries (libjxl, libheif, libraw,
ImageMagick, libvips) in `/usr/local/lib`. Only `/opt/immich/app` and
`/opt/immich/source` are rebuilt.

## Setup

The scripts fetch each other over the network at runtime, so they need to know
where they live. `RAW_BASE` at the top of `tools/immich-flavor.sh` and
`ct/gallery.sh` points at this repository:

```bash
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/karigeo/immich-noodle-gallery-switch/main}"
```

Nothing to change if you use this repo as-is. If you fork it, edit that line in
both files. To test a branch without editing anything, override it for the run:

```bash
RAW_BASE=https://raw.githubusercontent.com/karigeo/immich-noodle-gallery-switch/dev
```

The repository must be **public**, or the container cannot fetch from it.

All commands below run **inside the LXC** as root (`pct enter <ctid>`).

## Usage

```bash
# What am I running?
bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- status

# Immich -> Noodle Gallery
bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- to-gallery

# Noodle Gallery -> Immich
bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- to-immich

# Just a database dump, nothing else
bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- backup-db
```

`to-gallery` installs a local copy at `/usr/local/bin/immich-flavor`, so afterwards
plain `immich-flavor to-immich` works even if GitHub is unreachable.

### Options

| | |
|---|---|
| `--version <tag>` | Use a specific release instead of the pinned one. |
| `--force` | (to-gallery) Proceed even when Gallery is not rebased on your Immich version. |
| `--restore-dump <file>` | (to-immich) Restore a pg_dump instead of running the SQL cleanup. |
| `--no-snapshot` | Do not keep a copy of the old `app/` directory. |
| `--yes` | Skip confirmation prompts. |
| `--verbose` | Full build output instead of spinners. |

### Updating Gallery

`to-gallery` repoints `/usr/bin/update` at this repo's `ct/gallery.sh`, so the
familiar command still works:

```bash
update
```

That runs the same maintenance blocks as `ct/immich.sh` (Debian testing repo, mise,
Intel OpenVINO refresh, image-library recompiles, VectorChord upgrade), takes a
`pg_dump`, then rebuilds from the pinned Gallery release. Bump `RELEASE` in
`ct/gallery.sh` after reading the release notes, or override once with
`var_appversion=v5.4.0 update`.

## Before you switch

Take a container snapshot from the **Proxmox host** — this is the only rollback that
covers everything at once:

```bash
pct snapshot <ctid> pre-gallery
```

Better still, rehearse on a clone first:

```bash
pct clone <ctid> <new-ctid> --hostname gallery-test
```

The tool takes a `pg_dump` automatically before every destructive step, into
`/opt/immich/backups/`, and moves the old `app/` aside rather than deleting it when
there is disk space for both.

## Version pinning, and the one hard rule

Gallery's migrations assume the database is at the exact Immich release the fork is
rebased on — published in Gallery's `branding/config.json` as `upstream.version`
(3.1.0 for Gallery v5.3.1). `to-gallery` checks this against your `~/.immich` and
**refuses to run on a mismatch**. If it complains, run `update` to bring Immich to
the named version first, then switch. `--force` exists but turns a code swap into an
untested cross-version migration.

## What rolling back costs

`to-immich` defaults to running Gallery's own `scripts/revert-to-immich.sql`. Photos
and albums you added while on Gallery are **kept**. Permanently dropped:

- Shared Spaces — members, assets, person clusters, libraries, activity, audit trail
- User groups and memberships
- Classification categories and prompts
- Pet detection results (`person.type`, `person.species`)
- Asset duplicate checksums
- Library sync state and storage migration history

The cleanup runs in a single transaction, so a mid-way failure leaves the database
untouched. A dump is taken first regardless.

The lossless alternative is `--restore-dump /opt/immich/backups/pre-gallery-*/database.dump`,
which rewinds the database to the moment you switched — anything added while on
Gallery stays on disk in `upload/` but disappears from the library.

## Order of operations

Both directions build first and touch the database last, because the build is the
long, failure-prone step and the database is still consistent while it runs:

```
stop services -> pg_dump -> snapshot app/ -> build -> database step -> start -> health check
```

If the build fails, the database is untouched; restore the `app/` snapshot and you
are back where you started. The script prints the exact commands on failure.

## Layout

```
ct/gallery.sh                  Gallery updater, community-scripts ct/ shape
tools/immich-flavor.sh         status / backup-db / to-gallery / to-immich
tools/check-upstream-drift.sh  diff live upstream scripts against vendor/
lib/build.func                 shared source -> /opt/immich/app build
lib/flavor.func                flavor marker, preflight, backups, services
lib/compile-libs.func          image-library recompiles (verbatim from upstream)
vendor/                        upstream snapshots for drift detection
```

### Keeping in sync with upstream

`lib/compile-libs.func` and the maintenance blocks in `ct/gallery.sh` are copies of
community-scripts code and will drift. Before bumping the pinned Gallery release:

```bash
tools/check-upstream-drift.sh            # show what changed upstream
tools/check-upstream-drift.sh --update   # accept the snapshots once ported
```

## Known limitations

- **`ct/immich.sh` run by hand against a Gallery install is still unsafe.**
  `/usr/bin/update` is repointed and `ct/gallery.sh` refuses to touch a non-Gallery
  install, but upstream offers no hook to block a direct `curl | bash` of its own
  script. It would rebuild Immich on top of Gallery's schema.
  (`~/.immich` is deliberately left in place after a switch: while upstream still
  pins the same Immich release, an accidental run sees an equal version and no-ops.)
- Rolling back does not recover Gallery-only data. The pre-switch `pg_dump` is the
  only lossless path.
- A switch takes roughly 20–45 minutes on 4 cores. No C libraries are recompiled;
  the time goes into pnpm builds and the machine-learning venv.
- The Immich mobile app is expected to work against Gallery (same API surface); it
  is not covered by any test here.
- Everything here is unofficial and unaffiliated with either project.

## Licence

MIT. Vendored community-scripts code is MIT; see `vendor/VENDOR.md`.
