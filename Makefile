# Gentoo TUI Installer build and packaging helpers.
# The installer has no build step; targets validate, test and install it.

SHELL := /bin/bash
NAME := gentoo-tui-installer
VERSION := $(shell cat VERSION)
TAG := v$(VERSION)

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/sbin
LIBDIR ?= $(PREFIX)/lib/gentoo-installer
DOCDIR ?= $(PREFIX)/share/doc/gentoo-installer
DESTDIR ?=
DISTDIR ?= dist

SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?= -x -S warning -e SC2034

SHELL_FILES := gentoo-installer lib/*.sh scripts/*.sh tests/*.sh tests/unit/*.sh

.PHONY: all help syntax lint test check install uninstall dist clean

.DEFAULT_GOAL := help

all: check

help:
	@printf '%s %s\n\n' '$(NAME)' '$(VERSION)'
	@printf 'Targets:\n'
	@printf '  make check      syntax, ShellCheck and unit tests\n'
	@printf '  make test       unit tests only\n'
	@printf '  make lint       ShellCheck only\n'
	@printf '  make install    install under $(PREFIX) (DESTDIR supported)\n'
	@printf '  make uninstall  remove installed files\n'
	@printf '  make dist       release tarball and SHA256 for tag $(TAG)\n'
	@printf '  make clean      remove generated release archives\n'

syntax:
	@printf '== syntax\n'
	@bash -n $(SHELL_FILES)

lint:
	@printf '== shellcheck\n'
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { \
		printf 'shellcheck not found; install dev-util/shellcheck or set SHELLCHECK=path\n' >&2; \
		exit 1; \
	}
	@$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SHELL_FILES)

test:
	@bash tests/run.sh

check: syntax lint test

install:
	@test -n '$(LIBDIR)' || { printf 'LIBDIR must not be empty\n' >&2; exit 1; }
	install -d '$(DESTDIR)$(LIBDIR)/lib' '$(DESTDIR)$(LIBDIR)/lib/lang' '$(DESTDIR)$(LIBDIR)/conf'
	install -d '$(DESTDIR)$(BINDIR)' '$(DESTDIR)$(DOCDIR)'
	install -m 0755 gentoo-installer '$(DESTDIR)$(LIBDIR)/gentoo-installer'
	install -m 0644 VERSION '$(DESTDIR)$(LIBDIR)/VERSION'
	install -m 0644 lib/*.sh '$(DESTDIR)$(LIBDIR)/lib/'
	install -m 0644 lib/lang/*.tsv '$(DESTDIR)$(LIBDIR)/lib/lang/'
	install -m 0644 conf/installer.conf.example '$(DESTDIR)$(LIBDIR)/conf/'
	install -m 0644 README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md LICENSE \
		'$(DESTDIR)$(DOCDIR)/'
	install -m 0644 docs/*.md '$(DESTDIR)$(DOCDIR)/'
	install -m 0644 conf/installer.conf.example '$(DESTDIR)$(DOCDIR)/installer.conf.example'
	ln -sfn '$(LIBDIR)/gentoo-installer' '$(DESTDIR)$(BINDIR)/gentoo-installer'
	@printf 'Installed %s %s to %s\n' '$(NAME)' '$(VERSION)' '$(DESTDIR)$(LIBDIR)'
	@printf 'Run: %s\n' '$(BINDIR)/gentoo-installer'

uninstall:
	@case '$(LIBDIR)' in \
		*/gentoo-installer) ;; \
		*) printf 'refusing to remove unexpected LIBDIR: %s\n' '$(LIBDIR)' >&2; exit 1 ;; \
	esac
	rm -f '$(DESTDIR)$(BINDIR)/gentoo-installer'
	rm -rf '$(DESTDIR)$(LIBDIR)' '$(DESTDIR)$(DOCDIR)'

dist: check
	@test -f scripts/release.sh || { printf 'scripts/release.sh missing\n' >&2; exit 1; }
	@DIST_DIR='$(abspath $(DISTDIR))' ./scripts/release.sh

clean:
	rm -rf '$(DISTDIR)'
