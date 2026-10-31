# Соответствие Gentoo AMD64 Handbook

Установщик реализует основной путь установки из
[Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64). Ниже
перечислены главы Handbook, действия установщика и сознательные отличия.

## Общая последовательность

```
Minimal CD
  │
  ├─ проверка окружения, сети, даты и инструментов
  ├─ глава 4  → диск: GPT/MBR, разделы, ФС, UUID, монтирование
  ├─ глава 5  → stage3: загрузка, SHA256/GPG, распаковка
  ├─ глава 6  → Portage: chroot, make.conf, sync, профиль
  ├─ глава 7  → ядро: firmware, microcode, kernel, initramfs
  ├─ глава 8  → система: hostname, время, locale, fstab, учётные записи
  ├─ глава 9  → службы и дополнительные утилиты
  ├─ глава 10 → GRUB: установка и генерация grub.cfg
  ├─ графика  → Xorg + XFCE/LightDM или GNOME/GDM (вне core Handbook)
  └─ глава 11 → depclean, очистка, размонтирование, reboot
```

Этап «Графика» добавлен после главы 10 и перед главой 11. Основной Handbook
заканчивается настройкой загрузчика и финализацией; графические окружения
описаны в отдельных руководствах Gentoo Desktop. Такое расположение оставляет
базовую систему загрузочной даже при сбое установки графики, а финальный
`depclean` выполняется уже после неё и видит все установленные пакеты.

## Интерфейс и язык

Английский — исходный и используемый по умолчанию язык интерфейса. При первом
запуске установщик предлагает `English` или `Русский`; выбор сохраняется в
`UI_LANGUAGE`. Язык можно сменить в главном меню или параметром `--lang en|ru`.

Русские строки находятся в `lib/lang/ru.tsv`; отсутствующие записи откатываются
к английскому. Для русского интерфейса установщик выбирает или генерирует
UTF-8 locale `ru_RU.UTF-8`. Это касается только TUI: системная локаль целевой
системы задаётся ключом `LOCALE` на этапе «Система».

Внизу каждого экрана находится панель действий `<Back>`, `<Next>`,
`<Save>` (F2), `<Help>` (F1), `<Exit>` (F10) и подсказка по клавишам:

- `↑`/`↓` — перемещение по пунктам; с последнего пункта `↓` переводит на панель
  действий, `↑` с панели возвращает к пунктам;
- `←`/`→` — выбор кнопки на панели действий (на содержимом страницы игнорируются);
- `Пробел` — отметить вариант в окне выбора (`[ ]`/`[*]` или `( )`/`(*)`);
- `Enter` — изменить поле, перейти к панели действий или нажать кнопку;
  выбор варианта выполняется пробелом, поэтому Enter не меняет ответ;
- `Esc` — вернуться на предыдущую страницу;
- `F1` — справка;
- `F2`, `Ctrl-S` — сохранить конфигурацию;
- `F10` — выйти с текущей страницы.

Над панелью выводится компактная сводка: режим загрузки, диск и размер,
файловые системы, swap и `/home`, Stage3, метод установки ядра, графическое
окружение, прогресс этапов, язык и целевая локаль. Она обновляется после
каждого изменения и помогает проверить параметры перед установкой.

Установщик сначала собирает все параметры на восьми страницах и только после
итогового подтверждения начинает работу. После этого этапы выполняются
непрерывно, без вопросов между ними. Ручная настройка ядра (`make menuconfig`)
остаётся интерактивной и явно обозначена на странице «Ядро».

## Главы Handbook

### Глава 2. Выбор установочного носителя

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Media>

Установщик предполагает, что пользователь уже загрузился с Minimal Installation
CD в нужном режиме — UEFI или BIOS. Preflight проверяет:

- архитектуру `x86_64`;
- наличие `/sys/firmware/efi/efivars` для UEFI;
- дату системы (слишком старая дата блокирует установку);
- доступ к `distfiles.gentoo.org`;
- обязательные утилиты live-среды;
- наличие `mkfs.xfs`/`mkfs.btrfs` для выбранных файловых систем;
- Secure Boot и выбранный целевой диск.

Если Minimal CD загружен в BIOS, а в конфигурации выбран UEFI (или наоборот),
установка блокируется до изменения диска.

### Глава 3. Настройка сети

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Networking>

Сеть live-среды настраивается пользователем до запуска установщика. Установщик
не изменяет сеть Minimal CD; он только проверяет HTTPS-доступ к зеркалу и
копирует `/etc/resolv.conf` в chroot на этапе Portage. Для установленной системы
можно выбрать `dhcpcd`, `NetworkManager` или `none`.

