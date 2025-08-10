# Troubleshooting

- Проверка `zpool status`, `zpool iostat`
- Медленный resilver: проверьте нагрузки, состояние NVMe, special‑вместимость
- Переполнение special vdev: снизить порог `special_small_blocks` и/или добавить special mirror
