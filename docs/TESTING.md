# Тестирование

## Что проверяется автоматически

```bash
make check     # синтаксис + ShellCheck + unit-тесты
make test      # только unit-тесты
make lint      # только ShellCheck
```

`make check` не требует root, не использует `sudo`, не трогает блочные
устройства и не пишет в `/var/lib`. Все пути подменяются через `GI_*`.

### Unit-тесты

| Файл | Что покрывает |
|---|---|
| `tests/unit/test_core.sh` | `human_mib`, пути разделов, `shell_quote`, `render_cmd`, `config_derived`, автоматический desktop Stage3, roundtrip конфигурации, комментарии и ошибки парсера, state, `make_jobs_suggestion`, определение `VIDEO_CARDS` для Intel/AMD/NVIDIA/VMware/QEMU/virtio. |
| `tests/unit/test_validate.sh` | hostname, username, timezone, locale, URL, MiB, диапазоны, USE, CFLAGS, kernel cmdline, bool и нефатальные предупреждения о противоречиях конфигурации. |
| `tests/unit/test_disks.sh` | UEFI/BIOS-планы, swap и `/home`, отсутствие перекрытий, минимальный размер, BIOS > 2 TiB, NVMe-имена, `parted`-типы ФС, fallback-определение размера virtio-диска через `blockdev`/`lsblk`/sysfs. |
| `tests/unit/test_kernel.sh` | удаление `root=`, `/etc/kernel/cmdline`, dracut config, `/etc/default/grub`, quoting одинарных кавычек. |
| `tests/unit/test_ui.sh` | progress bar, перенос текста, валидатор целых чисел, панель действий `<Back>`/`<Next>`/`<Save>`/`<Help>`/`<Exit>`, сводка, декодирование стрелок/F1/F2/F10/Ctrl-S, серии стрелок и неизвестные escape-последовательности, маркеры `[ ]`/`[*]`/`( )`/`(*)`, окна выбора, модальное подтверждение, `ui_page_run` и отсутствие ожидания в unattended-режиме. |
| `tests/unit/test_wizard.sh` | изоляция stdout в `wizard_bool`, очистка `UI_RESULT`/`UI_SECRET` после ввода пароля, сводка на английском и русском, отсутствие паролей в `install.conf`, пустой `KERNEL_MODE` по умолчанию, явный выбор ядра, требования к паролям, отсутствие секретов в тексте проверки, единственная настройка sudo и предупреждения в финальном подтверждении. |
| `tests/unit/test_i18n.sh` | структура `ru.tsv`, перевод статических и printf-строк, сохранение подстановок, выбор/generation locale, первый выбор языка, панель действий и сводка. |
| `tests/unit/test_desktop.sh` | списки пакетов XFCE/GNOME, LightDM/GDM, OpenRC-службы и `/etc/conf.d/display-manager`, systemd-цель, группы пользователя, проверка установки, сетевое требование для незавершённого desktop-этапа и пропуск desktop-этапа при `DESKTOP=none`. |
| `tests/unit/test_config_example.sh` | все ключи `CONFIG_KEYS` присутствуют, нет дубликатов и паролей, пример загружается и даёт ожидаемые значения. |

На момент 1.4.0 выполняется 445 assertions в 9 файлах. Число может меняться;
важен нулевой код возврата, а не точное количество.

### Harness

`tests/harness.sh` предоставляет:

- `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`;
- `assert_ok` — команда должна вернуть 0;
- `assert_fail` — команда должна вернуть non-zero в текущем shell;
- `assert_fail_isolated` — то же в subshell, для функций, которые вызывают
  `die` и завершают shell;
- `finish_tests` — печатает итог и завершает тест.

`tests/run.sh` создаёт временный корень, экспортирует `GI_TEST_ROOT`,
`GI_TEST_TMP`, `GI_WORKDIR`, `GI_CONFIG_FILE`, `GI_STATE_FILE`, `GI_LOG_FILE` и
запускает каждый `tests/unit/test_*.sh` отдельным процессом. Упавший файл не
останавливает остальные.

## Статические проверки

```bash
bash -n gentoo-installer lib/*.sh scripts/*.sh tests/*.sh tests/unit/*.sh

shellcheck -x -S warning -e SC2034 \
  gentoo-installer lib/*.sh scripts/*.sh tests/*.sh tests/unit/*.sh
```

`SC2034` отключён осознанно: часть переменных используется косвенно через
`printf -v`, `${!var}` и общий state. Остальные warning-level замечания должны
быть устранены. Если ShellCheck не установлен:

```bash
# Gentoo
emerge --ask dev-util/shellcheck

# Debian/Ubuntu
sudo apt-get install shellcheck
```

## CI

`.github/workflows/ci.yml` выполняет на `ubuntu-latest`:

1. `actions/checkout`;
2. установку ShellCheck;
3. `bash -n`;
4. ShellCheck;
5. `bash tests/run.sh`;
6. проверку формата `VERSION`.

На тег `v*` дополнительный job собирает release-архив через `make dist` и
публикует `.tar.gz` и `.sha256` как artifact. CI не запускает установку на
реальном диске.

## Ручная проверка в виртуальной машине

В версии 1.4.0 **нет автоматического интеграционного теста с реальной
разметкой и загрузкой**. Перед использованием на физическом компьютере
обязательно пройдите сценарий в VM.

