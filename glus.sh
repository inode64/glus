#!/bin/bash
#
# Gentoo Linux update system
#
# Version:    1.0.0
# Author:     Francisco Javier Félix Belmonte <ffelix@inode64.com>
# License:    MIT, https://opensource.org/licenses/MIT
# Repository: https://github.com/inode64/glus


# TODO: Use different ways to send mail (https://linuxhint.com/bash_script_send_email)

# Check if other instances of glus.sh are running.
if ! command -v flock >/dev/null 2>&1; then
	printf '%s\n' 'flock command not found' >&2
	exit 1
fi

if [ -d /run/lock ] && [ -w /run/lock ]; then
	LOCK_FILE='/run/lock/glus.lock'
else
	LOCK_FILE="${TMPDIR:-/tmp}/glus.lock"
fi
exec {LOCK_FD}>"${LOCK_FILE}" || {
	printf 'Unable to open lock file: %s\n' "${LOCK_FILE}" >&2
	exit 1
}
if ! flock -n "${LOCK_FD}"; then
	exit 0
fi

export LC_ALL='C'

# Define system configuration file.
if [ -z "${ETCDIR+x}" ]; then ETCDIR='/etc'; fi
SYS_CONF_FILE="${ETCDIR?}/portage/glus.conf"

declare -r ETCDIR
declare -r LOCK_FILE
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
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
		return
	fi

	# Check if other instances of emerge are running before deleting temporary files
	# shellcheck disable=SC2046
	if [ $(pgrep -c emerge) -eq 0 ]; then
		rm -rf /var/tmp/portage/* 2>/dev/null
	fi
}

Last_binutils() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
		return 0
	fi

	local last

	last=$(/usr/bin/binutils-config -l 2>/dev/null | wc -l)
	if ! [ "${last}" -gt 0 ] 2>/dev/null; then
		return 0
	fi

	/usr/bin/binutils-config "${last}"
	/usr/sbin/env-update 2>/dev/null

	# shellcheck disable=SC1091
	. /etc/profile

	return 0
}

Last_gcc() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
		return 0
	fi

	local last

	last=$(/usr/bin/gcc-config -l 2>/dev/null | wc -l)
	if ! [ "${last}" -gt 0 ] 2>/dev/null; then
		return 0
	fi

	/usr/bin/gcc-config "${last}"
	/usr/sbin/env-update 2>/dev/null

	# shellcheck disable=SC1091
	. /etc/profile

	return 0
}

update_devel() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
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
			shift "${optShift:?}"
			;;
		'-p' | '--packages')
			opt_arg_str "${@-}"
			packages="${optArg:?}"
			shift "${optShift:?}"
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
		'--dry-run' | '--plan')
			enable_dry_run
			optArgNext=0
			;;
		'--debug' | '--no-debug')
			opt_arg_bool "${@-}"
			debug="${optArg:?}"
			;;
		'-b' | '--binary')
			opt_arg_str "${@-}"
			binary="${optArg:?}"
			shift "${optShift:?}"
			;;
		'--no-binary')
			binary='false'
			optArgNext=0
			;;
		'-q' | '--quiet' | '--no-quiet')
			opt_arg_bool "${@-}"
			quiet="${optArg:?}"
			;;
		'-x'* | '--color')
			opt_arg_str "${@-}"
			color="${optArg?}"
			shift "${optShift:?}"
			;;
		'--email' | '-email')
			opt_arg_str "${@-}"
			email="${optArg:?}"
			shift "${optShift:?}"
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
		*) if [ "${optArgNext}" -eq 1 ]; then
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
	else opt_die "No argument for ${1:?} option"; fi

	[ "${optArg:0:1}" == "-" ] && opt_die "Non a valid argument for ${1:?} option"

	optArgNext=0
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

enable_dry_run() {
	dry_run='true'
	debug='true'
	quiet='false'
}

# Show help and quit.
show_help() {
	if [ "${dry_run-}" = 'true' ]; then
		enable_dry_run
	fi

	printf '%s\n' "$(
		sed -e 's/%NL/\n/g' <<-EOF
			  Gentoo Linux update system%NL
			  Usage: glus [--full|--world|--dry-run|--plan] [OPTION]...
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
	     -b, --binary <auto|autoonly|true|false|only>, --no-binary, \${GLUS_BINARY}
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
	     --dry-run, --plan
	        Show the planned steps and commands without executing them.
	        Shows commands like --debug and disables --quiet.
	        (default: ${dry_run?})%NL

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

format_command() {
	printf '%q ' "$@"
}

run_config_command() {
	local config_command
	local -a config_args

	config_command="${1-}"
	if [ ! "${config_command}" ]; then
		return 0
	fi

	read -r -a config_args <<<"${config_command}"
	if [ "${#config_args[@]}" -eq 0 ]; then
		return 0
	fi

	command "${config_args[@]}"
}

validate_bool() {
	local name value

	name="${1:?}"
	value="${2-}"

	case "${value}" in
	'true' | 'false') return 0 ;;
	*) print_error "Invalid ${name}: ${value}. Expected true or false." ;;
	esac

	return 1
}

validate_choice() {
	local choice choices name value

	name="${1:?}"
	value="${2-}"
	shift 2

	for choice in "$@"; do
		if [ "${value}" = "${choice}" ]; then
			return 0
		fi
		choices="${choices:+${choices}|}${choice}"
	done

	print_error "Invalid ${name}: ${value}. Expected one of: ${choices}."
	return 1
}

validate_email() {
	local name value

	name="${1:?}"
	value="${2-}"

	if [ ! "${value}" ]; then
		return 0
	fi

	if [[ "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
		return 0
	fi

	print_error "Invalid ${name}: ${value}. Expected an email address."
	return 1
}

validate_config_command() {
	local name value
	local -a command_args

	name="${1:?}"
	value="${2-}"

	if [ ! "${value}" ]; then
		return 0
	fi

	case "${value}" in
	*[\;\|\&\<\>\`]*)
		print_error "Invalid ${name}: shell operators are not supported. Use a wrapper script instead."
		return 1
		;;
	esac

	read -r -a command_args <<<"${value}"
	if [ "${#command_args[@]}" -eq 0 ]; then
		return 0
	fi

	if [[ "${command_args[0]}" = */* ]]; then
		[ -x "${command_args[0]}" ] && return 0
	else
		builtin command -v "${command_args[0]}" >/dev/null 2>&1 && return 0
	fi

	print_error "Invalid ${name}: command not found: ${command_args[0]}"
	return 1
}

