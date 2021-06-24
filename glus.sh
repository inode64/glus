#!/bin/bash

# Version:    1.0.0
# Author:     Francisco Javier Félix Belmonte <ffelix@inode64.com>
# License:    MIT, https://opensource.org/licenses/MIT
# Repository: https://github.com/inode64/glus

# TODO: Use different forms to send mail (https://linuxhint.com/bash_script_send_email)

export LC_ALL='C'

# Define system configuration file.
if [ -z "${ETCDIR+x}" ]; then ETCDIR='/etc'; fi
sysConfFile="${ETCDIR?}/portage/glus.conf"

declare -r ETCDIR
declare -r sysConfFile

LOGS=$(mktemp -d)
declare -r LOGS

# Remove temporary files on exit.
cleanup() { ret="$?"; rm -rf "${LOGS}"; trap - EXIT; exit "${ret:?}"; }
{ trap cleanup EXIT ||:; trap cleanup TERM ||:; trap cleanup INT ||:; trap cleanup HUP ||:; } 2>/dev/null

errors=0

# Remove Unnecessary files in /var/tmp/portage
clean_portage_dir() {
  if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
    return
  fi

  # shellcheck disable=SC2046
  if [ $(pgrep -c emerge) -eq 0 ]; then
    rm -rf /var/tmp/portage/* 2>/dev/null
  fi
}

secs_to_human() {
  local result

  ((result = $(date +%s) - ${1}))

  echo "Process time: $((result / 3600))h $(((result / 60) % 60))m $((result % 60))s"
}

LastBinutils() {
  if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
    return
  fi

  local last

  last=$(/usr/bin/binutils-config -l 2>/dev/null | wc | awk '{print $1}')

  /usr/bin/binutils-config -C "${last}"
  /usr/sbin/env-update 2>/dev/null

  . /etc/profile

  return "${last}"
}

LastGCC() {
  if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
    return
  fi

  local last

  last=$(/usr/bin/gcc-config -l 2>/dev/null | wc | awk '{print $1}')

  /usr/bin/gcc-config -C "${last}"
  /usr/sbin/env-update 2>/dev/null

  . /etc/profile

  return "${last}"
}

UpdateDevel() {
  if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
    return
  fi

  etc-update -p

  LastBinutils
  LastGCC

  # We update 2 times in case the new python does not exist yet
  eselect python update --python3
  etc-update --automode -5 /etc/python-exec
  eselect python update --python3
}

# Parse command line options.
optParse() {
  while [ "${#}" -gt '0' ]; do
    case "${1?}" in
    # Short options that accept an argument need a "*" in their pattern because they can be
    # found in the "-A<value>" form.
    '-S' | '--sync' | '--no-sync')
      optArgBool "${@-}"
      sync="${optArg:?}"
      ;;
    '-e' | '--exclude')
      optArgStr "${@-}"
      exclude="${optArg:?}"
      ;;
    '-p' | '--packages')
      optArgStr "${@-}"
      packages="${optArg:?}"
      ;;
    '-P' | '--pretend' | '--no-pretend')
      optArgBool "${@-}"
      pretend="${optArg:?}"
      ;;
    '-c' | '--check' | '--no-check')
      optArgBool "${@-}"
      check="${optArg:?}"
      ;;
    '-C' | '--clean' | '--no-clean')
      optArgBool "${@-}"
      clean="${optArg:?}"
      ;;
    '-g' | '--go' | '--no-go')
      optArgBool "${@-}"
      go="${optArg:?}"
      ;;
    '-m' | '--modules' | '--no-modules')
      optArgBool "${@-}"
      modules="${optArg:?}"
      ;;
    '-l' | '--live' | '--no-live')
      optArgBool "${@-}"
      live="${optArg:?}"
      ;;
    '-s' | '--security' | '--no-security')
      optArgBool "${@-}"
      security="${optArg:?}"
      ;;
    '--system' | '--no-system')
      optArgBool "${@-}"
      system="${optArg:?}"
      ;;
    '--world')
      optArgBool "${@-}"
      world="${optArg:?}"
      ;;
    '--full')
      optArgBool "${@-}"
      full="${optArg:?}"
      ;;
    '-f' | '--fetch' | '--no-fetch')
      optArgBool "${@-}"
      fetch="${optArg:?}"
      ;;
    '--debug')
      optArgBool "${@-}"
      debug="${optArg:?}"
      ;;
    '-b' | '--binary' | '--no-binary')
      optArgStr "${@-}"
      binary="${optArg:?}"
      ;;
    '-x'* | '--color')
      optArgStr "${@-}"
      color="${optArg?}"
      shift "${optShift:?}"
      ;;
    '-email')
      optArgStr "${@-}"
      email="${optArg:?}"
      ;;
    '-v' | '--version') showVersion ;;
    '-h' | '--help') showHelp ;;
    # If "--" is found, the remaining positional arguments are saved and the parsing ends.
    --)
      shift
      posArgs="${posArgs-} ${*-}"
      break
      ;;
    # If a long option in the form "--opt=value" is found, it is split into "--opt" and "value".
    --*=*)
      optSplitEquals "${@-}"
      shift
      set -- "${optName:?}" "${optArg?}" "${@-}"
      continue
      ;;
    # If an option did not match any pattern, an error is thrown.
    -? | --*) optDie "Illegal option ${1:?}" ;;
    # If multiple short options in the form "-AB" are found, they are split into "-A" and "-B".
    -?*)
      optSplitShort "${@-}"
      shift
      set -- "${optAName:?}" "${optBName:?}" "${@-}"
      continue
      ;;
    # If a positional argument is found, it is saved.
    *) posArgs="${posArgs-} ${1?}" ;;
    esac
    shift
  done
}

optSplitShort() {
  optAName="${1%"${1#??}"}"
  optBName="-${1#??}"
}

optSplitEquals() {
  optName="${1%="${1#--*=}"}"
  optArg="${1#--*=}"
}

optArgStr() {
  if [ -n "${1#??}" ] && [ "${1#--}" = "${1:?}" ]; then
    optArg="${1#??}"
    optShift='0'
  elif [ -n "${2+x}" ]; then
    optArg="${2-}"
    optShift='1'
  else optDie "No argument for ${1:?} option"; fi
}

optArgBool() {
  if [ "${1#--no-}" = "${1:?}" ]; then
    optArg='true'
  else optArg='false'; fi
}

optDie() {
  printf '%s\n' "${@-}" "Try 'glus --help' for more information" >&2
  exit 2
}

# Show help and quit.
showHelp() {
  printf '%s\n' "$(
    sed -e 's/%NL/\n/g' <<-EOF
	  Gentoo Linux update system%NL
	  Usage: glus [--full|--world] [OPTION]...
	  Keep your gentoo linux up to date, update security problems daily
	  and check that it is correct.%NL
	  Options:
     -S, --[no-]sync, \${GLUS_SYNC}
        Sync portage.
        (default: ${sync})%NL
     -e, --exclude <EXCLUDE>, \${GLUS_EXCLUDE}
        Exclude packages.
        (default: "${exclude}")%NL
     -p --packages <PACKAGES>, \${GLUS_PACKAGES}
        Add this packages for update.
        (default: "${packages}")%NL
     -P --[no-]pretend, \${GLUS_PRETEND}
        Instead of actually performing the merge, simply display what *would* have been installed if --pretend weren't used.
        (default: "${pretend}")%NL
     -c --[no-]check, \${GLUS_CHECK}
        Check the system.
        (default: ${check?})%NL
     -C --[no-]clean, \${GLUS_CLEAN}
        Clean packages and source files after compile.
        (default: ${clean?})%NL
     --[no-]debug, \${GLUS_DEBUG}
        Show the commands to run.
        (default: ${debug?})%NL
     -f, --[no-]fetch, \${GLUS_FETCH}
        Only download, no compile or install.
        (default: ${fetch?})%NL
     -q, --[no-]quiet, \${GLUS_QUIET}
        Suppress non-error messages.
        (default: ${quiet?})%NL
     -b, --binary <auto|autoonly|true|false|only>, \${GLUS_BINARY}
        Use binary packages for true or auto.
        Force use only binary packages for only option selected.
        (default: ${binary?})%NL
     -x, --color <auto|true|false>, \${GLUS_COLOR}
        Colorize the output.
        (default: ${color?})%NL
     --email <email> \${GLUS_EMAIL}
        Send mail for alerts and notifications.
        (default: "${email?}")%NL
     -v, --version
        Show version number and quit.%NL
     -h, --help
        Show this help and quit.%NL

	  SETS
     -g --[no-]go, \${GLUS_GO}
        Add go lang packages for update.
        (default: ${go?})%NL
     -m --[no-]modules, \${GLUS_MODULES}
        Add kernel modules for update.
        (default: ${modules?})%NL
     -l --[no-]live, \${GLUS_LIVE}
        Add live packages for update. (force compile)
        (default: ${live?})%NL
     -s --[no-]security, \${GLUS_SECURITY}
        Compile security relevant packages (daily process, for example).
        (default: ${security?})%NL

	  ACTIONS
     --[no-]system, \${GLUS_SYSTEM}
        Compile only system core (weekly process, for example).
        (default: ${system?})%NL
     --world
        Compile only system core (monthly process, for example).%NL
     --full
        Recompile the entire system (annual process, for example).%NL

    Hooks:
      GLUS_BEFORE_SYNC: "${GLUS_BEFORE_SYNC}"
      GLUS_AFTER_SYNC: "${GLUS_AFTER_SYNC}"
      GLUS_BEFORE_COMPILE: "${GLUS_BEFORE_COMPILE}"
      GLUS_AFTER_COMPILE: "${GLUS_AFTER_COMPILE}"

    Configuration file: ${sysConfFile}
    Report bugs to: <$(getMetadata 'Repository')/issues>
	EOF
  )"
  exit 0
}

getMetadata() { sed -ne 's|^# '"${1:?}"':[[:blank:]]*\(.\{1,\}\)$|\1|p' -- "${0:?}"; }

# Show version number and quit.
showVersion() {
  printf '%s\n' "$(
    cat <<-EOF
		GLUS: $(getMetadata 'Version')
		Author: $(getMetadata 'Author')
		License: $(getMetadata 'License')
		Repository: $(getMetadata 'Repository')
	EOF
  )"
  exit 0
}

# Pretty print methods.
printInfo() { [ -n "${NO_STDOUT+x}" ] || printf "${COLOR_RESET-}[${COLOR_BGREEN-}INFO${COLOR_RESET-}] %s\n" "${@-}"; }
printWarn() { [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BYELLOW-}WARN${COLOR_RESET-}] %s\n" "${@-}" >&2; }
printError() { [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BRED-}ERROR${COLOR_RESET-}] %s\n" "${@-}" >&2; }
printList() { [ -n "${NO_STDOUT+x}" ] || printf "${COLOR_RESET-} ${COLOR_BCYAN-}*${COLOR_RESET-} %s\n" "${@-}"; }

# Compile
compile() {
  local try emerge

  # Update binutils, gcc
  UpdateDevel &>/dev/null

  # shellcheck disable=SC2012
  emerge=$(ls /usr/lib/python-exec/python*/emerge | sort -rV | head -n1)
  try=3

  if [ ! "${pretend}" ]; then
    # First try download all files
    while true; do
      # shellcheck disable=SC2048
      if command "${emerge} -f ${color} -u1 --keep-going --fail-clean y ${exclude} ${EMERGE_OPTS} $*" ; then
        break
      fi

      ((--try)) || break
      sleep 300
    done
  fi

  if [ "${fetch:?}" = 'false' ]; then
    # Compile
    command "${emerge} ${color} -v -u1 --keep-going --fail-clean y ${binary} ${pretend} $*"

    # Update broken merges
    command "emaint ${pretend} merges"

    # Update binutils, gcc
    UpdateDevel &>/dev/null
  fi
}

