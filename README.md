# Glus
Gentoo Linux update system

 Keep your gentoo linux up to date, update security problems daily and check that it is correct.

# Prerequisites

* perl-cleaner (app-admin/perl-cleaner)
  Find & rebuild packages and Perl header files broken due to a perl upgrade.
  
* revdep-rebuild (app-portage/gentoolkit)
  Scans libraries and binaries for missing shared library dependencies and attempts to fix 
  them by re-emerging those broken binaries and shared libraries. 
  It is useful when an upgraded package breaks other software packages that are dependent
  upon the upgraded package.
  
* mailx (virtual/mta)
  Send mail for alerts and notifications.

# Git Installation

The latest available version can also be installed manually by running the following commands:

```sh
curl -o /usr/sbin/glus.sh 'https://raw.githubusercontent.com/inode64/glus/main/glus.sh' \
  && chown 0:0 /usr/sbin/glus.sh \
  && chmod 755 /usr/sbin/glus.sh
curl -o /etc/portage/glus.conf 'https://raw.githubusercontent.com/inode64/glus/main/glus.conf'
```
# Help

```
  PORTAGE OPTIONS:
     -S, --[no-]sync, ${GLUS_SYNC}
        Sync portage.
        (default: true)

     -e, --exclude <EXCLUDE>, ${GLUS_EXCLUDE}
        Exclude packages.
        (default: "")

     -P --[no-]pretend, ${GLUS_PRETEND}
        Instead of actually performing the merge, simply display what *would* have been installed if --pretend weren't used.
        (default: "false")

     -c --[no-]check, ${GLUS_CHECK}
        Check the system.
        (default: true)

     -C --[no-]clean, ${GLUS_CLEAN}
        Clean packages and source files after compile.
        (default: false)

     -f, --[no-]fetch, ${GLUS_FETCH}
        Only download, no compile or install.
        (default: false)

     -b, --binary <auto|autoonly|true|false|only>, ${GLUS_BINARY}
        Use binary packages for true or auto.
        Force use only binary packages for only option selected.
        (default: false)


  SETS:
     -p --packages <PACKAGES>, ${GLUS_PACKAGES}
        Add this packages for update.
        (default: "")

     -g --[no-]go, ${GLUS_GO}
        Add go lang packages for update.
        (default: false)

     -m --[no-]modules, ${GLUS_MODULES}
        Add kernel modules for update.
        (default: false)

     -l --[no-]live, ${GLUS_LIVE}
        Add live packages for update. (force compile)
        (default: false)

     -s --[no-]security, ${GLUS_SECURITY}
        Compile security relevant packages (daily process, for example).
        (default: true)


  ACTIONS:
     --[no-]system
        Compile only system core (weekly process, for example).
        (default: false)

     --world
        Compile only system core (monthly process, for example).

     --full
        Recompile the entire system (annual process, for example).


    MISC OPTIONS:
     --[no-]debug, ${GLUS_DEBUG}
        Show the commands to run.
        (default: false)

     -q, --[no-]quiet, ${GLUS_QUIET}
        Suppress non-error messages.
        (default: false)

     -x, --color <auto|true|false>, ${GLUS_COLOR}
        Colorize the output.
        (default: true)

     --email <email> ${GLUS_EMAIL}
        Send mail for alerts and notifications.
        (default: "")

     -v, --version
        Show version number and quit.

     -h, --help
        Show this help and quit.
```

# Usage

The default behavior of Glus can be adjusted with multiple options. Use the --help option for the full list.
It by default Glus sync the portage and update the security packages with
```
glus.sh
```

* Update security, kernel modules and live packages

```
glus.sh --security --modules --live
```

* Update security packages and system

```
glus.sh --system
```

* Update world

```
glus.sh --world
```

* Update empty tree world and debug 

```
glus.sh --world --debug
```