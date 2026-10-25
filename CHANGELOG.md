# Changelog

Все заметные изменения проекта. Формат основан на
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии следуют
[Semantic Versioning](https://semver.org/lang/ru/).

## [1.1.0] - 2026-10-25

### Добавлено

- Необязательное графическое окружение: XFCE + LightDM, GNOME + GDM или
  `DESKTOP="none"` для консольной установки.
- Новый ключ `DESKTOP` с валидацией и настройкой в мастере.
- Этап `desktop` после загрузчика и перед финализацией. При отказе от графики
  этап сразу отмечается завершённым и не требует сети.
- Установка Xorg, драйверов ввода, XFCE/GNOME и соответствующего
  дисплей-менеджера; для OpenRC включаются `dbus`, `elogind` и
  `display-manager`, для systemd — unit менеджера и `graphical.target`.
- Автоматический выбор профиля Portage: XFCE → `desktop`, GNOME → `gnome`;
  явные `kde` и `hardened` сохраняются.
- Для OpenRC-графики в `USE` автоматически добавляется `elogind`, чтобы
  LightDM/GDM собирались и с явным профилем `hardened`.
- Добавление пользователя в группы `plugdev`, `input`, `render`, `video`,
  `audio`, если они существуют.
- Unit-тесты для пакетов, дисплей-менеджеров, служб, проверки установки и
  сетевого требования; всего 288 assertions в 8 файлах.
- Документация по этапу графики, профилям, службам и проверке в VM.

### Изменено

- `STATE_STEPS` и общий счётчик этапов: теперь 9 этапов.
- Preflight считает сеть обязательной, пока выбранный этап графики не завершён.
- Мастер предупреждает, если `DESKTOP` изменён после Portage, и если
  `VIDEO_CARDS` не заданы.

### Безопасность

- Пароли по-прежнему не входят в конфигурацию, состояние и журналы; установка
  графики не добавляет секретов в файлы.

## [1.0.0] - 2026-10-25

Первый публичный релиз.

### Добавлено

- Консольный TUI-установщик на Bash 4.4+ без `dialog`/`whiptail`.
- UEFI + GPT с ESP в `/efi` и BIOS + MBR с `/boot`; загрузчик GRUB.
- Автоматическая разметка по схемам Gentoo AMD64 Handbook и ручное назначение
  существующих разделов.
- XFS, ext4, Btrfs, FAT32 и swap; необязательные отдельные swap и `/home`.
- Stage3 `openrc`, `systemd`, `desktop-openrc`, `desktop-systemd`.
- Загрузка `latest-stage3`, докачка, проверка SHA256 и GPG-подписи.
- Portage: `make.conf`, профили, `CPU_FLAGS_X86`, CFLAGS, USE, `VIDEO_CARDS`,
  `MAKEOPTS`, необязательное обновление `@world`.
- Ядро `gentoo-kernel-bin`, `gentoo-kernel` и `gentoo-sources` с `menuconfig`;
  `installkernel` + `dracut`, firmware и микрокод.
- Настройка hostname, timezone, locale, keymap, fstab, root-пароля и
  пользователя.
- Службы: dhcpcd/NetworkManager, OpenSSH, cronie, chrony, sysklogd/rsyslog,
  sudo и gentoolkit.
- Установка GRUB для UEFI и BIOS с проверкой `grub.cfg` и `root=`.
- Возобновление установки по файлу состояния, сброс состояния, повтор
  неудачных команд.
- Журналы команд с правами `0600`; пароли не сохраняются в конфигурацию и
  журналы.
- Пример конфигурации `conf/installer.conf.example` со всеми ключами.
- Unit-тесты (230 assertions), ShellCheck-проверки, CI и release-сборка.
- Документация: README, Handbook mapping, архитектура, тестирование,
  конфигурация, безопасность.

### Безопасность

- Stage3 не устанавливается без SHA256 или GPG-подписи.
- Конфигурация не исполняется как shell; ключи проверяются по whitelist.
- Kernel cmdline и GRUB defaults защищены от инъекций.
- Destructive-операции требуют `ERASE`, если не указан `--yes`.
- Preflight проверяет окружение до изменения диска.

### Известные ограничения

- Только amd64 и только GRUB.
- Нет LUKS, LVM, RAID, swap-файлов, Btrfs subvolumes и Secure Boot.
- Нет автоматического dual boot; `os-prober` отключён.
- Все разделы установки должны быть на одном диске.
- Автоматический интеграционный тест с реальной разметкой и загрузкой
  отсутствует; перед физической установкой требуется проверка в VM.