### Глава 4. Подготовка дисков

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Disks>

Поддерживаются две автоматические схемы:

| Режим | Таблица | Первый раздел | Загрузчик |
|---|---|---|---|
| UEFI | GPT | ESP 1024 MiB, FAT32, `/efi`, флаг `esp` | `x86_64-efi` |
| BIOS | MBR (`msdos`) | `/boot` 1024 MiB, ext4/XFS/Btrfs, флаг `boot` | `i386-pc` |

Далее по порядку: необязательный swap, root, необязательный `/home`.

- Размер диска определяется через `blockdev --getsize64`, затем
  `lsblk -bndo SIZE` и sysfs (`/sys/block/<name>/size` или
  `/sys/class/block/<name>/size`). Пустые, нулевые и значения меньше 1 MiB
  отбрасываются. Это устраняет ложное определение `0 MiB` для virtio-дисков
  `/dev/vda` в KVM/QEMU.
- Минимальный размер диска для автоматической схемы — 4 GiB на уровне
  планировщика; проверка конфигурации требует не меньше 16 GiB, чтобы установка
  имела практический смысл.
- Корневой раздел должен получить не меньше 8 GiB.
- После монтирования требуется не меньше 6 GiB свободного места.
- Размер swap `auto` выбирается по таблице Handbook в зависимости от RAM.
- `/home` можно вынести на отдельный раздел.
- BIOS + MBR запрещён для дисков больше 2 TiB; для них нужен UEFI + GPT.
- UUID снимаются через `blkid`; монтирование и fstab используют UUID.

В ручном режиме установщик не создаёт таблицу разделов (по желанию открывает
`cfdisk`), а просит назначить существующие разделы ролям. Проверяется, что все
разделы находятся на одном диске, не повторяются и соответствуют выбранной
таблице (GPT для UEFI, MBR для BIOS). Форматирование каждого раздела можно
отключить, чтобы сохранить существующую ФС; для ESP при этом требуется FAT32,
для `/boot` и `/home` — ext4/XFS/Btrfs, для swap — существующий swap.

**Отличия:** Btrfs создаётся одной файловой системой без subvolumes и сжатия.
Отдельные разделы для `/var`, `/usr`, `/tmp` и swap-файлы не поддерживаются.

### Глава 5. Установка stage3

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Stage>

Установщик:

1. Загружает `releases/amd64/autobuilds/latest-stage3-amd64-<flavor>.txt` с
   выбранного зеркала либо использует прямой URL из `STAGE_URL`.
2. Скачивает `.tar.xz` с докачкой и проверкой ожидаемого размера.
3. Скачивает sidecar `.sha256` и `.asc`, если они доступны.
4. Проверяет SHA256; при наличии GPG импортирует ключ релизов Gentoo из
   `/usr/share/openpgp-keys/gentoo-release.asc` и проверяет подпись.
5. Распаковывает архив с `--xattrs-include='*.*' --numeric-owner -xpvf`.

Если нет ни SHA256, ни GPG-подписи, установка прерывается. Если GPG недоступен,
но SHA256 есть, выводится предупреждение и проверяется только SHA256.

Варианты stage3: `openrc`, `systemd`, `desktop-openrc`, `desktop-systemd`.
Desktop-варианты автоматически выбирают профиль `desktop`, если пользователь не
выбрал `gnome`, `kde` или `hardened`. Выбор `DESKTOP=xfce` или `DESKTOP=gnome`
также подстраивает профиль: XFCE выбирает `desktop`, GNOME — `gnome`; явные
`kde` и `hardened` сохраняются.

### Глава 6. Установка базовой системы

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base>

Действия этапа Portage:

- копирование `/etc/resolv.conf` в целевое окружение;
- запись `/etc/portage/make.conf` с `COMMON_FLAGS`, `CFLAGS`, `CXXFLAGS`,
  `MAKEOPTS`, `ACCEPT_LICENSE="*"`, `GRUB_PLATFORMS`, `USE`, `VIDEO_CARDS` и
  определёнными `CPU_FLAGS_X86`;
- `/etc/portage/package.use/installer` с `sys-kernel/installkernel dracut`;
- `emerge-webrsync`;
- установка `cpuid2cpuflags` и определение CPU-флагов (если включено);
- выбор профиля через `eselect profile` и `env-update`;
- необязательное `emerge --update --deep --newuse @world`.

chroot подготавливается монтированием `/proc`, `/sys`, `/dev` и `/run`. Эти
монтирования снимаются перед размонтированием целевой системы.

**Отличия:** используется `emerge-webrsync`, а не `emerge --sync`; это
предсказуемее в live-среде. `ACCEPT_LICENSE="*"` выбран для удобства, а не для
минимизации лицензионных ограничений.

