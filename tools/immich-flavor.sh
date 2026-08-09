#!/usr/bin/env bash
#
# immich-flavor — switch a community-scripts Immich LXC between upstream Immich and
# Noodle Gallery, and back again.
#
# Copyright (c) 2026 — MIT
# Immich:         https://github.com/immich-app/immich
# Noodle Gallery: https://github.com/open-noodle/gallery
# Base scripts:   https://github.com/community-scripts/ProxmoxVE
#
# Run inside the LXC, as root:
#
#   bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- status
#   bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- to-gallery
#   bash -c "$(curl -fsSL $RAW_BASE/tools/immich-flavor.sh)" -- to-immich

# --- where this repo lives; override with RAW_BASE=... to test a branch ------
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/karigeo/immich-noodle-gallery-switch/main}"
# -----------------------------------------------------------------------------

CS_BASE="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"

# Pinned Noodle Gallery release. Bump after reading the release notes; --version
# overrides it for a one-off.
GALLERY_RELEASE="v5.3.1"

LOCAL_COPY="/usr/local/bin/immich-flavor"

# ==============================================================================
# Bootstrap
# ==============================================================================

# Source a repo file from the local checkout when there is one (script was cloned
# or previously installed), otherwise from $RAW_BASE (script was curl'd).
flavor_source() {
  local rel="$1" dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  if [[ -n "$dir" && -f "${dir}/${rel}" ]]; then
    # shellcheck disable=SC1090
    source "${dir}/${rel}"
  else
    # shellcheck disable=SC1090
    source <(curl -fsSL "${RAW_BASE}/${rel}") || {
      echo "FATAL: could not load ${rel} from ${RAW_BASE}" >&2
      exit 1
    }
  fi
}

# shellcheck disable=SC1090
source <(curl -fsSL "${CS_BASE}/misc/core.func") || {
  echo "FATAL: could not load core.func" >&2
  exit 1
}
# shellcheck disable=SC1090
source <(curl -fsSL "${CS_BASE}/misc/error_handler.func")
# shellcheck disable=SC1090
source <(curl -fsSL "${CS_BASE}/misc/tools.func")

flavor_source "lib/build.func"
flavor_source "lib/flavor.func"

load_functions
VERBOSE="${VERBOSE:-no}"
set_std_mode
catch_errors

# Print recovery guidance before the framework's error handler runs.
FLAVOR_RECOVERY_HINT=""
flavor_on_error() {
  local rc=$?
  if [[ -n "$FLAVOR_RECOVERY_HINT" ]]; then
    echo ""
    echo "================= RECOVERY ================="
    echo -e "$FLAVOR_RECOVERY_HINT"
    echo "============================================"
    echo ""
  fi
  if declare -F error_handler >/dev/null; then
    error_handler
  fi
  exit "$rc"
}
trap 'flavor_on_error' ERR

# ==============================================================================
# Usage
# ==============================================================================

usage() {
  cat <<EOF
immich-flavor — switch a community-scripts Immich LXC to Noodle Gallery and back.

USAGE
  immich-flavor <command> [options]

COMMANDS
  status                      Show which flavor is installed and where the backups are.
  backup-db                   Take a pg_dump only, no other changes.
  to-gallery [options]        Switch Immich -> Noodle Gallery.
  to-immich  [options]        Switch Noodle Gallery -> Immich.
  install-local               Copy this script (and libs) to ${LOCAL_COPY}.

to-gallery OPTIONS
  --version <tag>             Gallery release to install (default ${GALLERY_RELEASE}).
  --no-snapshot               Do not keep a copy of the current app/ directory.
  --force                     Proceed even if Gallery is not rebased on the installed
                              Immich version. Only do this if you know why.
  --yes                       Skip confirmation prompts.

to-immich OPTIONS
  --version <tag>             Immich release to install. Defaults to the version
                              Gallery is rebased on (branding/config.json).
  --restore-dump <file>       Restore this pg_dump instead of running Gallery's
                              revert-to-immich.sql cleanup.
  --no-snapshot               Do not keep a copy of the current app/ directory.
  --yes                       Skip confirmation prompts.

GLOBAL
  --verbose                   Show full build output instead of spinners.
  -h, --help                  This text.

Before either switch, snapshot the container from the Proxmox host:
  pct snapshot <ctid> pre-gallery
EOF
}

# ==============================================================================
# status
# ==============================================================================

