# Дизайн (mirror vs RAIDZ)

- Выбор: **2× mirror vdev** (4 HDD) для низкой латентности/IOPS.
- special vdev на NVMe (`special_small_blocks=32K`)
- SLOG 32 ГБ на NVMe для sync‑путей (NFS/iSCSI/VM)
- L2ARC из остатка NVMe
- Когда RAIDZ уместнее: архив/медиатеки/холодные данные/большие последовательные файлы.
