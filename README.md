# zfs-llm-storage

Высокопроизводительное ZFS‑хранилище для LLM/AI (inference, training, VM, backup) на базе HP ProLiant MicroServer Gen10:
- 4× HGST 4 ТБ HDD
- Intel P4610 1.92 ТБ (SLOG + L2ARC)
- Intel P4510 960 ГБ (special vdev + L2ARC)

## Особенности
- Схема **2× mirror vdev** для низкой латентности и высоких IOPS
- **special vdev** на NVMe для метаданных и малых блоков (`special_small_blocks=32K`)
- **SLOG** на NVMe для ускорения sync‑операций (NFS/iSCSI/VM)
- **L2ARC** из остатка NVMe
- Экспорт **NFSv4** и **iSCSI (LIO/targetcli)**
- Минимально‑надежный **UFW/pfSense** пример правил
- Мониторинг: **Prometheus node_exporter** + textfile‑collector, готовый дашборд Grafana

## Быстрый старт
1. Отредактируйте `scripts/examples/env.example` под свои идентификаторы дисков/подсети.
2. Запустите:
   ```bash
   sudo bash scripts/zfs_llm_setup.sh
   ```
3. Проверьте:
   ```bash
   zpool status
   zfs list
   sudo exportfs -s
   sudo targetcli ls
   ```

Подробности см. в `docs/`.
