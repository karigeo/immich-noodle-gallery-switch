#!/usr/bin/env bash
#
# ct/gallery.sh — update a community-scripts LXC that has been switched to
# Noodle Gallery with tools/immich-flavor.sh.
#
# Copyright (c) 2026 — MIT
# Source: https://opennoodle.de | GitHub: https://github.com/open-noodle/gallery
# Framework: https://github.com/community-scripts/ProxmoxVE (MIT)
# Derived from ct/immich.sh
# SYNCED-FROM: ct/immich.sh @ 33de14e45cbae374f3ae33386824e4bde0a5e8ce (2026-08-07)
#
# Run inside the LXC. After a switch, /usr/bin/update points here, so `update`
# is all you need.

# --- where this repo lives; override with RAW_BASE=... to test a branch ------
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/karigeo/immich-noodle-gallery-switch/main}"
# -----------------------------------------------------------------------------

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="gallery"
# Keep the community-scripts status guard from matching some unrelated "gallery"
# slug in its database and refusing to run. Read by build.func.
# shellcheck disable=SC2034
SCRIPT_SLUG="noodle-gallery"

var_tags="${var_tags:-photos}"
var_disk="${var_disk:-20}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-6144}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

# Pinned Noodle Gallery release. Bump after reading the release notes, or override
# for a single run with:  var_appversion=v5.4.0 update
RELEASE="${var_appversion:-v5.3.1}"

gallery_banner() {
  mkdir -p /usr/local/community-scripts/headers/ct
  if [[ ! -s /usr/local/community-scripts/headers/ct/gallery ]]; then
    cat <<'EOF' >/usr/local/community-scripts/headers/ct/gallery
   +------------------------------------------------+
   |   Noodle Gallery   -   a friendly Immich fork   |
   |   community-scripts LXC, built from source      |
   +------------------------------------------------+
EOF
  fi
}

gallery_banner
header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # ---------------------------------------------------------------------------
  # Guard: this updater must only ever run against a Gallery install.
  # ---------------------------------------------------------------------------
  if [[ ! -d /opt/immich ]]; then
    msg_error "No Immich/Gallery installation found at /opt/immich!"
    exit
  fi
  if [[ ! -f /opt/immich/.flavor ]] || ! grep -q '^FLAVOR=gallery' /opt/immich/.flavor; then
    msg_error "This container is not running Noodle Gallery."
    msg_error "Use the community-scripts updater instead:"
    echo "${TAB3}  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/immich.sh)\""
    msg_error "To switch it to Gallery, run tools/immich-flavor.sh to-gallery."
    exit
  fi
  if [[ -f /etc/apt/sources.list.d/immich.list ]]; then
    msg_error "Wrong Debian version detected!"
    msg_error "You must upgrade your LXC to Debian Trixie before updating."
    msg_error "See https://github.com/community-scripts/ProxmoxVE/discussions/7726"
    exit
  fi

  # shellcheck disable=SC1090
  source <(curl -fsSL "${RAW_BASE}/lib/build.func") || {
    msg_error "Could not load lib/build.func from ${RAW_BASE}"
    exit
  }
  # shellcheck disable=SC1090
  source <(curl -fsSL "${RAW_BASE}/lib/flavor.func")
  # shellcheck disable=SC1090
  source <(curl -fsSL "${RAW_BASE}/lib/compile-libs.func")
  flavor_paths

  # ---------------------------------------------------------------------------
  # Host maintenance — identical to ct/immich.sh, all of it flavor-agnostic.
  # ---------------------------------------------------------------------------
  if ! grep -qE '(^|[[:space:]])testing([[:space:]]|$)' /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
    msg_info "Adding Debian Testing repo"
    if grep -q "trixie-updates" /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
      sed -i 's/ trixie-updates/ trixie-updates testing/g' /etc/apt/sources.list.d/debian.sources
    else
      sed -i '/^[[:space:]]*Suites:.*trixie/ s/$/ testing/' /etc/apt/sources.list.d/debian.sources
    fi
    cat <<EOF >/etc/apt/preferences.d/preferences
Package: *
Pin: release a=unstable
Pin-Priority: 450

