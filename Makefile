#!/usr/bin/make -f

SHELL := /bin/sh

DESTDIR ?=

prefix ?= /usr/local
exec_prefix ?= $(prefix)
sbindir ?= $(exec_prefix)/sbin
gentoodir ?= $(prefix)/etc/portage/

INSTALL ?= install

INSTALL_PROGRAM ?= $(INSTALL)
INSTALL_DATA ?= $(INSTALL) -m 644

install:
	mkdir -p '$(exec_prefix)$(sbindir)' '$(DESTDIR)$(gentoodir)'
	$(INSTALL_PROGRAM) ./glus.sh '$(exec_prefix)$(sbindir)'/glus.sh
	$(INSTALL_PROGRAM) ./glus.conf '$(DESTDIR)$(gentoodir)'glus.conf

uninstall:
	rm -f '$(exec_prefix)$(sbindir)'/glus.sh
	rm -f '$(DESTDIR)$(gentoodir)'glus.conf