command() {
  printInfo "$@"

  if [ "${debug:?}" = 'true' ]; then
    return
  fi

  local err temp_file
  temp_file=${LOGS}/$(date +%Y-%m-%d-%H-%M-%S)_$(echo "$@" | sed -e 's:/:_:g' | sed -e 's: :_:g' | sed -e 's:=:_:g').log

  if [ "${pretend}" ]; then
    # shellcheck disable=SC2048
    $* 2>/dev/null
  else
    if [ "${quiet:?}" = 'true' ]; then
      # shellcheck disable=SC2048
      $* &>"${temp_file}"
    else
      # shellcheck disable=SC2048
      $* | tee "${temp_file}"
    fi
    err=$?
    if [[ ${err} -ne 0 && ${email} ]]; then
      ((++errors))
      tail -n1000 "${temp_file}" | mailx -s "Gentoo update error: $*" "${email}"
    fi
  fi
}

checkPKG() {
  if grep -q ^PKGDIR= /etc/make.conf || grep -q ^PKGDIR= /etc/portage/make.conf; then
    return 0
  fi

  return 1
}

main() {
  if [ -f "${sysConfFile}" ]; then
    # shellcheck source=/etc/portage/glus.conf
    set -a
    . "${sysConfFile}"
    set +a
  fi

  # Sync portage.
  sync="${GLUS_SYNC-"true"}"

  # Only fetch packages.
  fetch="${GLUS_FETCH-"false"}"

  # Exclude packages.
  exclude="${GLUS_EXCLUDE-""}"

  # Add this packages for update
  packages="${GLUS_PACKAGES-""}"

  # Display what packages have been installed
  pretend="${GLUS_PRETEND-"false"}"

  # Check the system
  check="${GLUS_CHECK-"true"}"

  # Clean packages and source files after compile.
  clean="${GLUS_CLEAN-"false"}"

  # Add go lang packages for update
  go="${GLUS_GO-"false"}"

  # Add kernel modules for update
  modules="${GLUS_MODULES-"false"}"

  # Add live packages for update
  live="${GLUS_LIVE-"false"}"

  # Compile security relevant packages
  security="${GLUS_SECURITY-"true"}"

  # Compile only system core
  system="${GLUS_SYSTEM-"false"}"

  # Suppress non-error messages
  quiet="${GLUS_QUIET-"false"}"

  # Add go lang packages for update
  color="${GLUS_COLOR-"true"}"

  # Add go lang packages for update
  binary="${GLUS_BINARY-"false"}"

  # Send mail for alerts and notifications.
  email="${GLUS_EMAIL-""}"

  # Show the commands to run
  debug="${GLUS_DEBUG-"false"}"

  # Compile all
  world="false"

  # Recompile the entire system
  full="false"

  # Parse command line options.
  # shellcheck disable=SC2086
  {
    optParse "${@-}"
    set -- ${posArgs-} >/dev/null
  }

  # Define terminal colors if the color option is enabled or in auto mode if STDOUT is attached to a TTY and the
  # "NO_COLOR" variable is not set (https://no-color.org).
  if [ "${color:?}" = 'true' ] || { [ "${color:?}" = 'auto' ] && [ -z "${NO_COLOR+x}" ] && [ -t 1 ]; }; then
    COLOR_RESET="$({ exists tput && tput sgr0; } 2>/dev/null || printf '\033[0m')"
    COLOR_BRED="$({ exists tput && tput bold && tput setaf 1; } 2>/dev/null || printf '\033[1;31m')"
    COLOR_BGREEN="$({ exists tput && tput bold && tput setaf 2; } 2>/dev/null || printf '\033[1;32m')"
    COLOR_BYELLOW="$({ exists tput && tput bold && tput setaf 3; } 2>/dev/null || printf '\033[1;33m')"
    COLOR_BCYAN="$({ exists tput && tput bold && tput setaf 6; } 2>/dev/null || printf '\033[1;36m')"
    color=""
  else
    color=" --color n"
  fi

  # Set "NO_STDOUT" variable if the quiet option is enabled (other methods will honor this variable).
  if [ "${quiet:?}" = 'true' ]; then
    NO_STDOUT='true'
  fi

  # Remove superfluous warnings in pretend
  if [ "${pretend:?}" = 'true' ]; then
    pretend=" -p"
  else
    pretend=""
  fi

  if [ "${exclude}" ]; then
    exclude="--exclude \"${exclude}\""
  fi

  # Check the header file.
  case "${binary:?}" in
  # If is false.
  'false') binary="" ;;
    # If is empty.
  'true') binary="-k" ;;
    # If the value equals "only" or empty, use pkg.
  'only') binary="-K" ;;
    # If the value equals "only", use pkgonly.
  'auto')
    if checkPKG; then
      echo "ok"
      binary="-k"
    else
      binary=""
    fi
    ;;
  'autoonly')
    if checkPKG; then
      binary="-K"
    else
      binary=""
    fi
    ;;
  # If the file does not exist, throw an error.
  *) [ -e "${binary:?}" ] || {
    printError "No such binary option: ${headerFile:?}"
    exit 1
  } ;;
  esac

  if [ "${sync:?}" = 'true' ]; then
    if [ "${GLUS_BEFORE_SYNC}" ]; then
      # Execute command before sync portage
      command "${GLUS_BEFORE_SYNC}"
    fi

    command "emaint -a sync"

    if [ "${GLUS_AFTER_SYNC}" ]; then
      # Execute command after sync portage
      command "${GLUS_AFTER_SYNC}"
    fi
  fi

  if [ "${GLUS_BEFORE_COMPILE}" ] && [ ! "${pretend}" ]; then
    # Execute command before compile
    command "${GLUS_BEFORE_COMPILE}"
  fi

  # Empty portage tmp dir
  clean_portage_dir

  # First update the portage
  compile "portage"

  # Update the system base
  if [ "${system:?}" = "true" ]; then
    # First try compile all updates
    compile "-uDN system"
    # Compile only the basic system because sometimes you can't compile everything because of perl or python dependencies
    compile "system"
  fi

  if [ "${world:?}" = "true" ]; then
    compile "-uDN world --complete-graph=y --with-bdeps=y"
  else
    if [ "${full:?}" = "true" ]; then
      compile "-ueDN world --complete-graph=y --with-bdeps=y"
    else
      # Force compile the live packages
      if [ "${live:?}" = "true" ]; then
        compile "@live-rebuild"
      fi

      local sets

      # Compile sets
      sets="-u ${packages}"
      if [ "${security:?}" = "true" ]; then
        # Update security
        sets="${sets} @security"
      fi
      if [ "${go:?}" = "true" ]; then
        sets="${sets} @golang-rebuild"
      fi
      if [ "${modules:?}" = "true" ]; then
        sets="${sets} @modules-rebuild"
      fi
      compile "${sets}"
    fi
  fi

  if [ "${fetch:?}" = 'false' ]; then
    # Remove old packages
    if [ "${clean:?}" = 'true' ]; then
      command "emerge --depclean ${pretend} ${exclude}"
    fi

    # Recompile all perl packages
    command "/usr/sbin/perl-cleaner --all -- ${color} -v --fail-clean y ${binary} ${pretend}"

    if [ "${check:?}" = 'true' ]; then
      # Check system integrity
      command "revdep-rebuild -- -v ${color} --fail-clean y ${binary} ${pretend}"
    fi

    if [ "${GLUS_AFTER_COMPILE}" ] && [ ! "${pretend}" ]; then
      # Execute command after all
      command "${GLUS_AFTER_COMPILE}"
    fi

    # Check and fix problems in the world file
    command "emaint ${pretend} world"

    if [ "${clean:?}" = 'true' ]; then
      command "eclean -C -d ${pretend} packages"
      command "eclean -C -d ${pretend} distfiles"
    fi
  fi
}

main "${@-}"