Package: *
Pin:release a=testing
Pin-Priority: 450
EOF
    [[ -f /etc/apt/preferences.d/immich ]] && rm /etc/apt/preferences.d/immich
    $STD apt update
    msg_ok "Added Debian Testing repo"
  fi

  if ! dpkg -l "libmimalloc3" | grep -q '3.1' || ! dpkg -l "libde265-dev" | grep -q '1.0.16'; then
    msg_info "Installing/upgrading Testing repo packages"
    $STD apt install -t testing libmimalloc3 libde265-dev -y
    msg_ok "Installed/upgraded Testing repo packages"
  fi

  if [[ ! -f /etc/apt/sources.list.d/mise.list ]]; then
    msg_info "Installing Mise"
    curl -fSs https://mise.jdx.dev/gpg-key.pub | tee /etc/apt/keyrings/mise-archive-keyring.pub 1>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.pub arch=$(arch_resolve)] https://mise.jdx.dev/deb stable main" >/etc/apt/sources.list.d/mise.list
    ensure_dependencies mise
    msg_ok "Installed Mise"
  fi

  cd /tmp || exit
  if [[ -f ~/.intel_version ]]; then
    curl_with_retry "https://raw.githubusercontent.com/immich-app/immich/refs/heads/main/machine-learning/Dockerfile" "Dockerfile"
    readarray -t INTEL_URLS < <(
      sed -n "/intel-[igc|opencl]/p" ./Dockerfile | awk '{print $3}'
      sed -n "/libigdgmm12/p" ./Dockerfile | awk '{print $3}'
    )
    INTEL_RELEASE="$(grep "intel-opencl-icd_" ./Dockerfile | awk -F '_' '{print $2}')"
    if [[ "$INTEL_RELEASE" != "$(cat ~/.intel_version)" ]]; then
      msg_info "Updating Intel OpenVINO dependencies"
      for url in "${INTEL_URLS[@]}"; do
        curl_with_retry "$url" "$(basename "$url")"
      done
      $STD apt-mark unhold libigdgmm12
      $STD apt install -y --allow-downgrades ./libigdgmm12*.deb
      rm ./libigdgmm12*.deb
      $STD apt install -y ./*.deb
      rm ./*.deb
      $STD apt-mark hold libigdgmm12
      dpkg-query -W -f='${Version}\n' intel-opencl-icd >~/.intel_version
      rm -f ./Dockerfile
      msg_ok "Updated Intel OpenVINO dependencies"
    fi
  fi

  flavor_recompile_libraries

  # ---------------------------------------------------------------------------
  # Gallery release
  # ---------------------------------------------------------------------------
  if check_for_gh_release "Gallery" "open-noodle/gallery" "${RELEASE}" \
    "each release is pinned in this script and bumped by hand after reading the release notes"; then

    flavor_maintenance enable
    flavor_stop_services

    # A fork's migrations are in play on every update, so always take a dump.
    flavor_backup "pre-update-gallery"
    local backup_dir="$FLAVOR_BACKUP_PATH"

    # -------------------------------------------------------------------------
    # VectorChord — verbatim from ct/immich.sh, keyed off the Immich pin because
    # Gallery does not change the vector extension.
    # -------------------------------------------------------------------------
    VCHORD_RELEASE="1.1.1"
    PG_VERSION=$(ls /etc/postgresql/ 2>/dev/null | sort -V | tail -1)
    PG_VERSION=${PG_VERSION:-16}
    DB_NAME="$(flavor_db_name)"
    [[ -f ~/.vchord_version ]] && mv ~/.vchord_version ~/.vectorchord
    if check_for_gh_release "VectorChord" "tensorchord/VectorChord" "${VCHORD_RELEASE}" "updated together with Immich after testing"; then
      # Dead tuples in smart_search/face_search make the REINDEX below fail with
      # "missing chunk ... for toast value"; must vacuum while still on the old
      # extension version, a post-upgrade vacuum errors instead.
      $STD sudo -u postgres psql -d "$DB_NAME" -c "VACUUM (ANALYZE) smart_search;"
      $STD sudo -u postgres psql -d "$DB_NAME" -c "VACUUM (ANALYZE) face_search;"
      fetch_and_deploy_gh_release "VectorChord" "tensorchord/VectorChord" "binary" "${VCHORD_RELEASE}" "/tmp" "postgresql-${PG_VERSION}-vchord_*_$(arch_resolve).deb"
      systemctl restart postgresql
      $STD sudo -u postgres psql -d "$DB_NAME" -c "ALTER EXTENSION vector UPDATE;"
      $STD sudo -u postgres psql -d "$DB_NAME" -c "ALTER EXTENSION vchord UPDATE;"
      $STD sudo -u postgres psql -d "$DB_NAME" -c "REINDEX INDEX face_index;"
      $STD sudo -u postgres psql -d "$DB_NAME" -c "REINDEX INDEX clip_index;"
    fi

    # -------------------------------------------------------------------------
    # Rebuild
    # -------------------------------------------------------------------------
    flavor_build_app "Gallery" "open-noodle/gallery" "${RELEASE}"

    # Keep the .env additions ct/immich.sh makes for older installs.
    if ! grep -q '^DB_HOSTNAME=' "$INSTALL_DIR"/.env; then
      sed -i '/^DB_DATABASE_NAME/a DB_HOSTNAME=127.0.0.1' "$INSTALL_DIR"/.env
    fi
    if ! grep -q 'HELMET_FILE' "$INSTALL_DIR"/.env; then
      sed -i -e '$a\' "$INSTALL_DIR"/.env
      echo "IMMICH_HELMET_FILE=true" >>"$INSTALL_DIR"/.env
    fi
    if grep -q 'ExecStart=/usr/bin/node' /etc/systemd/system/immich-web.service; then
      sed -i '/^EnvironmentFile=/d' /etc/systemd/system/immich-web.service
      sed -i "s|^ExecStart=.*|ExecStart=${APP_DIR}/bin/start.sh|" /etc/systemd/system/immich-web.service
      systemctl daemon-reload
    fi

    flavor_bump_marker_version "$FLAVOR_BUILT_VERSION"

    flavor_start_services
    [[ -f /etc/systemd/system/immich-proxy.service ]] && systemctl restart immich-proxy
    if flavor_wait_healthy 900; then
      flavor_maintenance disable
      msg_ok "Updated Noodle Gallery to ${FLAVOR_BUILT_VERSION}"
    else
      flavor_slow_start_notice "$backup_dir"
      msg_warn "Gallery ${FLAVOR_BUILT_VERSION} is installed but has not answered yet"
    fi
    echo "${TAB3}Pre-update backup: ${backup_dir}"
  fi
  exit
}

if command -v pveversion >/dev/null 2>&1; then
  msg_error "This script updates an existing container and must run *inside* it."
  msg_error "Enter the container first:  pct enter <ctid>"
  msg_error "To create a new Immich LXC, use the community-scripts ct/immich.sh."
  exit 1
fi

start
