#!/usr/bin/env bash
set -euo pipefail

# Load env if exists
if [ -f "scripts/examples/env.example" ]; then
  # shellcheck disable=SC1091
  source "scripts/examples/env.example"
fi

POOL_NAME="${POOL_NAME:-llm}"
SUBNET="${SUBNET:-192.168.1.0/24}"
SERVER_IP="$(hostname -I | awk '{print $1}')"
ARC_MAX_BYTES="${ARC_MAX_BYTES:-8589934592}" # 8G

HGST_DISKS=(${HGST_DISKS[@]:-/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2331PAKGEY7T /dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2331PAKGKMYT /dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2334PBGZT5ZT /dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2338P4H9XM0C})
INTEL_P4610="${INTEL_P4610:-/dev/disk/by-id/nvme-INTEL_SSDPE2KE016T8_PHLN326000ZE1P6AGN}"
INTEL_P4510="${INTEL_P4510:-/dev/disk/by-id/nvme-INTEL_SSDPF2KX960HZ_PHAO4022055N960RGN}"

P4610_SLOG_SIZE="${P4610_SLOG_SIZE:-32GiB}"
P4510_SPECIAL_SIZE="${P4510_SPECIAL_SIZE:-400GiB}"

ISCSI_ZVOL="${ISCSI_ZVOL:-vm/iscsi0}"
ISCSI_ZVOL_SIZE="${ISCSI_ZVOL_SIZE:-500G}"
ISCSI_IQN_TARGET="${ISCSI_IQN_TARGET:-iqn.2025-08.local.$(hostname):llm}"
ISCSI_INITIATOR_IQN_ALLOW="${ISCSI_INITIATOR_IQN_ALLOW:-iqn.1993-08.org.debian:initiator}"

