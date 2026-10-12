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

* Optionally verify installed package file integrity with `qcheck`, reporting
  packages with changed or missing files while ignoring protected configuration
  paths.

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

1. Load `/etc/portage/glus.conf`, validate options and hooks, and build the ordered
   list of steps shared by planning and execution. Executing the plan acquires
   an instance lock and creates a persistent run log directory.

2. Sync Portage with `emaint -a sync`, unless synchronization is disabled.

3. Run optional sync hooks configured with `GLUS_BEFORE_SYNC` and
   `GLUS_AFTER_SYNC`.

4. Leave build-directory cleanup to Portage, which coordinates its own locks.
   Glus no longer deletes `/var/tmp/portage/*`: checking for processes cannot
   prevent a different build from starting during deletion. Automatically merge
   Portage configuration updates with `etc-update --automode -5 /etc/portage`.

5. Update Portage first.

6. Refresh development tools before and after package compilation: select the
   latest available binutils and GCC profiles, run `env-update`, and refresh
   Python wrappers with `eselect python update --python3` when the optional
   `eselect-python` module is installed. If it is absent, Glus skips the
   selector updates and continues; failures from an installed selector still
   stop the run.

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
    Perl maintenance is skipped in effective binary-only mode (`only`, or
    `autoonly` when binary packages are available), with the reason included
    in the final summary. Modes that allow source builds run `perl-cleaner --all`
    without forcing binary packages, passing the other options through
    `EMERGE_DEFAULT_OPTS` and preserving Portage's configured defaults.
    When `GLUS_QCHECK=true` or `--qcheck` is enabled, also run
    `qcheck -B -P -v` to verify installed package file integrity.

11. Optionally run `emerge --depclean`, clean old binary packages and distfiles
    with `eclean`, run compile hooks, reload systemd when required, and write a
    final summary. Optionally send that summary by email, Slack, or both.

# Run logs and summaries

`--color false` (or `GLUS_COLOR=false`) also exports `NOCOLOR=true` and
`NO_COLOR=1` to synchronization and build tools, keeping their output suitable
for plain-text logs and Healthchecks. `--color auto` does the same when output
is not a terminal.

Each execution creates a private directory under `/var/log/glus`, named
`run-<UTC timestamp>-<unique suffix>`. Override the parent directory with
`GLUS_LOG_DIR` or `--log-dir /absolute/path`. Failure to create logs stops the
run before maintenance begins.

* `summary.txt`: final status, exit code, total duration and each step's result.
* `steps.tsv`: step index, result, exit code, seconds and title. Remaining steps
  are marked skipped if a previous step fails or the run is interrupted.
* `command-<step>-*.log`: unique output file for each command, including retries.
  The accompanying `.meta` file records the command, duration and exit status;
  an interrupted command may retain `Status: running` without an exit entry.
* `commands.tsv`: exit code, log filename, seconds, step index, quoted command
  and short command label.
* `retries.log` and `notifications.log`: retry decisions and delivery results,
  when applicable.

Use `--quiet` (or `GLUS_QUIET=true`) when wrapping Glus with runitor: the final
summary includes each command's name, duration and exit code, while full command
output stays in the local logs. Failures show only the last 20 output lines.

Logs survive both failure and interruption. The summary is printed even with
`--quiet`. `GLUS_LOG_ROTATIONS` / `--log-rotations` defaults to **10 runs**,
including the current one; 0 disables the count limit. The oldest completed,
marked Glus run directories are removed first. Unfinished runs, symlinks and
unrelated directories are retained and do not count towards the limit.
`GLUS_LOG_RETENTION_DAYS` / `--log-retention-days` optionally expires runs by
age as well; it defaults to 0 (disabled). Set both limits to 0 to keep all runs.

`--plan` and `--debug` use the same ordered steps but do not acquire a lock,
create run logs, run maintenance commands or send notifications. Conditional
steps can depend on the current machine state; the basic-system fallback only
executes when the initial system update fails. `--pretend` executes Portage
checks and keeps logs, but sends no notifications.

# Retry and cancellation controls

| Option | Configuration | Default |
| --- | --- | --- |
| `--fetch-attempts` | `GLUS_FETCH_ATTEMPTS` | 3 total attempts |
| `--fetch-delay` | `GLUS_FETCH_DELAY` | 300 seconds |
| `--cancel-grace` | `GLUS_CANCEL_GRACE` | 10 seconds |

Only the download phase is retried. Invocation errors (exit 2), missing or
non-executable commands (126/127), signal exits and recognized invalid-argument
diagnostics stop immediately. Portage uses exit 1 for several different causes,
so unclassified exit-1 failures are retried up to the configured limit. Use
`--fetch-attempts 1` to disable retries or `--fetch-delay 0` to retry immediately.

Maintenance runs in a dedicated process group. On TERM, INT or HUP, Glus sends
TERM to the group, waits up to the grace period, then kills remaining members.
It preserves the logs and exits with 143, 130 or 129 respectively. Hooks should
run in the foreground and must not detach into their own session if they need
to participate in cancellation. The instance lock remains held during shutdown.
Maintenance is unattended: the worker receives closed interactive input
(`/dev/null`). Hooks and Portage options must not require terminal prompts.

# Email and Slack notifications

Configure either destination or both in `/etc/portage/glus.conf`:

```bash
GLUS_EMAIL="admin@example.com"
GLUS_SLACK_WEBHOOK="https://hooks.slack.com/services/T_EXAMPLE/B_EXAMPLE/REPLACE_ME"
GLUS_NOTIFY="failures"
```

`GLUS_NOTIFY` / `--notify` accepts `failures` (default), `always` or `never`.
Once an execution has started, one final summary is sent according to that
policy, including interrupted runs. Email now receives the final summary
instead of separate messages for individual command failures. Slack receives
the host, result, duration, step counts and the local log path; command output
is retained locally. A local path is not a downloadable link in Slack.

Create an [incoming webhook in Slack](https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/)
for the destination channel. Slack delivery requires `curl`. `--slack-webhook`
overrides the configured URL and `--no-slack` disables Slack for a single run.
Prefer the configuration file over the CLI for the secret URL; restrict the
configuration file's permissions. Glus does not print the URL or pass it in
curl's command-line arguments, and removes the configured webhook environment
variable before running package commands.

Delivery failures are recorded and warned about without changing the update's
exit status. Slack requests have a 10-second connection timeout and a 20-second
overall timeout, with no automatic resend to avoid duplicate messages after
ambiguous responses. No notifications are sent by `--plan`, `--debug` or
`--pretend`. The documented example is a placeholder, not a usable webhook.

```bash
glus.sh --plan --world --binary only
glus.sh --world --fetch-attempts 2 --fetch-delay 60 --notify always
glus.sh --security --no-slack
```

For a targeted update, use `glus.sh --packages-only dev-lang/rust-bin`.
This mode only fetches and updates the selected packages and any dependencies
Portage requires. It skips synchronization, the automatic Portage update,
toolchain selection, hooks, Perl maintenance, rebuilds and cleanup, even when
those are enabled in the configuration. Locks, retries, logs and notifications
remain active. Preview the exact scope with `--plan` or `--pretend`.
It cannot be combined with `--system`, `--world` or `--full`.


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
  
* **qcheck** (app-portage/portage-utils)

  Optionally verifies the integrity of installed package files when
  `GLUS_QCHECK` or `--qcheck` is enabled.


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

     --[no-]qcheck, ${GLUS_QCHECK}
        Verify installed package integrity with qcheck.
        (default: false)

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

* Run the regular checks and verify installed package file integrity with qcheck

```
glus.sh --qcheck
```