validate_config() {
	local ret

	ret=0

	validate_bool GLUS_SYNC "${sync}" || ret=1
	validate_bool GLUS_FETCH "${fetch}" || ret=1
	validate_bool GLUS_PRETEND "${pretend}" || ret=1
	validate_bool GLUS_CHECK "${check}" || ret=1
	validate_bool GLUS_CLEAN "${clean}" || ret=1
	validate_bool GLUS_GO "${go}" || ret=1
	validate_bool GLUS_MODULES "${modules}" || ret=1
	validate_bool GLUS_LIVE "${live}" || ret=1
	validate_bool GLUS_SECURITY "${security}" || ret=1
	validate_bool GLUS_QUIET "${quiet}" || ret=1
	validate_bool GLUS_DEBUG "${debug}" || ret=1
	validate_bool system "${system}" || ret=1
	validate_bool world "${world}" || ret=1
	validate_bool full "${full}" || ret=1

	validate_choice GLUS_BINARY "${binary}" false true only auto autoonly || ret=1
	validate_choice GLUS_COLOR "${color}" true false auto || ret=1
	validate_email GLUS_EMAIL "${email}" || ret=1

	validate_config_command GLUS_BEFORE_SYNC "${GLUS_BEFORE_SYNC-}" || ret=1
	validate_config_command GLUS_AFTER_SYNC "${GLUS_AFTER_SYNC-}" || ret=1
	validate_config_command GLUS_BEFORE_COMPILE "${GLUS_BEFORE_COMPILE-}" || ret=1
	validate_config_command GLUS_AFTER_COMPILE "${GLUS_AFTER_COMPILE-}" || ret=1

	return "${ret}"
}