### Глава 7. Настройка ядра

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Kernel>

Три режима:

| Режим | Пакет | Особенности |
|---|---|---|
| `bin` | `sys-kernel/gentoo-kernel-bin` | Готовое бинарное ядро, самый быстрый путь. |
| `dist` | `sys-kernel/gentoo-kernel` | Сборка с конфигурацией Gentoo. |
| `manual` | `sys-kernel/gentoo-sources` | `make menuconfig`, затем `make`, `modules_install`, `install`. |

Для всех режимов устанавливаются `sys-kernel/installkernel` и
`sys-kernel/dracut`. Конфигурация dracut запрещает host-only initramfs:

```text
hostonly="no"
hostonly_cmdline="no"
```

Командная строка ядра записывается в `/etc/kernel/cmdline` как
`root=UUID=<root> ro <дополнительные параметры>`. Параметр `root=` из
пользовательского ввода удаляется, чтобы не было дубликатов. GRUB получает
только дополнительные параметры; `root=` добавляет `grub-mkconfig`.

Дополнительно:

- `sys-kernel/linux-firmware` — по выбору;
- микрокод Intel/AMD — автоматически по производителю CPU или вручную;
- для ручной сборки ставятся `bc`, `flex`, `bison`, `elfutils`, `ncurses`,
  `pahole`, `openssl`.

После установки проверяется наличие `vmlinuz-*`/`kernel-*` и initramfs. Если
initramfs отсутствует, установщик пытается создать его через `dracut --force`.

**Отличия:** установщик не редактирует вручную `.config` и не включает
конкретные драйверы; в ручном режиме ответственность за конфигурацию несёт
пользователь.

### Глава 8. Настройка системы

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/System>

Записываются:

- `/etc/hostname`, `/etc/hosts`, `/etc/conf.d/hostname` (OpenRC);
- `/etc/localtime`, `/etc/timezone`, `/etc/conf.d/hwclock` (OpenRC);
- `/etc/locale.gen`, `/etc/env.d/02locale`, `/etc/locale.conf`, затем
  `locale-gen` и `env-update`;
- `/etc/conf.d/keymaps` (OpenRC) и `/etc/vconsole.conf` (systemd);
- `/etc/fstab` с UUID для root, ESP или `/boot`, swap и `/home`;
- пароль root через `chpasswd`;
- пользователь с группами `users`, `wheel`, `audio`, `video`, `usb`, `cdrom`,
  если они существуют, и его пароль.

Если RTC недоступен, `hwclock --systohc` не прерывает установку: выбор UTC/local
сохраняется в `/etc/adjtime`, выводится предупреждение.

`/etc/fstab` для Btrfs использует `pass=0` для корня; для остальных ФС — `pass=1`.

### Глава 9. Установка системных инструментов

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Tools>

Устанавливается `app-portage/gentoolkit`, затем по выбору:

| Опция | Пакет | Служба |
|---|---|---|
| `NETWORK=dhcpcd` | `net-misc/dhcpcd` | `dhcpcd` |
| `NETWORK=networkmanager` | `net-misc/networkmanager` | `NetworkManager` |
| `SSH=yes` | `net-misc/openssh` | `sshd` |
| `CRON=yes` | `sys-process/cronie` | `cronie` |
| `CHRONY=yes` | `net-misc/chrony` | `chronyd` |
| `SYSLOG=yes` | `app-admin/sysklogd` (OpenRC) или `app-admin/rsyslog` (systemd) | соответствующая |
| `SUDO=yes` | `app-admin/sudo` | правило `%wheel ALL=(ALL:ALL) ALL` |

Службы включаются через `rc-update add ... default` или `systemctl enable`.
Правило sudo проверяется через `visudo -cf /etc/sudoers`.

**Отличия:** установщик не настраивает статический IP, Wi-Fi, PPPoE и другие
сложные сетевые сценарии; для них выберите `NETWORK=none` и настройте сеть
вручную после первой загрузки.

### Глава 10. Настройка загрузчика

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Bootloader>

Устанавливается `sys-boot/grub`; для UEFI дополнительно `sys-boot/efibootmgr`.

```text
UEFI: grub-install --target=x86_64-efi --efi-directory=/efi \
                    --bootloader-id=Gentoo --recheck
BIOS: grub-install --target=i386-pc --recheck /dev/sdX
```

`/etc/default/grub` содержит `GRUB_DISTRIBUTOR="Gentoo"`, таймаут 5 секунд,
`GRUB_DISABLE_OS_PROBER=true` и только дополнительные параметры ядра. Затем
выполняется `grub-mkconfig -o /boot/grub/grub.cfg`.

