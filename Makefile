#!/usr/bin/make -f

SHELL := /bin/sh

DESTDIR ?=
prefix ?= /usr

exec_prefix ?= $(prefix)
sbindir ?= $(exec_prefix)/sbin
sysconfdir ?= /etc
gentoodir ?= $(sysconfdir)/portage

INSTALL ?= install

INSTALL_PROGRAM ?= $(INSTALL)
INSTALL_DATA ?= $(INSTALL) -m 644

install:
	mkdir -p '$(DESTDIR)$(sbindir)' '$(DESTDIR)$(gentoodir)'
	$(INSTALL_PROGRAM) ./glus.sh '$(DESTDIR)$(sbindir)'/glus.sh
	$(INSTALL_DATA) ./glus.conf '$(DESTDIR)$(gentoodir)'/glus.conf

uninstall:
	rm -f '$(DESTDIR)$(sbindir)'/glus.sh
	rm -f '$(DESTDIR)$(gentoodir)'/glus.conf
