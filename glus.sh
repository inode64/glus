#!/bin/bash
#
# Gentoo Linux update system
#
# Version:    1.0.0
# Author:     Francisco Javier Félix Belmonte <ffelix@inode64.com>
# License:    MIT, https://opensource.org/licenses/MIT
# Repository: https://github.com/inode64/glus


# TODO: Use different ways to send mail (https://linuxhint.com/bash_script_send_email)

# Check if other instances of glus.sh are running
# shellcheck disable=SC2046
if [ $(pgrep -c glus.sh) -gt 1 ]; then
	exit 0
fi

export LC_ALL='C'

# Define system configuration file.
if [ -z "${ETCDIR+x}" ]; then ETCDIR='/etc'; fi
SYS_CONF_FILE="${ETCDIR?}/portage/glus.conf"

declare -r ETCDIR
declare -r SYS_CONF_FILE

LOGS=$(mktemp -d)
declare -r LOGS

errors=0

#######################################
# Remove temporary files on exit.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
#######################################
cleanup() {
	local ret="$?"
	rm -rf "${LOGS}"
	trap - EXIT
	exit "${ret:?}"
}
{
	trap cleanup EXIT || :
	trap cleanup TERM || :
	trap cleanup INT || :
	trap cleanup HUP || :
} 2>/dev/null

