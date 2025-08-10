# ZFS тюнинг

- `ashift=12`, `compression=lz4`, `xattr=sa`, `acltype=posixacl`
- `recordsize`: 1M для крупных последовательных данных, 16K для zvol (VM)
- ARC limit подбирается исходя из RAM (пример 8 ГБ на 16 ГБ RAM)
- `special_small_blocks=32K`
