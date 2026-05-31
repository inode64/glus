# Glus
Gentoo Linux update system

Glus is a maintenance script for Gentoo Linux systems. It keeps Portage and
selected package sets up to date, rebuilds packages affected by toolchain,
Perl, Python, or shared-library changes, and optionally removes obsolete
packages and downloaded source archives.

It is intended for periodic system maintenance, from small daily security
updates to larger system, world, or full rebuild runs. The script can also show
the planned operations with `--plan`, run Portage in pretend mode with
`--pretend`, and print commands without executing them with `--debug`.


# Features

* Unify the regular Gentoo maintenance workflow: sync Portage, update Portage
  itself, update selected package sets, rebuild affected packages, and clean old
  packages or source files when requested.
  
* Use the executable `emerge` wrapper found under
  `/usr/lib/python-exec/python*/emerge`. This helps when the regular `emerge`
  command is temporarily broken during Python upgrades or when the system is
  between two Python versions.

* Update the active binutils and GCC configuration before compiling packages so
  newly built binaries use the latest available development toolchain.

* Check and repair packages with missing shared-library dependencies using
  `revdep-rebuild`.

* Rebuild Perl packages and headers affected by Perl upgrades using
  `perl-cleaner`.

* Rebuild preserved packages, repair Portage merge metadata, and check the
  world file with `emaint`.

* Support binary package modes, package exclusions, live package rebuilds,
  kernel module rebuilds, Go package rebuilds, hooks, quiet output, colored
  output, error email notifications, and dry-run planning.


# How it works

Glus performs the update in a conservative order so that the package manager and
the base build toolchain are refreshed before larger package updates are
attempted:

1. Load `/etc/portage/glus.conf`, validate command-line options and configured
   hooks, and acquire a lock so only one Glus instance runs at a time.

2. Sync Portage with `emaint -a sync`, unless synchronization is disabled.

3. Run optional sync hooks configured with `GLUS_BEFORE_SYNC` and
   `GLUS_AFTER_SYNC`.

4. Clean temporary Portage build files from `/var/tmp/portage` when it is safe
   to do so, and automatically merge safe Portage configuration updates with
   `etc-update --automode -5 /etc/portage`.

5. Update Portage first.

6. Refresh development tools before and after package compilation: select the
   latest available binutils and GCC profiles, run `env-update`, and refresh
   Python wrappers with `eselect python update --python3`.

7. Resolve `emerge` through the Python exec wrappers in
   `/usr/lib/python-exec/python*/emerge`, which can recover from situations
   where the default `emerge` command is not usable during Python transitions.

8. Fetch required package sources before compiling, retrying downloads before
   giving up.

9. Update the requested target: security packages, explicit packages, live
   packages, Go packages, kernel modules, the base system, world, or a full
   empty-tree world rebuild.

10. Rebuild preserved packages, rebuild Perl packages, and run `revdep-rebuild`
    to find and repair binaries linked against missing or updated libraries.

11. Optionally run `emerge --depclean`, clean old binary packages and distfiles
    with `eclean`, run compile hooks, reload systemd when required, and send an
    email with the last command output when a command fails.


# Prerequisites

* **flock** (sys-apps/util-linux)

  Prevents multiple Glus instances from running at the same time.

* **perl-cleaner** (app-admin/perl-cleaner)
  
  Find & rebuild packages and Perl header files broken due to a perl upgrade.

  
* **revdep-rebuild** (app-portage/gentoolkit)
  
  Scans libraries and binaries for missing shared library dependencies and attempts to fix 
  them by re-emerging those broken binaries and shared libraries. 
  It is useful when an upgraded package breaks other software packages that are dependent
  upon the upgraded package.
  

* **mailx** (virtual/mta)
  
  Send mail for alerts and notifications when `GLUS_EMAIL` or `--email` is
  configured.

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

     -b, --binary <auto|autoonly|true|false|only>, --no-binary, ${GLUS_BINARY}
        Use binary packages.
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

     --dry-run, --plan
        Show the planned steps and commands without executing them.
        Shows commands like --debug and disables --quiet.


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
By default, Glus sync the portage and update the security packages with:
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
glus.sh --full --debug
```

* Show the update plan without executing commands

```
glus.sh --plan
```
