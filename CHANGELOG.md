# Changelog

Все заметные изменения проекта. Формат основан на
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии следуют
[Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

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
