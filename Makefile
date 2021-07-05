#!/usr/bin/make -f

SHELL := /bin/sh

DESTDIR ?=/usr/local

exec_prefix ?= $(DESTDIR)
sbindir ?= $(exec_prefix)/sbin
gentoodir ?= $(DESTDIR)/etc/portage/

INSTALL ?= install

INSTALL_PROGRAM ?= $(INSTALL)
INSTALL_DATA ?= $(INSTALL) -m 644

install:
	mkdir -p '$(sbindir)' '$(gentoodir)'
	$(INSTALL_PROGRAM) ./glus.sh '$(sbindir)'/glus.sh
	$(INSTALL_PROGRAM) ./glus.conf '$(gentoodir)'glus.conf

uninstall:
	rm -f '$(sbindir)'/glus.sh
	rm -f '$(gentoodir)'glus.conf