# Remove unnecessary files in /var/tmp/portage
clean_portage_dir() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
		return
	fi

	# Check if other instances of emerge are running before deleting temporary files
	# shellcheck disable=SC2046
	if [ $(pgrep -c emerge) -eq 0 ]; then
		rm -rf /var/tmp/portage/* 2>/dev/null
	fi
}

Last_binutils() {
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

Last_gcc() {
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

update_devel() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug}" ]; then
		return
	fi

	etc-update -p

	Last_binutils
	Last_gcc

	# We update 2 times in case the new python does not exist yet
	eselect python update --python3
	etc-update --automode -5 /etc/python-exec
	eselect python update --python3
}

# Parse command line options.
opt_parse() {
	optArgNext=0

	while [ "${#}" -gt '0' ]; do
		case "${1?}" in
		# Short options that accept an argument need a "*" in their pattern because they can be
		# found in the "-A<value>" form.
		'-S' | '--sync' | '--no-sync')
			opt_arg_bool "${@-}"
			sync="${optArg:?}"
			;;
		'-e' | '--exclude')
			opt_arg_str "${@-}"
			exclude="${optArg:?}"
			;;
		'-p' | '--packages')
			opt_arg_str "${@-}"
			packages="${optArg:?}"
			;;
		'-P' | '--pretend' | '--no-pretend')
			opt_arg_bool "${@-}"
			pretend="${optArg:?}"
			;;
		'-c' | '--check' | '--no-check')
			opt_arg_bool "${@-}"
			check="${optArg:?}"
			;;
		'-C' | '--clean' | '--no-clean')
			opt_arg_bool "${@-}"
			clean="${optArg:?}"
			;;
		'-g' | '--go' | '--no-go')
			opt_arg_bool "${@-}"
			go="${optArg:?}"
			;;
		'-m' | '--modules' | '--no-modules')
			opt_arg_bool "${@-}"
			modules="${optArg:?}"
			;;
		'-l' | '--live' | '--no-live')
			opt_arg_bool "${@-}"
			live="${optArg:?}"
			;;
		'-s' | '--security' | '--no-security')
			opt_arg_bool "${@-}"
			security="${optArg:?}"
			;;
		'--system' | '--no-system')
			opt_arg_bool "${@-}"
			system="${optArg:?}"
			;;
		'--world')
			opt_arg_bool "${@-}"
			world="${optArg:?}"
			;;
		'--full')
			opt_arg_bool "${@-}"
			full="${optArg:?}"
			;;
		'-f' | '--fetch' | '--no-fetch')
			opt_arg_bool "${@-}"
			fetch="${optArg:?}"
			;;
		'--debug')
			opt_arg_bool "${@-}"
			debug="${optArg:?}"
			;;
		'-b' | '--binary' | '--no-binary')
			opt_arg_str "${@-}"
			binary="${optArg:?}"
			;;
		'-x'* | '--color')
			opt_arg_str "${@-}"
			color="${optArg?}"
			shift "${optShift:?}"
			;;
		'-email')
			opt_arg_str "${@-}"
			email="${optArg:?}"
			;;
		'-v' | '--version') show_version ;;
		'-h' | '--help') show_help ;;
		# If "--" is found, the remaining positional arguments are saved and the parsing ends.
		--)
			shift
			posArgs="${posArgs-} ${*-}"
			break
			;;
		# If a long option in the form "--opt=value" is found, it is split into "--opt" and "value".
		--*=*)
			opt_split_equals "${@-}"
			shift
			set -- "${optName:?}" "${optArg?}" "${@-}"
			continue
			;;
		# If an option did not match any pattern, an error is thrown.
		-? | --*) opt_die "Illegal option ${1:?}" ;;
		# If multiple short options in the form "-AB" are found, they are split into "-A" and "-B".
		-?*)
			opt_split_short "${@-}"
			shift
			set -- "${optAName:?}" "${optBName:?}" "${@-}"
			continue
			;;
		# If a positional argument is found, it is saved.
		*) if [ ${optArgNext} -eq 1 ]; then
				posArgs="${posArgs-} ${1?}"
			else
				opt_die "Illegal option ${1?}"
			fi
		  ;;
		esac
		shift
	done
}

opt_split_short() {
	optAName="${1%"${1#??}"}"
	optBName="-${1#??}"
	optArgNext=0
}

opt_split_equals() {
	optName="${1%="${1#--*=}"}"
	optArg="${1#--*=}"
	optArgNext=0
}

opt_arg_str() {
	if [ -n "${1#??}" ] && [ "${1#--}" = "${1:?}" ]; then
		optArg="${1#??}"
		optShift='0'
	elif [ -n "${2+x}" ]; then
		optArg="${2-}"
		optShift='1'
	else opt_die "No argument for ${:?} option"; fi

	[ "${optArg:0:1}" == "-" ] && opt_die "Non a valid argument for ${1:?} option"

	optArgNext='1'
}

opt_arg_bool() {
	if [ "${1#--no-}" = "${1:?}" ]; then
		optArg='true'
	else optArg='false'; fi
	optArgNext=0
}

opt_die() {
	printf '%s\n' "${@-}" "Try 'glus --help' for more information" >&2
	exit 2
}

# Show help and quit.
show_help() {
	printf '%s\n' "$(
		sed -e 's/%NL/\n/g' <<-EOF
			  Gentoo Linux update system%NL
			  Usage: glus [--full|--world] [OPTION]...
			  Keep your gentoo linux up to date, update security problems daily
			  and check that it is correct.%NL
			  PORTAGE OPTIONS:
	     -S, --[no-]sync, \${GLUS_SYNC}
	        Sync portage.
	        (default: ${sync})%NL
	     -e, --exclude <EXCLUDE>, \${GLUS_EXCLUDE}
	        Exclude packages.
	        (default: "${exclude}")%NL
	     -P --[no-]pretend, \${GLUS_PRETEND}
	        Instead of actually performing the merge, simply display what *would* have been installed if --pretend weren't used.
	        (default: "${pretend}")%NL
	     -c --[no-]check, \${GLUS_CHECK}
	        Check the system.
	        (default: ${check?})%NL
	     -C --[no-]clean, \${GLUS_CLEAN}
	        Clean packages and source files after compile.
	        (default: ${clean?})%NL
	     -f, --[no-]fetch, \${GLUS_FETCH}
	        Only download, no compile or install.
	        (default: ${fetch?})%NL
	     -b, --binary <auto|autoonly|true|false|only>, \${GLUS_BINARY}
	        Use binary packages.
	        Force use only binary packages for only option selected.
	        (default: ${binary?})%NL

			  SETS:
	     -p --packages <PACKAGES>, \${GLUS_PACKAGES}
	        Add this packages for update.
	        (default: "${packages}")%NL
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

			  ACTIONS:
	     --[no-]system
	        Compile only system core (weekly process, for example).
	        (default: ${system?})%NL
	     --world
	        Compile only system core (monthly process, for example).%NL
	     --full
	        Recompile the entire system (annual process, for example).%NL

	    MISC OPTIONS:
	     --[no-]debug, \${GLUS_DEBUG}
	        Show the commands to run.
	        (default: ${debug?})%NL
	     -q, --[no-]quiet, \${GLUS_QUIET}
	        Suppress non-error messages.
	        (default: ${quiet?})%NL
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

	    Hooks:
	      GLUS_BEFORE_SYNC: "${GLUS_BEFORE_SYNC}"
	      GLUS_AFTER_SYNC: "${GLUS_AFTER_SYNC}"
	      GLUS_BEFORE_COMPILE: "${GLUS_BEFORE_COMPILE}"
	      GLUS_AFTER_COMPILE: "${GLUS_AFTER_COMPILE}"

	    Configuration file: ${SYS_CONF_FILE}
	    Report bugs to: <$(get_metadata 'Repository')/issues>
		EOF
	)"
	exit 0
}

get_metadata() { sed -ne 's|^# '"${1:?}"':[[:blank:]]*\(.\{1,\}\)$|\1|p' -- "${0:?}"; }

# Show version number and quit.
show_version() {
	printf '%s\n' "$(
		cat <<-EOF
			GLUS: $(get_metadata 'Version')
			Author: $(get_metadata 'Author')
			License: $(get_metadata 'License')
			Repository: $(get_metadata 'Repository')
		EOF
	)"
	exit 0
}

# Pretty print methods.
print_info() { [ -n "${NO_STDOUT+x}" ] || printf "${COLOR_RESET-}[${COLOR_BGREEN-}INFO${COLOR_RESET-}] %s\n" "${@-}"; }
print_warn() { [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BYELLOW-}WARN${COLOR_RESET-}] %s\n" "${@-}" >&2; }
print_error() { [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BRED-}ERROR${COLOR_RESET-}] %s\n" "${@-}" >&2; }
print_list() { [ -n "${NO_STDOUT+x}" ] || printf "${COLOR_RESET-} ${COLOR_BCYAN-}*${COLOR_RESET-} %s\n" "${@-}"; }

start_process() {
	START=$(date +%s)
	print_info "$@"
}

stop_process() {
	local result

	((result = $(date +%s) - START))

	print_info "Process time: $((result / 3600))h $(((result / 60) % 60))m $((result % 60))s"
}

# Auto merge portage config
etc_update_portage() {
	if [ ! "${pretend}" ] || [ "${debug}" ]; then
		command "/usr/sbin/etc-update --automode -5 /etc/portage &>/dev/null"
	fi
}

# Compile
compile() {
	local try emerge

	# Update binutils, gcc
	update_devel &>/dev/null

	# shellcheck disable=SC2012
	emerge=$(ls /usr/lib/python-exec/python*/emerge | sort -rV | head -n1)
	try=3

	if [ ! "${pretend}" ]; then
		# First try download all files
		while true; do
			# shellcheck disable=SC2048
			if command "${emerge} -f -1 --keep-going --fail-clean y${color}${exclude}${EMERGE_OPTS} $*"; then
				break
			fi

			((--try)) || break
			sleep 300
		done
	fi

	if [ "${fetch:?}" = 'false' ]; then
		# Compile
		command "${emerge} -v -1 --keep-going --fail-clean y${color}${exclude}${binary}${pretend} $*"

		# Update broken merges
		command "emaint${pretend} merges"

		# Update binutils, gcc
		update_devel &>/dev/null
	fi
}