install_if_missing() {
  if ! dpkg -s "$1" >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  install_if_missing zfsutils-linux
  install_if_missing nfs-kernel-server
  install_if_missing targetcli-fb
  install_if_missing ufw
  install_if_missing prometheus-node-exporter
fi

mkdir -p /etc/modprobe.d
echo "options zfs zfs_arc_max=${ARC_MAX_BYTES}" > /etc/modprobe.d/zfs.conf || true
if command -v update-initramfs >/dev/null 2>&1; then update-initramfs -u || true; fi
if [ -w /sys/module/zfs/parameters/zfs_arc_max ]; then
  echo "${ARC_MAX_BYTES}" > /sys/module/zfs/parameters/zfs_arc_max || true
fi

part_exists() { lsblk -no NAME "$1" | grep -qE "^$(basename "$1" | sed 's#^/dev/##')p?[0-9]$"; }

partition_nvme() {
  local dev="$1" first_label="$2" first_size="$3"
  if ! part_exists "$dev"; then
    parted -s "$dev" mklabel gpt
    parted -s "$dev" mkpart "$first_label" 1MiB "$first_size"
    parted -s "$dev" mkpart "REST" "$first_size" 100%
  fi
}

partition_nvme "$INTEL_P4610" "SLOG" "$P4610_SLOG_SIZE"
partition_nvme "$INTEL_P4510" "SPECIAL" "$P4510_SPECIAL_SIZE"

P4610_P1="${INTEL_P4610}p1"
P4610_P2="${INTEL_P4610}p2"
P4510_P1="${INTEL_P4510}p1"
P4510_P2="${INTEL_P4510}p2"

partprobe "$INTEL_P4610" || true
partprobe "$INTEL_P4510" || true
sleep 1

pool_exists() { zpool list -H "$POOL_NAME" >/dev/null 2>&1; }

if ! pool_exists; then
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O compression=lz4 \
    -O atime=off \
    -O relatime=on \
    -O xattr=sa \
    -O acltype=posixacl \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=/${POOL_NAME} \
    -O encryption=off \
    "$POOL_NAME" \
    mirror "${HGST_DISKS[0]}" "${HGST_DISKS[1]}" \
    mirror "${HGST_DISKS[2]}" "${HGST_DISKS[3]}"
  zpool set autoexpand=on "$POOL_NAME"
fi

if ! zpool status "$POOL_NAME" | grep -q "special"; then
  zpool add -f "$POOL_NAME" special "$P4510_P1"
  zfs set special_small_blocks=32K "${POOL_NAME}"
fi

if ! zpool status "$POOL_NAME" | grep -q "logs"; then
  zpool add -f "$POOL_NAME" log "$P4610_P1"
fi

add_cache_if_missing() {
  local dev="$1"
  if ! zpool status "$POOL_NAME" | grep -q "$(basename "$dev")"; then
    zpool add -f "$POOL_NAME" cache "$dev"
  fi
}
add_cache_if_missing "$P4610_P2"
add_cache_if_missing "$P4510_P2"

zfs set compression=lz4 "$POOL_NAME"
zfs set sync=standard "$POOL_NAME"
zfs set primarycache=all "$POOL_NAME"
zfs set secondarycache=all "$POOL_NAME"
zfs set logbias=latency "$POOL_NAME"

create_ds_if_absent() { zfs list -H -o name "$1" >/dev/null 2>&1 || zfs create "$1"; }

create_ds_if_absent "${POOL_NAME}/inference"
zfs set recordsize=1M "${POOL_NAME}/inference"

create_ds_if_absent "${POOL_NAME}/training"
zfs set recordsize=1M "${POOL_NAME}/training"
zfs set logbias=throughput "${POOL_NAME}/training"

create_ds_if_absent "${POOL_NAME}/tmp"
zfs set recordsize=128K "${POOL_NAME}/tmp"
zfs set sync=disabled "${POOL_NAME}/tmp"

create_ds_if_absent "${POOL_NAME}/backup"
zfs set recordsize=1M "${POOL_NAME}/backup"

if ! zfs list -H -o name "${POOL_NAME}/vm" >/dev/null 2>&1; then
  zfs create "${POOL_NAME}/vm"
fi

if ! zfs list -H -o name "${POOL_NAME}/${ISCSI_ZVOL}" >/dev/null 2>&1; then
  zfs create -V "${ISCSI_ZVOL_SIZE}" -b 16K -s \
    -o compression=lz4 \
    -o sync=always \
    -o volmode=dev \
    "${POOL_NAME}/${ISCSI_ZVOL}"
fi

mkdir -p /${POOL_NAME}/{inference,training,tmp,vm,backup}

mkdir -p /etc/nfs.conf.d
cat >/etc/nfs.conf.d/llm-nfsv4.conf <<'EOF'
[nfsd]
vers3=n
vers4=y
tcp=y
EOF

add_export() {
  local path="$1"
  local opts="rw,no_subtree_check,fsid=0,crossmnt,sec=sys"
  if ! grep -qE "^/${POOL_NAME}\s" /etc/exports 2>/dev/null; then
    echo "/${POOL_NAME} ${SUBNET}(${opts})" >> /etc/exports
  fi
  if ! grep -qE "^/${POOL_NAME}/${path}\s" /etc/exports 2>/dev/null; then
    echo "/${POOL_NAME}/${path} ${SUBNET}(rw,no_subtree_check,sec=sys)" >> /etc/exports
  fi
}
add_export inference
add_export training
add_export tmp
add_export backup

exportfs -ra
systemctl enable --now nfs-server

if ! targetcli ls | grep -q "${ISCSI_IQN_TARGET}"; then
  targetcli /backstores/block create name="${POOL_NAME}_${ISCSI_ZVOL##*/}" dev="/dev/zvol/${POOL_NAME}/${ISCSI_ZVOL}"
  targetcli /iscsi create "${ISCSI_IQN_TARGET}"
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/portals create 0.0.0.0 3260
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/luns create /backstores/block/${POOL_NAME}_${ISCSI_ZVOL##*/}
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/acls create "${ISCSI_INITIATOR_IQN_ALLOW}"
  targetcli saveconfig
fi
systemctl enable --now target

ufw status | grep -q "Status: active" || ufw --force enable
ufw allow from "${SUBNET%/*}" to any port 2049 proto tcp
ufw allow from "${SUBNET%/*}" to any port 3260 proto tcp
ufw allow from "${SUBNET%/*}" to any port 22 proto tcp

TEXTDIR="/var/lib/node_exporter/textfile-collector"
mkdir -p "$TEXTDIR"
install -m 0755 scripts/zfs_text_metrics.sh /usr/local/bin/zfs_text_metrics.sh
( crontab -l 2>/dev/null | grep -v zfs_text_metrics.sh ; echo "* * * * * /usr/local/bin/zfs_text_metrics.sh" ) | crontab -
systemctl enable --now prometheus-node-exporter

echo "Setup complete."
