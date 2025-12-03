#!/usr/bin/env bash
# scripts/zfs_llm_setup.sh

set -euo pipefail

###############################################################################
# Логирование в файл + stderr
###############################################################################

LOGFILE="${LOGFILE:-/var/log/zfs-llm-setup.log}"
mkdir -p "$(dirname "$LOGFILE")"
# Пишем вывод и в терминал, и в лог
exec > >(tee -a "$LOGFILE") 2>&1

###############################################################################
# Конфигурация по умолчанию (можно переопределить через переменные окружения)
###############################################################################

# Флаг безопасности: спрашивать подтверждение перед разметкой NVMe
REQUIRE_CONFIRM="${REQUIRE_CONFIRM:-1}"
# Разрешить ARC=11ГБ на машине с RAM < 16ГБ (по умолчанию запрещено)
ALLOW_LOW_MEM_ARC="${ALLOW_LOW_MEM_ARC:-0}"
# Управление UFW: по умолчанию включаем и настраиваем
ENABLE_UFW="${ENABLE_UFW:-1}"
# Использовать systemd timer для метрик (иначе cron)
USE_SYSTEMD_METRICS="${USE_SYSTEMD_METRICS:-1}"

POOL_NAME="${POOL_NAME:-llm}"
SUBNET="${SUBNET:-192.168.1.0/24}"
SERVER_IP="$(hostname -I | awk '{print $1}')"

# ARC ~11 ГБ (11 * 1024^3 = 11811160064)
ARC_MAX_BYTES="${ARC_MAX_BYTES:-11811160064}"

# HDD (HGST 4 ТБ) — подставлены реальные by-id из окружения пользователя
HGST_DISKS=(
  "${HGST_DISKS_0:-/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2331PAKGEY7T}"
  "${HGST_DISKS_1:-/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2331PAKGKMYT}"
  "${HGST_DISKS_2:-/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2334PBGZT5ZT}"
  "${HGST_DISKS_3:-/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2338P4H9XM0C}"
)

# NVMe SSD
INTEL_P4610="${INTEL_P4610:-/dev/disk/by-id/nvme-INTEL_SSDPE2KE016T8_PHLN326000ZE1P6AGN}"
INTEL_P4510="${INTEL_P4510:-/dev/disk/by-id/nvme-INTEL_SSDPF2KX960HZ_PHAO4022055N960RGN}"

# Разметка SSD:
# P4610: p1 = SLOG 32GiB, p2 = L2ARC (остальное)
# P4510: p1 = SPECIAL 400GiB, p2 = L2ARC (остальное)
P4610_SLOG_SIZE="${P4610_SLOG_SIZE:-32GiB}"
P4510_SPECIAL_SIZE="${P4510_SPECIAL_SIZE:-400GiB}"

# iSCSI zvol
ISCSI_ZVOL="${ISCSI_ZVOL:-vm/iscsi0}"
ISCSI_ZVOL_SIZE="${ISCSI_ZVOL_SIZE:-500G}"
ISCSI_IQN_TARGET="${ISCSI_IQN_TARGET:-iqn.2025-08.local.$(hostname):llm}"
ISCSI_INITIATOR_IQN_ALLOW="${ISCSI_INITIATOR_IQN_ALLOW:-iqn.1993-08.org.debian:initiator}"

###############################################################################
# Вспомогательные функции
###############################################################################

log() {
  printf '[zfs-llm-setup] %s\n' "$*" >&2
}