Проверка требует непустой `grub.cfg`, наличие `menuentry`, аргумент `root=` и
для UEFI — файл `grubx64.efi` в ESP. Если `root=` не найден, этап считается
неуспешным.

**Отличия:** другие загрузчики и автоматический dual boot не поддерживаются.
`os-prober` отключён.

### Графическое окружение (вне core Handbook)

**Руководства Gentoo:** [Xfce](https://wiki.gentoo.org/wiki/Xfce),
[GNOME](https://wiki.gentoo.org/wiki/GNOME),
[Xorg](https://wiki.gentoo.org/wiki/Xorg).

Этап выполняется после установки GRUB и до финализации. При `DESKTOP=none` он
сразу отмечается завершённым и не требует сети.

| Выбор | Пакеты | Дисплей-менеджер | Службы OpenRC | systemd |
|---|---|---|---|---|
| `xfce` | Xorg, `sys-apps/dbus`, `xfce-base/xfce4-meta`, `x11-misc/lightdm`, `x11-misc/lightdm-gtk-greeter`, `sys-auth/elogind` (OpenRC) | LightDM | `dbus` (default), `elogind` (boot), `display-manager` (default) | `lightdm.service`, `graphical.target` |
| `gnome` | Xorg, `sys-apps/dbus`, `gnome-base/gnome`, `gnome-base/gdm`, `sys-auth/elogind` (OpenRC) | GDM | `dbus` (default), `elogind` (boot), `display-manager` (default) | `gdm.service`, `graphical.target` |

Для OpenRC установщик пишет `/etc/conf.d/display-manager` с
`DISPLAYMANAGER="lightdm"` или `DISPLAYMANAGER="gdm"`. Служба
`display-manager` приходит из `gui-libs/display-manager-init`, которую
подтягивает `xorg-server` в OpenRC-профиле. Для systemd включается
соответствующий unit и графическая цель загрузки.

Профиль Portage подбирается до этапа Portage: XFCE использует `desktop`, GNOME —
`gnome`. При выборе графики Stage3 автоматически становится `desktop-openrc`
или `desktop-systemd`. Это важно для GDM: ему нужен `elogind` или `systemd`, а
GNOME-профиль включает нужные USE-флаги. Если пользователь явно выбрал `kde` или `hardened`,
установщик не перезаписывает профиль. Для OpenRC-графики в `USE` добавляется
`elogind`: LightDM и GDM имеют `REQUIRED_USE="^^ ( elogind systemd )"`, а
профиль `hardened` сам по себе его не включает.

`VIDEO_CARDS` определяется автоматически по видимому GPU и переносится в
`make.conf` на этапе Portage. На странице «Графика» значение можно выбрать из
списка (Intel, AMD, NVIDIA, VMware, QEMU QXL, virtio) или ввести вручную. Если
оно пусто, Xorg может работать только с базовым режимом без аппаратного
ускорения; установщик предупреждает об этом.

**Отличия:** поддерживаются только XFCE и GNOME. Установщик не настраивает
Wayland-сессии вручную, темы, автологин, несколько мониторов и параметры
клавиатуры внутри графической сессии. KDE-профиль Portage остаётся доступен,
но KDE Plasma установщик не устанавливает.

### Глава 11. Завершение установки

**Handbook:** <https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Finalizing>

Установщик выполняет `emerge --depclean`, `env-update`, удаляет скачанный
stage3 и временные файлы, снимает chroot-монтирования и размонтирует целевую
систему. Финальный экран показывает hostname, пользователя, загрузчик, ядро,
графическое окружение, часовой пояс, локаль и сеть. `depclean` запускается
после этапа графики, поэтому не удаляет её зависимости.

После этого нужно извлечь установочный носитель и выполнить `reboot`.

## Что не входит в Handbook-путь установщика

Следующие возможности Handbook не реализованы и требуют ручной настройки:

- шифрование корневого раздела (LUKS);
- LVM и RAID;
- Secure Boot и подпись ядра/GRUB;
- swap-файл;
- Btrfs subvolumes, снапшоты и сжатие;
- отдельные разделы `/var`, `/usr`, `/tmp`;
- несколько дисков в одной установке;
- автоматический dual boot;
- альтернативные загрузчики (systemd-boot, GRUB с другими целями и т. п.);
- KDE Plasma и другие графические окружения/оконные менеджеры;
- настройка автологина, тем, Wayland-композиторов и параметров Xorg.

Если нужен один из этих сценариев, используйте Handbook напрямую или добавьте
поддержку в установщик и покройте её тестами.
