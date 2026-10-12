#!/bin/bash
#
# Gentoo Linux update system
#
# Version:    1.0.0
# Author:     Francisco Javier Félix Belmonte <ffelix@inode64.com>
# License:    MIT, https://opensource.org/licenses/MIT
# Repository: https://github.com/inode64/glus


export LC_ALL='C'

SYS_CONF_FILE="${ETCDIR-/etc}/portage/glus.conf"
errors=0

# Finalize exactly once, preserving failures and interrupted runs on disk.
cleanup() {
	local ret="${1:-$?}"
	trap '' TERM INT HUP
	trap - EXIT
	cancel_active_run
	finalize_run "${ret}"
	exit "${ret}"
}

install_traps() {
	trap cleanup EXIT
	trap 'cleanup 143' TERM
	trap 'cleanup 130' INT
	trap 'cleanup 129' HUP
}

# Leave build-directory cleanup to Portage's own locking protocol.
clean_portage_dir() {
	# A process check cannot protect against a build starting during rm.
	# Portage owns build-directory locking and cleanup; never remove them globally.
	STEP_SKIPPED='Build directories are managed by Portage'
	print_info "${STEP_SKIPPED}"
}

Last_binutils() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" = 'true' ] || [ "${debug:?}" = 'true' ]; then
		return 0
	fi

	# Let binutils-config select the newest profile for the native host.
	/usr/bin/binutils-config latest || return
	/usr/sbin/env-update || return

	# shellcheck disable=SC1091
	. /etc/profile || return

	return 0
}

Last_gcc() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" = 'true' ] || [ "${debug:?}" = 'true' ]; then
		return 0
	fi

	# Let gcc-config select the newest profile for the native host.
	/usr/bin/gcc-config latest || return
	/usr/sbin/env-update || return

	# shellcheck disable=SC1091
	. /etc/profile || return

	return 0
}

update_devel() {
	if [ "${fetch:?}" = 'true' ] || [ "${pretend}" = 'true' ] || [ "${debug:?}" = 'true' ]; then
		return
	fi

	etc-update -p || return

	Last_binutils || return
	Last_gcc || return

	# We update 2 times in case the new python does not exist yet
	eselect python update --python3 || return
	etc-update --automode -5 /etc/python-exec || return
	eselect python update --python3
}

# Parse command line options.
opt_parse() {
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
		'--qcheck' | '--no-qcheck')
			opt_arg_bool "${@-}"
			qcheck="${optArg:?}"
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
		'--slack-webhook' | '--notify' | '--log-dir' | '--log-retention-days' | '--fetch-attempts' | '--fetch-delay' | '--cancel-grace')
			opt_arg_str "$@"
			case "$1" in
			--slack-webhook) slack_webhook="${optArg}" ;;
			--notify) notify_mode="${optArg}" ;;
			--log-dir) log_dir="${optArg}" ;;
			--log-retention-days) log_retention="${optArg}" ;;
			--fetch-attempts) fetch_attempts="${optArg}" ;;
			--fetch-delay) fetch_delay="${optArg}" ;;
			--cancel-grace) cancel_grace="${optArg}" ;;
			esac
			shift "${optShift}"
			;;
		'--no-slack') slack_webhook='' ;;
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
			set -- "${optName:?}" "${optArg?}" "$@"
			continue
			;;
		# If an option did not match any pattern, an error is thrown.
		-? | --*) opt_die "Illegal option ${1:?}" ;;
		# If multiple short options in the form "-AB" are found, they are split into "-A" and "-B".
		-?*)
			opt_split_short "${@-}"
			shift
			set -- "${optAName:?}" "${optBName:?}" "$@"
			continue
			;;
		# Positional arguments are only supported after "--".
		*) opt_die "Illegal option ${1?}" ;;
		esac
		shift
	done
}