Для проверки KVM/QEMU используйте virtio-диск (`if=virtio`): установщик должен
показать `/dev/vda` и его реальный размер, а не `0 MiB`. Дополнительно выберите
русский язык в первом меню и убедитесь, что кириллица отображается без
транслита, а нижняя панель и сводка остаются читаемыми.

### Подготовка

```bash
qemu-img create -f qcow2 gentoo-test.qcow2 30G
```

BIOS:

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 \
  -drive file=gentoo-test.qcow2,if=virtio,format=qcow2 \
  -cdrom gentoo-minimal.iso -boot order=d
```

UEFI (путь к OVMF зависит от дистрибутива; `OVMF_VARS.fd` — записываемая копия
шаблона):

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=gentoo-test.qcow2,if=virtio,format=qcow2 \
  -cdrom gentoo-minimal.iso -boot order=d
```

Скопируйте проект в live-систему, настройте сеть и запустите
`./gentoo-installer`. Для ускорения используйте `gentoo-kernel-bin` и
`STAGE_FLAVOR=openrc`, `ROOT_FS=ext4`.

### Матрица сценариев

Минимум:

- [ ] UEFI + GPT, OpenRC, `gentoo-kernel-bin`, ext4, auto swap, без `/home`.
- [ ] BIOS + MBR, OpenRC, `gentoo-kernel-bin`, xfs, swap custom, `/home`.
- [ ] UEFI + GPT, systemd, `gentoo-kernel`, btrfs, без swap.
- [ ] UEFI + GPT, OpenRC, `gentoo-sources` + `menuconfig`, ext4.
- [ ] UEFI + GPT, OpenRC, XFCE + LightDM, `VIDEO_CARDS` заданы.
- [ ] UEFI + GPT, systemd, GNOME + GDM, `VIDEO_CARDS` заданы.
- [ ] `DESKTOP=none`: этап графики пропускается, система загружается в консоль.
- [ ] Ручная схема: существующие ESP/root/`/home`, `FORMAT_ESP=no`,
      `FORMAT_HOME=no`.
- [ ] Прерывание после `stage3` и продолжение через `--resume`.
- [ ] Прерывание во время Portage и повтор команды через `R`.
- [ ] Неверная дата и отсутствие сети: preflight должен блокировать старт.
- [ ] `--yes`: destructive-подтверждение пропускается, пароли всё равно
      запрашиваются.
- [ ] Сброс состояния из меню и повторная установка.

Опционально:

- [ ] Каждый вариант stage3 (`openrc`, `systemd`, `desktop-*`).
- [ ] XFCE на systemd и GNOME на OpenRC (проверка профилей и служб).
- [ ] Смена `DESKTOP` после Portage: предупреждение мастера и работу с текущим
      профилем.
- [ ] XFS/ext4/Btrfs для root и `/home` в разных комбинациях.
- [ ] `NETWORK=networkmanager`, `SSH=yes`, `SUDO=no`, `CREATE_USER=no`.
- [ ] Микрокод Intel и AMD на соответствующем CPU.
- [ ] Диск > 2 TiB в BIOS (должен быть отклонён) и в UEFI (должен быть принят).
- [ ] Терминал 40×15 и 100×30; отсутствие цветов при `NO_COLOR=1`.

### Что проверить после установки

- Система загружается без установочного носителя.
- В `grub.cfg` ровно один `root=UUID=...` на пункт загрузки.
- `findmnt` показывает `/`, `/efi` или `/boot`, `/home` при наличии.
- `fstab` использует UUID и не содержит несуществующих устройств.
- `passwd -S root` и `passwd -S <user>` показывают установленный пароль.
- Пользователь входит и имеет ожидаемые группы (`wheel`, `audio`, `video`).
- Работают выбранные службы: `rc-status` или `systemctl status`.
- При `DESKTOP=xfce` запускается LightDM (`DISPLAYMANAGER="lightdm"`), входит
  пользователь и стартует сеанс XFCE.
- При `DESKTOP=gnome` запускается GDM, входит пользователь и стартует сеанс
  GNOME; для OpenRC работает `elogind`, для systemd — `graphical.target`.
- `locale`, `timedatectl`/`hwclock`, `hostnamectl`/`hostname` корректны.
- В журналах установщика нет паролей и секретов.
- `emerge --info` использует выбранный профиль, CFLAGS, USE и `CPU_FLAGS_X86`.
- `depclean` не удалил нужные пакеты; система перезагружается повторно.

### Проверка отсутствия секретов

Пароли не должны встречаться в:

```text
/var/lib/gentoo-installer/install.conf
/var/lib/gentoo-installer/state
/var/lib/gentoo-installer/logs/
```

Поиск по конкретному тестовому паролю:

```bash
grep -R --fixed-strings 'ваш-тестовый-пароль' /var/lib/gentoo-installer || echo 'не найдено'
```

Команда `chpasswd` в журнале должна быть без stdin. Если пароль найден — это
дефект безопасности.

## Добавление тестов

1. Создайте `tests/unit/test_<область>.sh` с `set -Eeuo pipefail`.
2. Подключите `tests/harness.sh` и только нужные модули.
3. Используйте временные пути из `GI_TEST_TMP`/`GI_WORKDIR`.
4. Не вызывайте `parted`, `mkfs`, `mount`, `emerge`, `chroot` и другие
   destructive-команды.
5. Для функций с `die` используйте `assert_fail_isolated`.
6. Завершите файл `finish_tests`.
7. Запустите `bash tests/run.sh` и `make check`.

Тест должен быть детерминированным, не зависеть от наличия `/dev/sda`, сети или
root и не оставлять файлы вне временного каталога.