command() {
	print_info "$@"

	if [ "${debug:?}" = 'true' ]; then
		return
	fi

	local err temp_file
	temp_file=${LOGS}/$(date +%Y-%m-%d-%H-%M-%S).log

	if [ "${pretend}" ]; then
		# shellcheck disable=SC2048
		eval "$*" 2>/dev/null
	else
		if [ "${quiet:?}" = 'true' ]; then
			# shellcheck disable=SC2048
			eval "$*" &>"${temp_file}"
		else
			# shellcheck disable=SC2048
			eval "$*" | tee "${temp_file}"
		fi
		err=$?
		if [[ ${err} -ne 0 && ${email} ]]; then
			((++errors))
			tail -n1000 "${temp_file}" | mailx -s "Gentoo update error: $*" "${email}"
		fi
	fi
}

check_pkg() {
	if grep -q ^PKGDIR= /etc/make.conf || grep -q ^PKGDIR= /etc/portage/make.conf; then
		return 0
	fi

	return 1
}

get_versions() {
	# Check systemd
	if [ -x /run/systemd/system ]; then
		systemd_old=$(systemctl --version)
	fi
}

change_versions() {
	local systemd_new
	# Check systemd
	if [ -x /run/systemd/system ]; then
		systemd_new=$(systemctl --version)
		if [ "$systemd_new" != "$systemd_old" ]; then
			print_info "systemd has changed, reloading"
			systemctl daemon-reexec
		fi
	fi
}