opt_split_short() {
	optAName="${1%"${1#??}"}"
	optBName="-${1#??}"
}

opt_split_equals() {
	optName="${1%="${1#--*=}"}"
	optArg="${1#--*=}"
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
}

opt_arg_bool() {
	if [ "${1#--no-}" = "${1:?}" ]; then
		optArg='true'
	else optArg='false'; fi
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
	     --[no-]qcheck, \${GLUS_QCHECK}
	        Verify installed package integrity with qcheck.
	        (default: ${qcheck?})%NL
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
	     --slack-webhook <URL>, --no-slack, \${GLUS_SLACK_WEBHOOK}
	        Send the final summary to a Slack incoming webhook. URL is never displayed.%NL
	     --notify <failures|always|never>, \${GLUS_NOTIFY}
	        Final email/Slack notification policy (default: ${notify_mode}).%NL
	     --log-dir <absolute path>, \${GLUS_LOG_DIR}
	        Persistent run logs (default: ${log_dir}).%NL
	     --log-retention-days <days>, \${GLUS_LOG_RETENTION_DAYS}
	        Keep completed runs for this many days; 0 keeps all (default: ${log_retention}).%NL
	     --fetch-attempts <count>, \${GLUS_FETCH_ATTEMPTS}
	        Total fetch attempts (default: ${fetch_attempts}).%NL
	     --fetch-delay <seconds>, \${GLUS_FETCH_DELAY}
	        Delay between fetch attempts (default: ${fetch_delay}).%NL
	     --cancel-grace <seconds>, \${GLUS_CANCEL_GRACE}
	        Grace period before killing remaining update processes (default: ${cancel_grace}).%NL
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
	local -a command_args

	config_command="${1-}"
	if [ ! "${config_command}" ]; then
		return 0
	fi

	parse_config_command hook "${config_command}" || return

	if [ "${#command_args[@]}" -eq 0 ]; then
		return 0
	fi

	command "${command_args[@]}"
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

# Split hook arguments without evaluating shell code or expansions.
# command_args is a local array in the caller, populated through Bash scope.
parse_config_command() {
	local name="${1:?}" value="${2-}"
	local char quote='' word='' escaped=false started=false i
	command_args=()

	case "${value}" in
	*[\;\|\&\<\>\`]* | *\$\(* | *$'\n'* | *$'\r'*)
		print_error "Invalid ${name}: shell operators are not supported. Use a wrapper script instead."
		return 1
		;;
	esac

	for ((i = 0; i < ${#value}; i++)); do
		char="${value:i:1}"
		if [ "${escaped}" = true ]; then
			# Within double quotes, backslashes only escape shell-special characters.
			if [ "${quote}" = '"' ] && [[ "${char}" != [\$\"\\] ]]; then
				word+="\\"
			fi
			word+="${char}"
			escaped=false
		elif [ "${quote}" = "'" ]; then
			if [ "${char}" = "'" ]; then quote=''; else word+="${char}"; fi
		elif [ "${char}" = "\\" ]; then
			escaped=true
			started=true
		elif [ "${quote}" = '"' ]; then
			if [ "${char}" = '"' ]; then quote=''; else word+="${char}"; fi
		else
			case "${char}" in
			"'" | '"') quote="${char}"; started=true ;;
			' ' | $'\t')
				if [ "${started}" = true ]; then
					command_args+=("${word}")
					word=''
					started=false
				fi
				;;
			*) word+="${char}"; started=true ;;
			esac
		fi
	done

	if [ -n "${quote}" ] || [ "${escaped}" = true ]; then
		print_error "Invalid ${name}: unbalanced quotes or unparseable value: ${value}"
		return 1
	fi
	if [ "${started}" = true ]; then command_args+=("${word}"); fi
	return 0
}

validate_config_command() {
	local name="${1:?}" value="${2-}"
	local -a command_args

	parse_config_command "${name}" "${value}" || return
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
	validate_bool GLUS_QCHECK "${qcheck}" || ret=1
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
	validate_choice GLUS_NOTIFY "${notify_mode}" failures always never || ret=1
	validate_integer GLUS_LOG_RETENTION_DAYS "${log_retention}" 0 36500 || ret=1
	validate_integer GLUS_FETCH_ATTEMPTS "${fetch_attempts}" 1 100 || ret=1
	validate_integer GLUS_FETCH_DELAY "${fetch_delay}" 0 86400 || ret=1
	validate_integer GLUS_CANCEL_GRACE "${cancel_grace}" 0 300 || ret=1
	if [[ "${log_dir}" != /* ]] || [[ "${log_dir}" == *[$'\n\r\t']* ]]; then
		print_error 'GLUS_LOG_DIR must be an absolute path without control whitespace'
		ret=1
	fi
	if [ -n "${slack_webhook}" ]; then
		if [[ ! "${slack_webhook}" =~ ^https://hooks\.slack(-gov)?\.com/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$ ]]; then
			print_error 'Invalid Slack incoming webhook URL (value hidden)'
			ret=1
		elif [ "${notify_mode}" != never ] && ! builtin command -v curl >/dev/null; then
			print_error 'curl is required for Slack notifications'
			ret=1
		fi
	fi

	validate_config_command GLUS_BEFORE_SYNC "${GLUS_BEFORE_SYNC-}" || ret=1
	validate_config_command GLUS_AFTER_SYNC "${GLUS_AFTER_SYNC-}" || ret=1
	validate_config_command GLUS_BEFORE_COMPILE "${GLUS_BEFORE_COMPILE-}" || ret=1
	validate_config_command GLUS_AFTER_COMPILE "${GLUS_AFTER_COMPILE-}" || ret=1

	return "${ret}"
}

validate_integer() {
	local name="$1" value="$2" minimum="$3" maximum="$4"
	if [[ "${value}" =~ ^(0|[1-9][0-9]{0,5})$ ]] && ((value >= minimum && value <= maximum)); then
		return 0
	fi
	print_error "Invalid ${name}: expected an integer from ${minimum} to ${maximum}"
	return 1
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
	if [ "${fetch:?}" = 'true' ]; then
		return 0
	fi

	if [ "${pretend}" != 'true' ] || [ "${debug:?}" = 'true' ]; then
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
	local command_flags count_errors fetch_ok try emerge ret
	local -a emerge_args

	command_flags=()
	count_errors='true'
	if [ "${1-}" = '--no-error-count' ]; then
		command_flags=(--no-error-count)
		count_errors='false'
		shift
	fi

	# Update binutils, gcc
	command --discard-output "${command_flags[@]}" update_devel || return

	if ! emerge=$(find_emerge); then
		if [ "${count_errors}" = 'true' ]; then
			((++errors))
		fi
		return 1
	fi
	build_emerge_args
	try=1

	if [ "${pretend}" != 'true' ]; then
		# First try download all files
		fetch_ok='false'
		while true; do
			if command --no-error-count "${emerge}" -f -1 --keep-going --fail-clean y "${emerge_args[@]}" "$@"; then
				fetch_ok='true'
				break
			else
				ret=$?
			fi

			[ "${try}" -lt "${fetch_attempts:-3}" ] || break
			fetch_retryable "${ret}" || break
			print_warn "Fetch attempt ${try}/${fetch_attempts:-3} failed; retrying in ${fetch_delay:-300}s"
			[ -z "${LOGS-}" ] || printf 'Fetch retry after exit %s; delay %ss\n' "${ret}" "${fetch_delay:-300}" >>"${LOGS}/retries.log"
			sleep "${fetch_delay:-300}" || return
			((++try))
		done

		if [ "${fetch_ok}" != 'true' ]; then
			print_error "Failed to fetch packages: $(format_command "$@")"
			if [ "${count_errors}" = 'true' ]; then
				((++errors))
			fi
			return "${ret}"
		fi
	fi

	if [ "${fetch:?}" = 'false' ]; then
		# Compile
		command --pretend-safe "${command_flags[@]}" "${emerge}" -v -1 --keep-going --fail-clean y "${emerge_args[@]}" "$@" || return

		# Update broken merges
		command --pretend-safe "${command_flags[@]}" emaint "${emaint_args[@]}" --yes merges || return

		# Update binutils, gcc
		command --discard-output "${command_flags[@]}" update_devel || return
	fi

	return 0
}

fetch_retryable() {
	# Portage uses exit 1 for several causes, including transient download errors.
	# Known invocation failures and signal exits must never be retried.
	case "$1" in 2 | 126 | 127) return 1 ;; esac
	[ "$1" -lt 128 ] || return 1
	if [ -n "${LAST_COMMAND_LOG-}" ] && [ -f "${LAST_COMMAND_LOG}" ]; then
		if grep -Eq 'Invalid atom|is not a valid package atom|unrecognized arguments:|no such option:' "${LAST_COMMAND_LOG}"; then
			return 1
		fi
	fi
	return 0
}

command() {
	local count_errors discard_output err run_in_pretend temp_file command_started
	local -a pipeline_status

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

	if [ "${pretend}" = 'true' ] && [ "${run_in_pretend}" != 'true' ]; then
		print_info "Skipping command in pretend mode"
		return 0
	fi

	if ! temp_file=$(mktemp "${LOGS}/command-${CURRENT_STEP_ID:-standalone}-XXXXXX.log"); then
		print_error 'Unable to create a command log; command was not executed'
		return 1
	fi
	LAST_COMMAND_LOG="${temp_file}"
	command_started=$SECONDS
	printf 'Step: %s\nCommand: %s\nStatus: running\n' "${CURRENT_STEP_ID:-standalone}" "$(format_command "$@")" >"${temp_file}.meta" || return

	if [ "${discard_output}" = 'true' ] || [ "${quiet:?}" = 'true' ]; then
		"$@" &>"${temp_file}"
		err=$?
	else
		"$@" 2>&1 | tee "${temp_file}"
		pipeline_status=("${PIPESTATUS[@]}")
		err=${pipeline_status[0]}
		if [ "${err}" -eq 0 ] && [ "${pipeline_status[1]}" -ne 0 ]; then
			err=${pipeline_status[1]}
			print_error 'Unable to save command output'
		fi
	fi
	printf 'Exit: %s\nDuration: %ss\n' "${err}" "$((SECONDS - command_started))" >>"${temp_file}.meta"
	printf '%s\t%s\t%s\t%s\t%s\n' "${err}" "${temp_file##*/}" "$((SECONDS - command_started))" "${CURRENT_STEP_ID:-standalone}" "$(format_command "$@")" >>"${LOGS}/commands.tsv"

	if [ "${err}" -ne 0 ]; then
		print_error "Command failed (exit ${err}): $(format_command "$@")"
		if [ "${quiet:?}" = 'true' ] || [ "${discard_output}" = 'true' ]; then
			if [ -f "${temp_file}" ]; then
				tail -n1000 "${temp_file}" >&2
			fi
		fi
		if [ "${count_errors}" = 'true' ]; then
			((++errors))
		fi
	fi

	return "${err}"
}

# Plan arguments are stored as arrays, never as executable shell strings.
add_step() {
	PLAN_TITLES+=("$1")
	PLAN_FUNCTIONS+=("$2")
	shift 2
	PLAN_OFFSETS+=("${#PLAN_ARGUMENTS[@]}")
	PLAN_COUNTS+=("$#")
	PLAN_ARGUMENTS+=("$@")
}

skip_step() {
	STEP_SKIPPED="$1"
	print_info "Skipped: $1"
}

build_plan() {
	PLAN_TITLES=() PLAN_FUNCTIONS=() PLAN_OFFSETS=() PLAN_COUNTS=() PLAN_ARGUMENTS=()
	local -a sets=("${package_args[@]}")
	if [ "${sync}" = true ] && [ "${pretend}" != true ]; then
		[ -z "${GLUS_BEFORE_SYNC-}" ] || add_step 'Before sync hook' run_config_command "${GLUS_BEFORE_SYNC}"
		add_step 'Sync portage' command emaint -a sync
		[ -z "${GLUS_AFTER_SYNC-}" ] || add_step 'After sync hook' run_config_command "${GLUS_AFTER_SYNC}"
	else
		add_step 'Sync portage' skip_step 'Disabled or pretend mode'
	fi
	if [ "${pretend}" != true ] && [ "${fetch}" != true ]; then
		[ -z "${GLUS_BEFORE_COMPILE-}" ] || add_step 'Before compile hook' run_config_command "${GLUS_BEFORE_COMPILE}"
		add_step 'Portage build directories' clean_portage_dir
		add_step 'Merge Portage configuration' etc_update_portage
	fi
	add_step 'Update portage' compile -u portage
	add_step 'Check crypt headers' ensure_crypt
	[ "${system}" != true ] || add_step 'Update system' update_system
	if [ "${world}" = true ]; then
		add_step 'Update world' compile -uDN world --complete-graph=y --with-bdeps=y
	elif [ "${full}" = true ]; then
		add_step 'Rebuild world' compile -ueDN world --complete-graph=y --with-bdeps=y
	else
		[ "${live}" != true ] || add_step 'Update live packages' compile @live-rebuild
		[ "${security}" != true ] || sets+=(@security)
		[ "${go}" != true ] || sets+=(@golang-rebuild)
		[ "${modules}" != true ] || sets+=(@modules-rebuild)
		if [ "${#sets[@]}" -gt 0 ]; then
			add_step 'Update sets' compile -u "${sets[@]}"
		else
			add_step 'Optional package sets' skip_step 'No package sets selected'
		fi
	fi
	if [ "${fetch}" != true ]; then
		[ "${clean}" != true ] || add_step 'Remove unused packages' emerge_action --depclean
		add_step 'Rebuild preserved packages' emerge_action @preserved-rebuild
		if [ "${pretend}" != true ]; then
			add_step 'Update Perl packages' rebuild_perl
			if [ "${check}" = true ]; then
				add_step 'Check reverse dependencies' rebuild_dependencies
				[ "${qcheck}" != true ] || add_step 'Check package integrity' command qcheck -B -P -v
			fi
			[ -z "${GLUS_AFTER_COMPILE-}" ] || add_step 'After compile hook' run_config_command "${GLUS_AFTER_COMPILE}"
		fi
		add_step 'Maintain world metadata' command --pretend-safe emaint "${emaint_args[@]}" world
		if [ "${clean}" = true ]; then
			[ "${#binary_args[@]}" -eq 0 ] || add_step 'Clean binary archives' command --pretend-safe eclean -C -d "${pretend_args[@]}" packages
			add_step 'Clean source archives' command --pretend-safe eclean -C -d "${pretend_args[@]}" distfiles
		fi
		add_step 'Check systemd version' change_versions
	fi
}

ensure_crypt() {
	if [ -e /usr/include/crypt.h ]; then
		skip_step 'crypt.h is present'
	else
		compile -1u sys-libs/libxcrypt
	fi
}

update_system() {
	if [ "${dry_run-false}" = true ] || [ "${debug-false}" = true ]; then
		print_info 'Conditional fallback: retry with basic system update (-u system) if the full update fails'
	fi
	if compile --no-error-count -uDN system; then
		return 0
	fi
	print_warn 'Full system update failed, trying basic system update'
	compile -u system
}

# All emerge callers use the same option builder. Resolve the wrapper again
# after each toolchain update because the Python interpreter may have changed.
build_emerge_args() {
	emerge_args=("${color_args[@]}" "${exclude_args[@]}" "${emerge_opts_args[@]}" "${binary_args[@]}" "${pretend_args[@]}")
}

emerge_action() {
	local emerge
	local -a emerge_args
	emerge=$(find_emerge) || return
	build_emerge_args
	command --pretend-safe "${emerge}" "${emerge_args[@]}" "$@"
}

rebuild_perl() {
	local -a emerge_args
	build_emerge_args
	command /usr/sbin/perl-cleaner --all -- -v --fail-clean y "${emerge_args[@]}"
}

rebuild_dependencies() {
	local -a emerge_args
	build_emerge_args
	command revdep-rebuild -i -v -- -v --fail-clean y "${emerge_args[@]}"
}

record_step() {
	[ -n "${LOGS-}" ] || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"${LOGS}/steps.tsv"
}

execute_plan() {
	local i j offset count started duration ret status
	local -a args
	for ((i = 0; i < ${#PLAN_TITLES[@]}; i++)); do
		offset="${PLAN_OFFSETS[i]}" count="${PLAN_COUNTS[i]}"
		args=("${PLAN_ARGUMENTS[@]:offset:count}")
		STEP_SKIPPED=''
		CURRENT_STEP_ID="${i}"
		started=$SECONDS
		if [ -n "${LOGS-}" ]; then printf '%s\t%s\n' "${i}" "${started}" >"${LOGS}/active-step"; fi
		start_process "${PLAN_TITLES[i]}"
		"${PLAN_FUNCTIONS[i]}" "${args[@]}"
		ret=$?
		duration=$((SECONDS - started))
		stop_process
		status=completed
		[ -z "${STEP_SKIPPED}" ] || status=skipped
		[ "${ret}" -eq 0 ] || status=failed
		record_step "${i}" "${status}" "${ret}" "${duration}" "${PLAN_TITLES[i]}"
		if [ -n "${LOGS-}" ]; then : >"${LOGS}/active-step"; fi
		if [ "${ret}" -ne 0 ]; then
			for ((j = i + 1; j < ${#PLAN_TITLES[@]}; j++)); do
				record_step "${j}" skipped 0 0 "${PLAN_TITLES[j]} (previous step failed)"
			done
			return "${ret}"
		fi
	done
	return 0
}

initialize_run() {
	local old_umask
	if ! builtin command -v flock >/dev/null; then
		print_error 'flock is required'
		return 1
	fi
	if [ -d /run/lock ] && [ -w /run/lock ]; then
		LOCK_FILE=/run/lock/glus.lock
	else
		LOCK_FILE="${TMPDIR:-/tmp}/glus-${UID}.lock"
	fi
	LOCK_FILE="${GLUS_LOCK_FILE-${LOCK_FILE}}"
	if [[ "${LOCK_FILE}" != /* ]] || [ -L "${LOCK_FILE}" ]; then
		print_error 'Lock path must be absolute and must not be a symlink'
		return 1
	fi
	exec {LOCK_FD}>>"${LOCK_FILE}" || return
	if ! flock -n "${LOCK_FD}"; then
		print_error "Another glus run holds ${LOCK_FILE}"
		return 75
	fi
	old_umask=$(umask)
	umask 077
	if ! mkdir -p -- "${log_dir}" || ! LOGS=$(mktemp -d "${log_dir%/}/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX"); then
		umask "${old_umask}"
		print_error 'Unable to create the persistent run log directory'
		return 1
	fi
	if ! { : >"${LOGS}/.glus-run" && : >"${LOGS}/steps.tsv" && : >"${LOGS}/commands.tsv"; }; then
		umask "${old_umask}"
		print_error 'Unable to initialize the run logs'
		return 1
	fi
	umask "${old_umask}"
	RUN_STARTED=$SECONDS
	RUN_INITIALIZED=true
	RUN_FINALIZED=false
	install_traps
	prune_run_logs
	print_info "Run logs: ${LOGS}"
}

prune_run_logs() {
	local candidate
	[ "${log_retention}" -gt 0 ] || return 0
	while IFS= read -r -d '' candidate; do
		[ "${candidate}" != "${LOGS}" ] || continue
		if [ -f "${candidate}/.glus-run" ] && [ -f "${candidate}/summary.txt" ] && [ ! -L "${candidate}" ]; then
			rm -rf -- "${candidate}"
		fi
	done < <(find "${log_dir}" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mtime "+${log_retention}" -print0)
}

supervise_plan() {
	local ret
	# Job control gives the worker and its descendants a dedicated process group.
	set -m
	(set +m; trap - EXIT TERM INT HUP; execute_plan) </dev/null &
	ACTIVE_PID=$!
	set +m
	wait "${ACTIVE_PID}"
	ret=$?
	ACTIVE_PID=''
	finalize_run "${ret}"
	return "${ret}"
}

cancel_active_run() {
	local deadline
	[ -n "${ACTIVE_PID-}" ] || return 0
	kill -TERM -- "-${ACTIVE_PID}" 2>/dev/null || :
	deadline=$((SECONDS + ${cancel_grace:-10}))
	while kill -0 -- "-${ACTIVE_PID}" 2>/dev/null && ((SECONDS < deadline)); do
		sleep 0.1
	done
	kill -KILL -- "-${ACTIVE_PID}" 2>/dev/null || :
	wait "${ACTIVE_PID}" 2>/dev/null || :
	ACTIVE_PID=''
}

finalize_run() {
	local ret="$1" status=success duration index state code seconds title count=0
	local active_index active_started active_duration=0
	local completed=0 failed=0 skipped=0
	[ "${RUN_INITIALIZED-false}" = true ] && [ "${RUN_FINALIZED-false}" != true ] || return 0
	RUN_FINALIZED=true
	[ "${ret}" -eq 0 ] || status=failed
	case "${ret}" in 129 | 130 | 143) status=interrupted ;; esac
	duration=$((SECONDS - RUN_STARTED))
	if [ -s "${LOGS}/active-step" ]; then
		IFS=$'\t' read -r active_index active_started <"${LOGS}/active-step"
		if [[ "${active_index}" =~ ^[0-9]+$ && "${active_started}" =~ ^[0-9]+$ ]]; then active_duration=$((SECONDS - active_started)); fi
	fi
	# A killed worker cannot write its final step result. Complete the manifest here.
	while IFS=$'\t' read -r index state code seconds title; do
		((++count))
		case "${state}" in completed) ((++completed)) ;; failed) ((++failed)) ;; skipped) ((++skipped)) ;; esac
	done <"${LOGS}/steps.tsv"
	for ((index = count; index < ${#PLAN_TITLES[@]}; index++)); do
		if [ "${index}" -eq "${count}" ]; then
			record_step "${index}" "${status}" "${ret}" "${active_duration}" "${PLAN_TITLES[index]}"
			((++failed))
		else
			record_step "${index}" skipped 0 0 "${PLAN_TITLES[index]} (run stopped)"
			((++skipped))
		fi
	done
	{
		printf 'GLUS on %s: %s (exit %s)\n' "$(hostname)" "${status}" "${ret}"
		printf 'Duration: %ss\nCompleted: %s; failed/interrupted: %s; skipped: %s\n' "${duration}" "${completed}" "${failed}" "${skipped}"
		printf 'Logs: %s\n' "${LOGS}"
		while IFS=$'\t' read -r index state code seconds title; do
			printf '  %s: %s (%ss, exit %s)\n' "${state}" "${title}" "${seconds}" "${code}"
		done <"${LOGS}/steps.tsv"
	} >"${LOGS}/summary.txt"
	cat "${LOGS}/summary.txt"
	notify_run "${ret}"
	return 0
}

json_string() {
	local value="$1" char i ordinal
	printf '"'
	for ((i = 0; i < ${#value}; i++)); do
		char="${value:i:1}"
		case "${char}" in
		'"') printf '\\"' ;;
		"\\") printf '%s%s' "\\" "\\" ;;
		*)
			printf -v ordinal '%d' "'${char}"
			if ((ordinal < 32)); then printf '\\u%04x' "${ordinal}"; else printf '%s' "${char}"; fi
			;;
		esac
	done
	printf '"'
}

notify_run() {
	local ret="$1" message response
	[ "${dry_run-false}" != true ] && [ "${debug-false}" != true ] && [ "${pretend-false}" != true ] || return 0
	[ "${notify_mode-failures}" != never ] || return 0
	[ "${notify_mode-failures}" = always ] || [ "${ret}" -ne 0 ] || return 0
	if [ -n "${email-}" ]; then
		if ! mailx -s "GLUS result on $(hostname): exit ${ret}" "${email}" <"${LOGS}/summary.txt"; then
			print_warn 'Email notification failed; update exit status is unchanged'
			printf 'Email: failed\n' >>"${LOGS}/notifications.log"
		else
			printf 'Email: sent\n' >>"${LOGS}/notifications.log"
		fi
	fi
	[ -n "${slack_webhook-}" ] || return 0
	# Plain text blocks prevent log paths/titles from becoming Slack mentions.
	message=$(head -n4 "${LOGS}/summary.txt")
	{
		printf '{"blocks":[{"type":"section","text":{"type":"plain_text","text":'
		json_string "${message}"
		printf '}}]}'
	} >"${LOGS}/slack.json"
	# Feed the secret through stdin, not argv or the command logger. No redirects
	# or automatic retries: an ambiguous response must not duplicate a message.
	if response=$(printf 'url = "%s"\n' "${slack_webhook}" | curl --disable --config - --silent --fail --proto '=https' --connect-timeout 10 --max-time 20 --header 'Content-Type: application/json' --data-binary "@${LOGS}/slack.json" 2>/dev/null) && [ "${response}" = ok ]; then
		printf 'Slack: sent\n' >>"${LOGS}/notifications.log"
	else
		print_warn 'Slack notification failed; update exit status is unchanged'
		printf 'Slack: failed\n' >>"${LOGS}/notifications.log"
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

	if [ "${pretend}" = 'true' ] || [ "${debug:?}" = 'true' ]; then
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
	local -a binary_args color_args emaint_args emerge_opts_args exclude_args package_args pretend_args

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

	# Verify installed package integrity with qcheck
	qcheck="${GLUS_QCHECK-"false"}"

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

	log_dir="${GLUS_LOG_DIR:-/var/log/glus}"
	log_retention="${GLUS_LOG_RETENTION_DAYS-30}"
	fetch_attempts="${GLUS_FETCH_ATTEMPTS-3}"
	fetch_delay="${GLUS_FETCH_DELAY-300}"
	cancel_grace="${GLUS_CANCEL_GRACE-10}"
	slack_webhook="${GLUS_SLACK_WEBHOOK-}"
	notify_mode="${GLUS_NOTIFY-failures}"
	# The webhook must not be inherited by package builds or hooks.
	unset GLUS_SLACK_WEBHOOK

	# Parse command line options.
	opt_parse "$@"
	# shellcheck disable=SC2086
	set -- ${posArgs-}

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

	# Build the pretend flag array used by emerge-family commands.
	if [ "${pretend:?}" = 'true' ]; then
		pretend_args=(-p)
		emaint_args=(--check)
	else
		pretend_args=()
		emaint_args=(--fix)
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

	# Check the binary package option. validate_config guarantees the value
	# is one of: false|true|only|auto|autoonly.
	case "${binary:?}" in
	'false') binary_args=() ;;
	'true') binary_args=(-k) ;;
	'only') binary_args=(-K) ;;
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
	esac

	build_plan
	if [ "${dry_run}" = true ] || [ "${debug}" = true ]; then
		execute_plan
		return
	fi

	initialize_run || return
	get_versions
	supervise_plan
}

main "$@"