cmd_status() {
  flavor_require_install
  flavor_detect

  local db upstream
  db="$(flavor_db_name)"

  echo ""
  echo "  Flavor            : ${FLAVOR_CURRENT}"
  echo "  Version           : ${FLAVOR_VERSION:-unknown}"
  [[ -n "$FLAVOR_UPSTREAM" ]] && echo "  Rebased on Immich : ${FLAVOR_UPSTREAM}"
  echo "  Install dir       : ${INSTALL_DIR}"
  echo "  Media location    : ${UPLOAD_DIR}"
  echo "  Database          : ${db}"
  echo "  Free space        : $(flavor_free_gb "$INSTALL_DIR")GB"
  echo "  immich-web        : $(systemctl is-active immich-web 2>/dev/null || echo unknown)"
  echo "  immich-ml         : $(systemctl is-active immich-ml 2>/dev/null || echo unknown)"
  echo "  /usr/bin/update   : $(grep -o 'ct/[a-z-]*\.sh' /usr/bin/update 2>/dev/null || echo unknown)"
  echo "  Version markers   : $(ls -1 "${HOME}"/.immich "${HOME}"/.gallery 2>/dev/null | tr '\n' ' ')"

  if [[ -d "$BACKUP_ROOT" ]]; then
    echo ""
    echo "  Backups in ${BACKUP_ROOT}:"
    du -sh "${BACKUP_ROOT}"/* 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  fi

  if [[ "$FLAVOR_CURRENT" == "immich" ]]; then
    upstream="$(flavor_gallery_upstream_version "$GALLERY_RELEASE" || true)"
    echo ""
    echo "  Gallery ${GALLERY_RELEASE} is rebased on Immich ${upstream:-?}; you are on ${FLAVOR_VERSION}."
    if [[ -n "$upstream" && "$upstream" == "$(flavor_strip_v "$FLAVOR_VERSION")" ]]; then
      echo "  -> Ready to switch: immich-flavor to-gallery"
    else
      echo "  -> Versions differ. Run 'update' to move Immich to ${upstream:-the matching release} first."
    fi
  fi
  echo ""
}

# ==============================================================================
# backup-db
# ==============================================================================

cmd_backup_db() {
  flavor_require_install
  flavor_detect
  flavor_backup "manual-${FLAVOR_CURRENT}" >/dev/null
}

# ==============================================================================
# install-local
# ==============================================================================

cmd_install_local() {
  local dir="/usr/local/lib/immich-flavor" src="" f
  msg_info "Installing a local copy to ${LOCAL_COPY}"
  mkdir -p "${dir}/lib" "${dir}/tools"

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  for f in lib/build.func lib/flavor.func lib/compile-libs.func tools/immich-flavor.sh; do
    if [[ -n "$src" && -f "${src}/${f}" && "${src}" != "${dir}" ]]; then
      cp "${src}/${f}" "${dir}/${f}"
    elif ! curl -fsSL "${RAW_BASE}/${f}" -o "${dir}/${f}"; then
      msg_warn "Could not fetch ${f} from ${RAW_BASE}; local copy is incomplete"
      return 0
    fi
  done

  chmod +x "${dir}/tools/immich-flavor.sh"
  ln -sf "${dir}/tools/immich-flavor.sh" "$LOCAL_COPY"
  msg_ok "Installed ${LOCAL_COPY}"
}

# ==============================================================================
# to-gallery
# ==============================================================================

cmd_to_gallery() {
  local tag="$GALLERY_RELEASE" force=0 snapshot=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --version)
      tag="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --no-snapshot)
      snapshot=0
      shift
      ;;
    --snapshot)
      snapshot=1
      shift
      ;;
    *)
      msg_error "Unknown option for to-gallery: $1"
      exit 1
      ;;
    esac
  done
  [[ "$tag" =~ ^v ]] || tag="v${tag}"

  flavor_require_install
  flavor_detect

  if [[ "$FLAVOR_CURRENT" == "gallery" ]]; then
    msg_error "This container already runs Noodle Gallery ${FLAVOR_VERSION}."
    msg_error "Use 'update' to move to a newer Gallery release."
    exit 1
  fi

  # --- baseline check -------------------------------------------------------
  # Gallery is a rebase fork: its migrations assume the database is at the Immich
  # release named in branding/config.json. Switching from a different Immich
  # version turns a code swap into an untested cross-version migration.
  msg_info "Checking that Gallery ${tag} is rebased on your Immich version"
  local upstream installed
  upstream="$(flavor_gallery_upstream_version "$tag")" || {
    msg_error "Could not read branding/config.json for ${tag} — is that a real Gallery tag?"
    exit 1
  }
  installed="$(flavor_strip_v "${FLAVOR_VERSION}")"
  if [[ "$upstream" != "$installed" ]]; then
    msg_error "Gallery ${tag} is rebased on Immich ${upstream}, but this container runs Immich ${installed}."
    if [[ "$force" -ne 1 ]]; then
      msg_error "Bring Immich to ${upstream} first (run 'update'), then switch."
      msg_error "Override with --force only if you understand the migration consequences."
      exit 1
    fi
    msg_warn "--force given; continuing with mismatched versions."
  else
    msg_ok "Gallery ${tag} is rebased on Immich ${upstream} — matches this container"
  fi

  flavor_require_space 12

  # --- confirmation ---------------------------------------------------------
  flavor_confirm yes <<EOF || exit 1
About to switch this container from Immich ${installed} to Noodle Gallery ${tag}.

  * /opt/immich/app is rebuilt from ${GALLERY_REPO}; the build takes 20-45 minutes.
  * Your photos in ${UPLOAD_DIR}, the database, .env, redis, postgres and the
    compiled image libraries are NOT touched by the build.
  * On first start Gallery applies its own database migrations, which add roughly
    30 fork-only tables. Going back afterwards means dropping them again.
  * A pg_dump is taken first, automatically.

Strongly recommended, from the Proxmox host, before you continue:
  pct snapshot <ctid> pre-gallery
EOF

  # --- quiesce and back up --------------------------------------------------
  flavor_maintenance enable
  flavor_stop_services

  local backup_dir
  flavor_backup "pre-gallery"
  backup_dir="$FLAVOR_BACKUP_PATH"

  FLAVOR_KEEP_APP_DIR=0
  if [[ "$snapshot" -eq 1 ]] && flavor_snapshot_app "$backup_dir"; then
    FLAVOR_KEEP_APP_DIR=1
  fi
  export FLAVOR_KEEP_APP_DIR

  # Nothing has touched the database at this point: Gallery's migrations only run
  # when its server starts, and it has not started. So recovery is app/ only.
  FLAVOR_RECOVERY_HINT="The build failed. Your database and photos are untouched, and
this container is still an Immich install (no flavor marker was written).

To get Immich running again, restore the snapshot of app/:
  rm -rf ${APP_DIR} && mv ${backup_dir}/app ${APP_DIR} && systemctl start immich-ml immich-web

If app/ was not snapshotted, force a fresh Immich build instead:
  rm -f ~/.immich && update

Database dump, should you ever need it: ${backup_dir}/database.dump"

  # --- build ----------------------------------------------------------------
  flavor_build_app "Gallery" "$GALLERY_REPO" "$tag"

  # --- record and rewire ----------------------------------------------------
  flavor_write_marker "gallery" "$FLAVOR_BUILT_VERSION" "$upstream" "$backup_dir"
  # ~/.immich is deliberately left alone: if ct/immich.sh is ever run by accident
  # while it still pins v${installed}, check_for_gh_release sees an equal version
  # and does nothing. Removing the marker would make it rebuild Immich over
  # Gallery's schema.
  flavor_set_update_shim "${RAW_BASE}/ct/gallery.sh"
  flavor_set_motd_name "immich" "Noodle Gallery"
  cmd_install_local

  # --- start ----------------------------------------------------------------
  # From here on the database is Gallery's: its migrations run at startup. Failing
  # loudly and suggesting a rollback would be wrong while that is in progress.
  FLAVOR_RECOVERY_HINT=""

  flavor_start_services
  if flavor_wait_healthy 900; then
    flavor_maintenance disable
    msg_ok "Switched to Noodle Gallery ${FLAVOR_BUILT_VERSION}"
  else
    flavor_slow_start_notice "$backup_dir"
    msg_warn "Gallery ${FLAVOR_BUILT_VERSION} is installed but has not answered yet"
  fi

  cat <<EOF

  Noodle Gallery ${FLAVOR_BUILT_VERSION} on http://$(hostname -I | awk '{print $1}'):2283

  Keep it updated with:   update            (now points at ct/gallery.sh)
  Roll back to Immich:    immich-flavor to-immich
  Pre-switch backup:      ${backup_dir}

  If the UI shows a maintenance page, clear it with:
      immich-admin disable-maintenance-mode

  Do NOT run the community-scripts ct/immich.sh against this container any more —
  it would rebuild Immich on top of Gallery's database schema.

EOF
}

# ==============================================================================
# to-immich
# ==============================================================================

cmd_to_immich() {
  local tag="" restore_dump="" snapshot=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --version)
      tag="$2"
      shift 2
      ;;
    --restore-dump)
      restore_dump="$2"
      shift 2
      ;;
    --no-snapshot)
      snapshot=0
      shift
      ;;
    --snapshot)
      snapshot=1
      shift
      ;;
    *)
      msg_error "Unknown option for to-immich: $1"
      exit 1
      ;;
    esac
  done

  flavor_require_install
  flavor_detect

  if [[ "$FLAVOR_CURRENT" != "gallery" ]]; then
    msg_error "This container is not running Noodle Gallery (flavor: ${FLAVOR_CURRENT})."
    msg_error "Nothing to roll back. Use the community-scripts ct/immich.sh to update Immich."
    exit 1
  fi

  # Target the Immich release Gallery is rebased on, unless told otherwise.
  if [[ -z "$tag" ]]; then
    local upstream
    upstream="${FLAVOR_UPSTREAM}"
    [[ -z "$upstream" ]] && upstream="$(flavor_installed_gallery_upstream_version || true)"
    if [[ -z "$upstream" ]]; then
      msg_error "Could not determine which Immich release to roll back to."
      msg_error "Pass it explicitly, e.g. --version v3.1.0"
      exit 1
    fi
    tag="v${upstream}"
  fi
  [[ "$tag" =~ ^v ]] || tag="v${tag}"

  if [[ -n "$restore_dump" && ! -s "$restore_dump" ]]; then
    msg_error "Dump file not found or empty: ${restore_dump}"
    exit 1
  fi

  flavor_require_space 12

  # --- locate the cleanup script before doing anything destructive ----------
  local revert_sql=""
  if [[ -z "$restore_dump" ]]; then
    revert_sql="${SRC_DIR}/scripts/revert-to-immich.sql"
    if [[ ! -f "$revert_sql" ]]; then
      msg_info "Fetching revert-to-immich.sql for Gallery v${FLAVOR_VERSION}"
      revert_sql="/tmp/revert-to-immich.sql"
      curl -fsSL "https://raw.githubusercontent.com/${GALLERY_REPO}/v${FLAVOR_VERSION}/scripts/revert-to-immich.sql" \
        -o "$revert_sql" ||
        curl -fsSL "https://raw.githubusercontent.com/${GALLERY_REPO}/main/scripts/revert-to-immich.sql" \
          -o "$revert_sql" || {
        msg_error "Could not obtain revert-to-immich.sql."
        msg_error "Download it manually and re-run, or use --restore-dump <file> instead."
        exit 1
      }
      msg_ok "Fetched revert-to-immich.sql"
    fi
  fi

  # --- confirmation ---------------------------------------------------------
  if [[ -n "$restore_dump" ]]; then
    flavor_confirm yes <<EOF || exit 1
About to roll back to Immich ${tag} and restore the database from:
  ${restore_dump}

The database returns to the state captured in that dump. Anything added while you
were on Gallery — photos, albums, edits — stays on disk in ${UPLOAD_DIR} but
disappears from the library. A fresh dump is taken first, so this is reversible.
EOF
  else
    flavor_confirm yes <<EOF || exit 1
About to roll back to Immich ${tag} using Gallery's revert-to-immich.sql cleanup.

Photos and albums you added while on Gallery are KEPT. These are dropped
permanently:

  * Shared Spaces — members, assets, person clusters, libraries, activity, audit
  * User groups and memberships
  * Classification categories and prompts
  * Pet detection results (person.type, person.species)
  * Asset duplicate checksums
  * Library sync state and storage migration history

A pg_dump is taken first (${BACKUP_ROOT}/pre-immich-*), and the cleanup runs in a
single transaction, so a failure mid-way leaves the database untouched.
EOF
  fi

  # --- quiesce and back up --------------------------------------------------
  flavor_maintenance enable
  flavor_stop_services

  local backup_dir
  flavor_backup "pre-immich"
  backup_dir="$FLAVOR_BACKUP_PATH"

  FLAVOR_KEEP_APP_DIR=0
  if [[ "$snapshot" -eq 1 ]] && flavor_snapshot_app "$backup_dir"; then
    FLAVOR_KEEP_APP_DIR=1
  fi
  export FLAVOR_KEEP_APP_DIR

  # Build first: it is the long, failure-prone step, and while it runs the database
  # is still pure Gallery. If it fails we put the snapshot back and Gallery works.
  FLAVOR_RECOVERY_HINT="The Immich build failed. The database is untouched and still
Gallery's, and the flavor marker still says gallery.

Restore the app snapshot to get Gallery running again:
  rm -rf ${APP_DIR} && mv ${backup_dir}/app ${APP_DIR} && systemctl start immich-ml immich-web

If app/ was not snapshotted, rebuild Gallery instead:
  rm -f ~/.gallery && update

Database dump: ${backup_dir}/database.dump"

  flavor_build_app "Immich" "$IMMICH_REPO" "$tag"

  # --- database -------------------------------------------------------------
  FLAVOR_RECOVERY_HINT="Immich ${tag} was built but the database step failed. The
cleanup script runs in one transaction, so the database is still Gallery's and the
flavor marker still says gallery — app/ is the only thing out of step.

Get Gallery back with:
  rm -rf ${APP_DIR} && mv ${backup_dir}/app ${APP_DIR} && systemctl start immich-ml immich-web
or, without a snapshot:
  rm -f ~/.gallery && update

Fresh dump taken just now: ${backup_dir}/database.dump"

  if [[ -n "$restore_dump" ]]; then
    flavor_pg_restore "$restore_dump"
  else
    flavor_run_revert_sql "$revert_sql"
  fi

  # --- record and rewire ----------------------------------------------------
  flavor_clear_marker
  rm -f "${HOME}/.gallery"
  flavor_strip_v "$tag" >"${HOME}/.immich"
  flavor_restore_update_shim
  flavor_set_motd_name "Noodle Gallery" "immich"

  FLAVOR_RECOVERY_HINT=""

  flavor_start_services
  if flavor_wait_healthy 600; then
    flavor_maintenance disable
    msg_ok "Rolled back to Immich ${FLAVOR_BUILT_VERSION}"
  else
    flavor_slow_start_notice "$backup_dir"
    msg_warn "Immich ${FLAVOR_BUILT_VERSION} is installed but has not answered yet"
    cat <<EOF

  A 'missing migration' or 'corrupted migrations' error in the log means the cleanup
  did not fully match this Immich release. Restore ${backup_dir}/database.dump and
  report it at https://github.com/${GALLERY_REPO}/issues

EOF
  fi

  cat <<EOF

  Immich ${FLAVOR_BUILT_VERSION} on http://$(hostname -I | awk '{print $1}'):2283

  'update' points at the community-scripts ct/immich.sh again.
  Pre-rollback backup: ${backup_dir}

  If the UI shows a maintenance page, clear it with:
      immich-admin disable-maintenance-mode

EOF
}

# ------------------------------------------------------------------------------
# flavor_run_revert_sql <file>
#
# Gallery refuses to run the cleanup without the acknowledgement GUC. Both -c and
# -f execute in the same psql session, so the SET is visible to the script.
# ------------------------------------------------------------------------------
flavor_run_revert_sql() {
  local sql="$1" db staged
  db="$(flavor_db_name)"

  staged="/tmp/revert-to-immich.$$.sql"
  install -o postgres -g postgres -m 0600 "$sql" "$staged"

  msg_info "Running Gallery's revert-to-immich.sql against '${db}'"
  if ! sudo -u postgres psql -d "$db" \
    -v ON_ERROR_STOP=1 \
    -c "SET gallery.revert_token = 'i_accept_data_loss';" \
    -f "$staged"; then
    rm -f "$staged"
    msg_error "revert-to-immich.sql failed. It runs in one transaction, so the database is unchanged."
    return 1
  fi
  rm -f "$staged"
  msg_ok "Gallery-only schema removed"
}

# ==============================================================================
# Dispatch
# ==============================================================================

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift

  # Global flags can appear anywhere.
  local args=() a
  for a in "$@"; do
    case "$a" in
    --yes | -y) ASSUME_YES=1 ;;
    --verbose)
      VERBOSE="yes"
      set_std_mode
      ;;
    *) args+=("$a") ;;
    esac
  done
  export ASSUME_YES="${ASSUME_YES:-0}"
  set -- "${args[@]}"

  case "$cmd" in
  status)
    flavor_require_container
    cmd_status
    ;;
  backup-db)
    flavor_require_root
    flavor_require_container
    cmd_backup_db
    ;;
  to-gallery)
    flavor_require_root
    flavor_require_container
    cmd_to_gallery "$@"
    ;;
  to-immich)
    flavor_require_root
    flavor_require_container
    cmd_to_immich "$@"
    ;;
  install-local)
    flavor_require_root
    cmd_install_local
    ;;
  -h | --help | help | "")
    usage
    ;;
  *)
    msg_error "Unknown command: ${cmd}"
    echo ""
    usage
    exit 1
    ;;
  esac
}

main "$@"