start_process() {
	START=$(date +%s)
	if [ "${dry_run-}" = 'true' ]; then
		print_info "Plan step: $*"
		return
	fi

	print_info "$@"
}

stop_process() {
	local result

	if [ "${dry_run-}" = 'true' ]; then
		return
	fi

	((result = $(date +%s) - START))

	print_info "Process time: $((result / 3600))h $(((result / 60) % 60))m $((result % 60))s"
}

run_process() {
	local ret title

	title="${1:?}"
	shift

	start_process "${title}"
	"$@"
	ret=$?
	stop_process

	return "${ret}"
}

# Auto merge portage config
etc_update_portage() {
	if [ ! "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
		command --discard-output /usr/sbin/etc-update --automode -5 /etc/portage || return
	fi

	return 0
}

find_emerge() {
	local candidate

	while IFS= read -r candidate; do
		if [ -x "${candidate}" ]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done < <(find /usr/lib/python-exec -maxdepth 2 -mindepth 2 -path '/usr/lib/python-exec/python*/emerge' 2>/dev/null | sort -rV)

	print_error "No executable emerge wrapper found in /usr/lib/python-exec/python*/emerge"
	return 1
}

# Compile
compile() {
	local command_flags count_errors fetch_ok try emerge

	command_flags=()
	count_errors='true'
	if [ "${1-}" = '--no-error-count' ]; then
		command_flags=(--no-error-count)
		count_errors='false'
		shift
	fi

	# Update binutils, gcc
	update_devel &>/dev/null

	if ! emerge=$(find_emerge); then
		if [ "${count_errors}" = 'true' ]; then
			((++errors))
		fi
		return 1
	fi
	try=3

	if [ ! "${pretend}" ]; then
		# First try download all files
		fetch_ok='false'
		while true; do
			if command --no-error-count "${emerge}" -f -1 --keep-going --fail-clean y "${color_args[@]}" "${exclude_args[@]}" "${emerge_opts_args[@]}" "$@"; then
				fetch_ok='true'
				break
			fi

			((--try)) || break
			sleep 300
		done

		if [ "${fetch_ok}" != 'true' ]; then
			print_error "Failed to fetch packages: $(format_command "$@")"
			if [ "${count_errors}" = 'true' ]; then
				((++errors))
			fi
			return 1
		fi
	fi

	if [ "${fetch:?}" = 'false' ]; then
		# Compile
		command --pretend-safe "${command_flags[@]}" "${emerge}" -v -1 --keep-going --fail-clean y "${color_args[@]}" "${exclude_args[@]}" "${binary_args[@]}" "${pretend_args[@]}" "$@" || return

		# Update broken merges
		command --pretend-safe "${command_flags[@]}" emaint "${pretend_args[@]}" merges || return

		# Update binutils, gcc
		update_devel &>/dev/null
	fi

	return 0
}

command() {
	local count_errors discard_output err run_in_pretend temp_file

	count_errors='true'
	discard_output='false'
	run_in_pretend='false'
	while [ "${1-}" ]; do
		case "${1}" in
		'--pretend-safe')
			run_in_pretend='true'
			shift
			;;
		'--no-error-count')
			count_errors='false'
			shift
			;;
		'--discard-output')
			discard_output='true'
			shift
			;;
		*)
			break
			;;
		esac
	done

	if [ "${#}" -eq 0 ]; then
		print_error "No command specified"
		return 1
	fi

	if [ "${dry_run-}" = 'true' ]; then
		print_info "Plan command: $(format_command "$@")"
		return 0
	fi

	print_info "$(format_command "$@")"

	if [ "${debug:?}" = 'true' ]; then
		return 0
	fi

	if [ "${pretend}" ] && [ "${run_in_pretend}" != 'true' ]; then
		print_info "Skipping command in pretend mode"
		return 0
	fi

	temp_file=${LOGS}/$(date +%Y-%m-%d-%H-%M-%S).log

	if [ "${pretend}" ]; then
		"$@" 2>/dev/null
		err=$?
	else
		if [ "${discard_output}" = 'true' ]; then
			"$@" &>/dev/null
			err=$?
		elif [ "${quiet:?}" = 'true' ]; then
			"$@" &>"${temp_file}"
			err=$?
		else
			"$@" 2>&1 | tee "${temp_file}"
			err=${PIPESTATUS[0]}
		fi
	fi

	if [ "${err}" -ne 0 ]; then
		if [ "${count_errors}" = 'true' ]; then
			((++errors))
			if [ "${email}" ] && [ -f "${temp_file}" ]; then
				tail -n1000 "${temp_file}" | mailx -s "Gentoo update error: $*" "${email}"
			fi
		fi
	fi

	return "${err}"
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

	if [ "${pretend}" ] || [ "${debug:?}" = 'true' ]; then
		return
	fi

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
	local -a binary_args color_args emerge_opts_args exclude_args package_args pretend_args sets

	if [ -f "${SYS_CONF_FILE}" ]; then
		set -a
		# shellcheck source=/etc/portage/glus.conf
		# shellcheck disable=SC1091
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

	# Plan the run without touching the system
	dry_run="false"

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

	if [ "${dry_run:?}" = 'true' ]; then
		enable_dry_run
	fi

	validate_config || return 2

	# Define terminal colors if the color option is enabled or in auto mode if STDOUT is attached to a TTY and the
	# "NO_COLOR" variable is not set (https://no-color.org).
	if [ "${color:?}" = 'true' ] || { [ "${color:?}" = 'auto' ] && [ -z "${NO_COLOR+x}" ] && [ -t 1 ]; }; then
		COLOR_RESET="$({ builtin command -v tput >/dev/null && tput sgr0; } 2>/dev/null || printf '\033[0m')"
		COLOR_BRED="$({ builtin command -v tput >/dev/null && tput bold && tput setaf 1; } 2>/dev/null || printf '\033[1;31m')"
		COLOR_BGREEN="$({ builtin command -v tput >/dev/null && tput bold && tput setaf 2; } 2>/dev/null || printf '\033[1;32m')"
		COLOR_BYELLOW="$({ builtin command -v tput >/dev/null && tput bold && tput setaf 3; } 2>/dev/null || printf '\033[1;33m')"
		COLOR_BCYAN="$({ builtin command -v tput >/dev/null && tput bold && tput setaf 6; } 2>/dev/null || printf '\033[1;36m')"
		color_args=()
	else
		color_args=(--color n)
	fi

	# Set "NO_STDOUT" variable if the quiet option is enabled (other methods will honor this variable).
	if [ "${quiet:?}" = 'true' ]; then
		NO_STDOUT='true'
	fi

	if [ "${dry_run:?}" = 'true' ]; then
		print_info "Dry-run: planned commands will not be executed"
	fi

	# Remove superfluous warnings in pretend
	if [ "${pretend:?}" = 'true' ]; then
		pretend="-p"
		pretend_args=(-p)
	else
		pretend=""
		pretend_args=()
	fi

	if [ "${exclude}" ]; then
		exclude_args=(--exclude "${exclude}")
	else
		exclude_args=()
	fi

	if [ "${packages}" ]; then
		read -r -a package_args <<<"${packages}"
	else
		package_args=()
	fi

	if [ "${EMERGE_OPTS-}" ]; then
		read -r -a emerge_opts_args <<<"${EMERGE_OPTS}"
	else
		emerge_opts_args=()
	fi

	# Check the binary package option.
	case "${binary:?}" in
	# If is false.
	'false') binary_args=() ;;
		# If is empty.
	'true') binary_args=(-k) ;;
		# If the value equals "only" or empty, use pkg.
	'only') binary_args=(-K) ;;
		# If the value equals "only", use pkgonly.
	'auto')
		if check_pkg; then
			binary_args=(-k)
		else
			binary_args=()
		fi
		;;
	'autoonly')
		if check_pkg; then
			binary_args=(-K)
		else
			binary_args=()
		fi
		;;
	# If the value is not supported, throw an error.
	*) [ -e "${binary:?}" ] || {
		print_error "No such binary option: ${binary:?}"
		exit 1
	} ;;
	esac

	get_versions

	if [ "${sync:?}" = 'true' ]; then
		if [ "${GLUS_BEFORE_SYNC}" ]; then
			# Execute command before sync portage
			run_config_command "${GLUS_BEFORE_SYNC}" || return
		fi

		run_process "Sync portage" command emaint -a sync || return

		if [ "${GLUS_AFTER_SYNC}" ]; then
			# Execute command after sync portage
			run_config_command "${GLUS_AFTER_SYNC}" || return
		fi
	fi

	if [ "${GLUS_BEFORE_COMPILE}" ] && [ ! "${pretend}" ]; then
		# Execute command before compile
		run_config_command "${GLUS_BEFORE_COMPILE}" || return
	fi

	# Empty portage tmp dir
	clean_portage_dir

	# Update config in /etc/portage
	etc_update_portage || return

	# First update the portage
	run_process "Update portage" compile -u portage || return

	# Fix compile errors when /usr/include/crypt.h is missing
	if [ ! -e /usr/include/crypt.h ]; then
		compile -1u sys-libs/libxcrypt || return
	fi

	# Update the system base
	if [ "${system:?}" = "true" ]; then
		local ret

		start_process "Update system"
		# First try to compile all updates
		compile --no-error-count -uDN system || print_warn "Full system update failed, trying basic system update"
		# Compile only the basic system because sometimes you can't compile everything because of perl or python dependencies
		compile -u system
		ret=$?
		stop_process
		[ "${ret}" -eq 0 ] || return "${ret}"
	fi

	if [ "${world:?}" = "true" ]; then
		run_process "Update world" compile -uDN world --complete-graph=y --with-bdeps=y || return
	else
		if [ "${full:?}" = "true" ]; then
			run_process "Update really world" compile -ueDN world --complete-graph=y --with-bdeps=y || return
		else
			# Force compiles the live packages
			if [ "${live:?}" = "true" ]; then
				run_process "Update live packages" compile @live-rebuild || return
			fi

			# Compile sets
			sets=(-u "${package_args[@]}")
			if [ "${security:?}" = "true" ]; then
				# Update security
				sets+=(@security)
			fi
			if [ "${go:?}" = "true" ]; then
				sets+=(@golang-rebuild)
			fi
			if [ "${modules:?}" = "true" ]; then
				sets+=(@modules-rebuild)
			fi

			run_process "Update sets" compile "${sets[@]}" || return
		fi
	fi

	if [ "${fetch:?}" = 'false' ]; then
		# Remove old packages
		if [ "${clean:?}" = 'true' ]; then
			command --pretend-safe emerge --depclean "${pretend_args[@]}" "${exclude_args[@]}" || return
		fi

		run_process "Rebuild preserved packages" command --pretend-safe emerge "${pretend_args[@]}" @preserved-rebuild || return

		if [ ! "${pretend}" ]; then
			# Recompile all perl packages
			run_process "Update perl packages" command /usr/sbin/perl-cleaner --all -- "${color_args[@]}" -v --fail-clean y "${binary_args[@]}" "${pretend_args[@]}" || return

			if [ "${check:?}" = 'true' ]; then
				# Check system integrity: Reverse Dependency Rebuilder
				command revdep-rebuild -i -v -- -v "${color_args[@]}" --fail-clean y "${binary_args[@]}" "${pretend_args[@]}" || return

				# TODO: verify integrity of installed packages -> qcheck -B -v ; qcheck <package>
			fi
		fi

		if [ "${GLUS_AFTER_COMPILE}" ] && [ ! "${pretend}" ]; then
			# Execute command after all
			run_config_command "${GLUS_AFTER_COMPILE}" || return
		fi

		# Check and fix problems in the world file
		command --pretend-safe emaint "${pretend_args[@]}" world || return

		if [ "${clean:?}" = 'true' ]; then
			if [ "${#binary_args[@]}" -gt 0 ]; then
				command --pretend-safe eclean -C -d "${pretend_args[@]}" packages || return
			fi
			command --pretend-safe eclean -C -d "${pretend_args[@]}" distfiles || return
		fi
	fi

	# Check if they have changed any programs and need to reload
	change_versions

	if [ "${errors}" -ne 0 ]; then
		print_error "${errors} command(s) failed"
		return 1
	fi
}

main "${@-}"