install_if_missing() {
  local pkg missing_packages=()

  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing_packages+=("$pkg")
    fi
  done

  if [ ${#missing_packages[@]} -gt 0 ]; then
    log "Устанавливаю пакеты: ${missing_packages[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
  fi
}

# Проверка: существует ли хотя бы один раздел у устройства (nvme0n1p1, sda1 и т.п.)
part_exists() {
  local dev="$1" base
  base="$(basename "$dev" | sed 's#^/dev/##')"
  lsblk -nr -o NAME "$dev" | grep -qE "^${base}p?[0-9]+$"
}

partition_nvme() {
  local dev="$1" first_label="$2" first_size="$3"

  if part_exists "$dev"; then
    log "Устройство $dev уже размечено, пропускаю разметку"
    return 0
  fi

  log "Разметка NVMe $dev: p1=$first_size, p2=остальное"
  parted -s "$dev" mklabel gpt
  parted -s "$dev" mkpart "$first_label" 1MiB "$first_size"
  parted -s "$dev" mkpart "L2ARC" "$first_size" 100%
}

pool_exists() {
  zpool list -H "$POOL_NAME" >/dev/null 2>&1
}

create_ds_if_absent() {
  local ds="$1"
  if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
    log "Создаю датасет $ds"
    zfs create "$ds"
  fi
}

add_export() {
  local path="$1" opts
  opts="rw,no_subtree_check,sec=sys"

  if ! grep -qE "^/${POOL_NAME}\\s" /etc/exports 2>/dev/null; then
    log "Добавляю NFS экспорт корня /${POOL_NAME}"
    echo "/${POOL_NAME} ${SUBNET}(rw,no_subtree_check,fsid=0,crossmnt,sec=sys)" >> /etc/exports
  fi

  if ! grep -qE "^/${POOL_NAME}/${path}\\s" /etc/exports 2>/dev/null; then
    log "Добавляю NFS экспорт /${POOL_NAME}/${path}"
    echo "/${POOL_NAME}/${path} ${SUBNET}(${opts})" >> /etc/exports
  fi
}

add_cache_if_missing() {
  local dev="$1" base
  base="$(basename "$dev")"

  if zpool status "$POOL_NAME" | grep -q "$base"; then
    log "L2ARC $dev уже добавлен, пропускаю"
    return 0
  fi

  log "Добавляю L2ARC устройство $dev"
  zpool add -f "$POOL_NAME" cache "$dev"
}

###############################################################################
# Проверка окружения и установка пакетов
###############################################################################

if ! command -v zpool >/dev/null 2>&1; then
  log "Устанавливаю ZFS и сопутствующие пакеты"
  install_if_missing zfsutils-linux
fi

install_if_missing nfs-kernel-server targetcli-fb ufw prometheus-node-exporter

###############################################################################
# Проверка RAM и настройка ARC (11 ГБ)
###############################################################################

mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_total_bytes=$((mem_total_kb * 1024))

if [ "$mem_total_bytes" -lt $((16 * 1024 * 1024 * 1024)) ] && [ "$ALLOW_LOW_MEM_ARC" -ne 1 ]; then
  log "Обнаружено < 16ГБ RAM. ARC=11ГБ может быть опасен. Установите ALLOW_LOW_MEM_ARC=1, если уверены."
  exit 1
fi

log "Настройка ARC: zfs_arc_max=${ARC_MAX_BYTES}"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/zfs-llm-arc.conf <<EOF
options zfs zfs_arc_max=${ARC_MAX_BYTES}
EOF

if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u || true
fi

if [ -w /sys/module/zfs/parameters/zfs_arc_max ]; then
  echo "${ARC_MAX_BYTES}" > /sys/module/zfs/parameters/zfs_arc_max || true
fi

###############################################################################
# Подтверждение перед разметкой NVMe
###############################################################################

if [ "$REQUIRE_CONFIRM" -eq 1 ]; then
  log "ПРЕДУПРЕЖДЕНИЕ: будут изменены разделы на устройствах: $INTEL_P4610 и $INTEL_P4510"
  lsblk "$INTEL_P4610" "$INTEL_P4510" || true
  read -r -p "Продолжить разметку NVMe (yes/NO)? " ans
  if [ "$ans" != "yes" ]; then
    log "Операция отменена пользователем"
    exit 1
  fi
fi

###############################################################################
# Разметка NVMe под SLOG / SPECIAL / L2ARC
###############################################################################

partition_nvme "$INTEL_P4610" "SLOG" "$P4610_SLOG_SIZE"
partition_nvme "$INTEL_P4510" "SPECIAL" "$P4510_SPECIAL_SIZE"

P4610_P1="${INTEL_P4610}p1"
P4610_P2="${INTEL_P4610}p2"
P4510_P1="${INTEL_P4510}p1"
P4510_P2="${INTEL_P4510}p2"

partprobe "$INTEL_P4610" || true
partprobe "$INTEL_P4510" || true
sleep 1

###############################################################################
# Создание пула: 2× mirror vdev + special + SLOG + L2ARC
###############################################################################

if ! pool_exists; then
  log "Создаю пул $POOL_NAME с mirror vdev"
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
else
  log "Пул $POOL_NAME уже существует, пропускаю создание"
fi

if ! zpool status "$POOL_NAME" | grep -q "special"; then
  log "Добавляю special vdev: $P4510_P1"
  zpool add -f "$POOL_NAME" special "$P4510_P1"
  zfs set special_small_blocks=32K "$POOL_NAME"
else
  log "special vdev уже настроен, пропускаю"
fi

if ! zpool status "$POOL_NAME" | grep -q "logs"; then
  log "Добавляю SLOG (log): $P4610_P1"
  zpool add -f "$POOL_NAME" log "$P4610_P1"
else
  log "SLOG уже добавлен, пропускаю"
fi

add_cache_if_missing "$P4610_P2"
add_cache_if_missing "$P4510_P2"

###############################################################################
# Тюнинг пула и датасетов
###############################################################################

zfs set compression=lz4 "$POOL_NAME"
zfs set sync=standard "$POOL_NAME"
zfs set primarycache=all "$POOL_NAME"
zfs set secondarycache=all "$POOL_NAME"
zfs set logbias=latency "$POOL_NAME"

# Датасеты
create_ds_if_absent "${POOL_NAME}/inference"
zfs set recordsize=1M "${POOL_NAME}/inference"

create_ds_if_absent "${POOL_NAME}/training"
zfs set recordsize=1M "${POOL_NAME}/training"
zfs set logbias=throughput "${POOL_NAME}/training"

create_ds_if_absent "${POOL_NAME}/tmp"
zfs set recordsize=128K "${POOL_NAME}/tmp"
# ВНИМАНИЕ: риск потери последних записей при сбое питания
zfs set sync=disabled "${POOL_NAME}/tmp"

create_ds_if_absent "${POOL_NAME}/backup"
zfs set recordsize=1M "${POOL_NAME}/backup"

if ! zfs list -H -o name "${POOL_NAME}/vm" >/dev/null 2>&1; then
  log "Создаю датасет ${POOL_NAME}/vm"
  zfs create "${POOL_NAME}/vm"
fi

if ! zfs list -H -o name "${POOL_NAME}/${ISCSI_ZVOL}" >/dev/null 2>&1; then
  log "Создаю zvol ${POOL_NAME}/${ISCSI_ZVOL} (${ISCSI_ZVOL_SIZE})"
  zfs create -V "${ISCSI_ZVOL_SIZE}" -b 16K -s \
    -o compression=lz4 \
    -o sync=always \
    -o volmode=dev \
    "${POOL_NAME}/${ISCSI_ZVOL}"
else
  log "zvol ${POOL_NAME}/${ISCSI_ZVOL} уже существует, пропускаю"
fi

###############################################################################
# Настройка NFSv4
###############################################################################

mkdir -p /"${POOL_NAME}"/{inference,training,tmp,vm,backup}

mkdir -p /etc/nfs.conf.d
cat >/etc/nfs.conf.d/zfs-llm-nfsv4.conf <<'EOF'
[nfsd]
vers3=n
vers4=y
tcp=y
EOF

add_export inference
add_export training
add_export tmp
add_export backup

exportfs -ra
systemctl enable --now nfs-server

###############################################################################
# Настройка iSCSI (LIO/targetcli)
###############################################################################

if ! targetcli ls | grep -q "${ISCSI_IQN_TARGET}"; then
  log "Создаю iSCSI target ${ISCSI_IQN_TARGET}"
  targetcli /backstores/block create name="${POOL_NAME}_${ISCSI_ZVOL##*/}" dev="/dev/zvol/${POOL_NAME}/${ISCSI_ZVOL}"
  targetcli /iscsi create "${ISCSI_IQN_TARGET}"
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/portals create 0.0.0.0 3260
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/luns create /backstores/block/${POOL_NAME}_${ISCSI_ZVOL##*/}
  targetcli /iscsi/"${ISCSI_IQN_TARGET}"/tpg1/acls create "${ISCSI_INITIATOR_IQN_ALLOW}"
  targetcli saveconfig
else
  log "iSCSI target ${ISCSI_IQN_TARGET} уже существует, пропускаю"
fi

systemctl enable --now target

###############################################################################
# Firewall (UFW)
###############################################################################

if [ "$ENABLE_UFW" -eq 1 ]; then
  if ! ufw status | grep -q "Status: active"; then
    log "Включаю UFW"
    ufw --force enable
  fi

  log "Разрешаю доступ NFSv4 (2049/tcp) из подсети ${SUBNET}"
  ufw allow from "${SUBNET%/*}" to any port 2049 proto tcp || true

  log "Разрешаю доступ iSCSI (3260/tcp) из подсети ${SUBNET}"
  ufw allow from "${SUBNET%/*}" to any port 3260 proto tcp || true

  log "Разрешаю SSH (22/tcp) из подсети ${SUBNET}"
  ufw allow from "${SUBNET%/*}" to any port 22 proto tcp || true
else
  log "ENABLE_UFW=0, настройки UFW пропущены"
fi

###############################################################################
# Мониторинг: node_exporter + textfile collector для ZFS
###############################################################################

TEXTDIR="/var/lib/node_exporter/textfile-collector"
mkdir -p "$TEXTDIR"

cat >/usr/local/bin/zfs_text_metrics.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
OUT="/var/lib/node_exporter/textfile-collector/zfs.prom"

{
  echo "# HELP zfs_zpool_health Pool health (0=ONLINE,1=DEGRADED,2=FAULTED,3=OFFLINE,4=UNKNOWN)"
  echo "# TYPE zfs_zpool_health gauge"
  zpool list -H -o name,health | while read -r name health; do
    val=4
    case "$health" in
      ONLINE) val=0;;
      DEGRADED) val=1;;
      FAULTED) val=2;;
      OFFLINE) val=3;;
      *) val=4;;
    esac
    echo "zfs_zpool_health{pool=\"$name\"} $val"
  done

  echo "# HELP zfs_zpool_iostat_bytes ZFS pool I/O bytes"
  echo "# TYPE zfs_zpool_iostat_bytes counter"
  zpool iostat -y -H -p 1 1 | tail -n +2 | while read -r name alloc free read write; do
    echo "zfs_zpool_read_bytes{pool=\"$name\"} $read"
    echo "zfs_zpool_write_bytes{pool=\"$name\"} $write"
  done

  echo "# HELP zfs_arc_stats ARC stats"
  echo "# TYPE zfs_arc_stats gauge"
  awk '{print "zfs_arc_" $1 " " $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null | sed 's/:-/_/g' || true
} > "$OUT.$$"

mv "$OUT.$$" "$OUT"
EOF

chmod +x /usr/local/bin/zfs_text_metrics.sh

if [ "$USE_SYSTEMD_METRICS" -eq 1 ]; then
  cat >/etc/systemd/system/zfs-metrics.service <<'EOF'
# zfs-metrics.service
[Unit]
Description=Export ZFS metrics to node_exporter textfile

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zfs_text_metrics.sh
EOF

  cat >/etc/systemd/system/zfs-metrics.timer <<'EOF'
# zfs-metrics.timer
[Unit]
Description=Run ZFS metrics exporter every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=zfs-metrics.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now zfs-metrics.timer
else
  (
    crontab -l 2>/dev/null | grep -v zfs_text_metrics.sh || true
    echo "* * * * * /usr/local/bin/zfs_text_metrics.sh"
  ) | crontab -
fi

systemctl enable --now prometheus-node-exporter

###############################################################################
# Финал
###############################################################################

log "Настройка пула ${POOL_NAME} завершена. Проверьте:"
log "  zpool status"
log "  zfs list"
log "  exportfs -s"
log "  targetcli ls"
