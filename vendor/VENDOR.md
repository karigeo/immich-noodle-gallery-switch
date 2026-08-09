# Vendored upstream snapshots

These are verbatim copies of the community-scripts ProxmoxVE files that this repo's
scripts were derived from. They exist so `tools/check-upstream-drift.sh` can tell you
when upstream changed something you need to port into `lib/build.func`,
`lib/compile-libs.func` or `ct/gallery.sh`.

| File | Upstream path | Commit | Date |
|---|---|---|---|
| `ct-immich.sh` | `ct/immich.sh` | `33de14e45cbae374f3ae33386824e4bde0a5e8ce` | 2026-08-07 |
| `immich-install.sh` | `install/immich-install.sh` | `33de14e45cbae374f3ae33386824e4bde0a5e8ce` | 2026-08-07 |

Upstream repo: <https://github.com/community-scripts/ProxmoxVE>
License: MIT.

## Re-syncing

```bash
tools/check-upstream-drift.sh          # show what changed
tools/check-upstream-drift.sh --update # accept the new snapshots after porting
```

After `--update`, bump the commit column above (the script prints the new SHA).
