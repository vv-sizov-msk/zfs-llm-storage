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