main() {
	if [ -f "${SYS_CONF_FILE}" ]; then
		set -a
		# shellcheck source=/etc/portage/glus.conf
		. "${SYS_CONF_FILE}"
		set +a
	fi

	# Portage options
	#

	# Sync portage.
	sync="${GLUS_SYNC-"true"}"

	# Only fetch packages.
	fetch="${GLUS_FETCH-"false"}"

	# Exclude packages.
	exclude="${GLUS_EXCLUDE-""}"

	# Display what packages have been installed
	pretend="${GLUS_PRETEND-"false"}"

	# Check the system
	check="${GLUS_CHECK-"true"}"

	# Clean packages and source files after compile.
	clean="${GLUS_CLEAN-"false"}"

	# Use binary packages
	binary="${GLUS_BINARY-"false"}"

	# Sets
	#

	# Add go lang packages for update
	go="${GLUS_GO-"false"}"

	# Add kernel modules for update
	modules="${GLUS_MODULES-"false"}"

	# Add live packages for update
	live="${GLUS_LIVE-"false"}"

	# Add this packages for update
	packages="${GLUS_PACKAGES-""}"

	# Compile security relevant packages
	security="${GLUS_SECURITY-"true"}"

	# Misc options
	#

	# Add go lang packages for update
	color="${GLUS_COLOR-"true"}"

	# Send mail for alerts and notifications.
	email="${GLUS_EMAIL-""}"

	# Suppress non-error messages
	quiet="${GLUS_QUIET-"false"}"

	# Show the commands to run
	debug="${GLUS_DEBUG-"false"}"

	# Actions
	#

	# Compile only system core
	system="false"

	# Compile all
	world="false"

	# Recompile the entire system
	full="false"

	# Parse command line options.
	# shellcheck disable=SC2086
	{
		opt_parse "${@-}"
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
		exclude=" --exclude '${exclude}'"
	fi

	# Check the header file.
	case "${binary:?}" in
	# If is false.
	'false') binary="" ;;
		# If is empty.
	'true') binary=" -k" ;;
		# If the value equals "only" or empty, use pkg.
	'only') binary=" -K" ;;
		# If the value equals "only", use pkgonly.
	'auto')
		if check_pkg; then
			echo "ok"
			binary=" -k"
		else
			binary=""
		fi
		;;
	'autoonly')
		if check_pkg; then
			binary=" -K"
		else
			binary=""
		fi
		;;
	# If the file does not exist, throw an error.
	*) [ -e "${binary:?}" ] || {
		print_error "No such binary option: ${headerFile:?}"
		exit 1
	} ;;
	esac

	get_versions

	if [ "${sync:?}" = 'true' ]; then
		if [ "${GLUS_BEFORE_SYNC}" ]; then
			# Execute command before sync portage
			command "${GLUS_BEFORE_SYNC}"
		fi

		start_process "Sync portage"
		command "emaint -a sync"
		stop_process

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

	# Update config in /etc/portage
	etc_update_portage

	# First update the portage
	start_process "Update portage"
	compile "-u portage"
	stop_process

	# Fix compile errors when /usr/include/crypt.h is missing
	if [ ! -e /usr/include/crypt.h ]; then
		compile "-1u sys-libs/libxcrypt"
	fi

	# Update the system base
	if [ "${system:?}" = "true" ]; then
		start_process "Update system"
		# First try to compile all updates
		compile "-uDN system"
		# Compile only the basic system because sometimes you can't compile everything because of perl or python dependencies
		compile "-u system"
		stop_process
	fi

	if [ "${world:?}" = "true" ]; then
		start_process "Update world"
		compile "-uDN world --complete-graph=y --with-bdeps=y"
		stop_process
	else
		if [ "${full:?}" = "true" ]; then
			start_process "Update really world"
			compile "-ueDN world --complete-graph=y --with-bdeps=y"
			stop_process
		else
			# Force compiles the live packages
			if [ "${live:?}" = "true" ]; then
				start_process "Update live packages"
				compile "@live-rebuild"
				stop_process
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

			start_process "Update sets"
			compile "${sets}"
			stop_process
		fi
	fi

	if [ "${fetch:?}" = 'false' ]; then
		# Remove old packages
		if [ "${clean:?}" = 'true' ]; then
			command "emerge --depclean${pretend}${exclude}"
		fi

		start_process "Rebuild preserved packages"
		command "emerge @preserved-rebuild"
		stop_process

		if [ ! "${pretend}" ]; then
			# Recompile all perl packages
			start_process "Update perl packages"
			command "/usr/sbin/perl-cleaner --all -- ${color} -v --fail-clean y${binary}${pretend}"
			stop_process

			if [ "${check:?}" = 'true' ]; then
				# Check system integrity: Reverse Dependency Rebuilder
				command "revdep-rebuild -i -v -- -v ${color} --fail-clean y${binary}${pretend}"

				# TODO: verify integrity of installed packages -> qcheck -B -v ; qcheck <package>
			fi
		fi

		if [ "${GLUS_AFTER_COMPILE}" ] && [ ! "${pretend}" ]; then
			# Execute command after all
			command "${GLUS_AFTER_COMPILE}"
		fi

		# Check and fix problems in the world file
		command "emaint${pretend} world"

		if [ "${clean:?}" = 'true' ]; then
			if [ "${binary}" ]; then
				command "eclean -C -d${pretend} packages"
			fi
			command "eclean -C -d${pretend} distfiles"
		fi
	fi

	# Check if they have changed any programs and need to reload
	change_versions
}

main "${@-}"
