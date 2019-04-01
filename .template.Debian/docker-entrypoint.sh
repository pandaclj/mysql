#!/bin/bash
set -eo pipefail
shopt -s nullglob

# logging functions
docker_log() {
	local type=$1;shift
	printf "$(date --rfc-3339=seconds) [${type}] [Entrypoint]: $@\n"
}
docker_note() {
	docker_log Note "$@"
}
docker_warn() {
	docker_log Warn "$@" >&2
}
docker_error() {
	docker_log ERROR "$@" >&2
	exit 1
}

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

# usage: docker_file_env VAR [DEFAULT]
#    ie: docker_file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
docker_file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		docker_error "Both $var and $fileVar are set (but are exclusive)"
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# usage: docker_process_init_file FILENAME MYSQLCOMMAND...
#    ie: docker_process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
docker_process_init_file() {
	local f="$1"; shift
	local mysql=( "$@" )

	case "$f" in
		*.sh)     docker_note "$0: running $f"; . "$f" ;;
		*.sql)    docker_note "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
		*.sql.gz) docker_note "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
		*)        docker_warn "$0: ignoring $f" ;;
	esac
	echo
}

mysql_check_config() {
	toRun=( "$@" --verbose --help )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		docker_error "mysqld failed while attempting to check config\n\tcommand was: ${toRun[*]}\n\t$errors"
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
docker_get_config() {
	local conf="$1"; shift
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
		| awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

# Do a temporary startup of the MySQL server, for init purposes
docker_start_server() {
	result=0
	%%SERVERSTARTUP%%
	if [ "$result" != "0" ];then
		docker_error "Unable to start server. Status code $result."
	fi
}

# Wait for the temporary server to be ready for connections.
# It is only used for versions older than 5.7
docker_wait_for_server() {
	local mysql=( "$@" )
	for i in {30..0}; do
		if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
			break
		fi
		sleep 1
	done
	if [ "$i" = 0 ]; then
		docker_error "Unable to start server."
	fi
}

# Stop the server. When using a local socket file mysqladmin will block until
# the shutdown is complete.
docker_stop_server() {
	result=0
	mysqladmin --defaults-extra-file="${PASSFILE}" shutdown -uroot --socket="${SOCKET}" || result=$?
	if [ "$result" != "0" ]; then
		docker_error "Unable to shut down server. Status code $result."
	fi
}

# Verify that the minimally required password settings are set for new databases.
docker_verify_env() {
	if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		docker_error "Database is uninitialized and password option is not specified \n\tYou need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD"
	fi
}

# Creates and initializes the database directory
docker_init_database_dir() {
	mkdir -p "$DATADIR"

	docker_note "Initializing database files"
	%%DATABASEINIT%%
	docker_note "Database files initialized"

	if command -v mysql_ssl_rsa_setup > /dev/null && [ ! -e "$DATADIR/server-key.pem" ]; then
		# https://github.com/mysql/mysql-server/blob/23032807537d8dd8ee4ec1c4d40f0633cd4e12f9/packaging/deb-in/extra/mysql-systemd-start#L81-L84
		docker_note "Initializing certificates"
		mysql_ssl_rsa_setup --datadir="$DATADIR"
		docker_note "Certificates initialized"
	fi
}

# Loads various settings that are used elsewhere in the script
docker_init_env() {
	# Get config
	DATADIR="$(docker_get_config 'datadir' "$@")"
	SOCKET="$(docker_get_config 'socket' "$@")"
	
	# We create a file to store the root password in so we don''t use it on the command line
	TMPDIR="$(mktemp -d)"
	PASSFILE="$(mktemp ${TMPDIR}/XXXXXXXXXX)"
	
	# Initialize values that might be stored in a file
	docker_file_env 'MYSQL_ROOT_HOST' '%'
	docker_file_env 'MYSQL_DATABASE'
	docker_file_env 'MYSQL_USER'
	docker_file_env 'MYSQL_PASSWORD'
	docker_file_env 'MYSQL_ROOT_PASSWORD'
}

# Define the client command that's used in various places
docker_init_client_command() {
	mysql=( mysql --defaults-file="${PASSFILE}" --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )
}

# Store root password in a file for use with the client command
docker_write_password_file() {
	# Write the password to the file the client uses
	if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
		cat >"${PASSFILE}" <<EOF
[client]
password="${MYSQL_ROOT_PASSWORD}"
EOF
	fi
}

# Sets root password and creates root users for non-localhost hosts
docker_init_root_user() {
	rootCreate=
	# default root to listen for connections from anywhere
	if [ ! -z "$MYSQL_ROOT_HOST" -a "$MYSQL_ROOT_HOST" != 'localhost' ]; then
		# no, we don't care if read finds a terminating character in this heredoc
		# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
		read -r -d '' rootCreate <<-EOSQL || true
			CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
		EOSQL
	fi

	"${mysql[@]}" <<-EOSQL
		-- What's done in this file shouldn't be replicated
		--  or products like mysql-fabric won't work
		SET @@SESSION.SQL_LOG_BIN=0;

		%%PASSWORDSET%%
		GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
		${rootCreate}
		DROP DATABASE IF EXISTS test ;
		FLUSH PRIVILEGES ;
	EOSQL
}

# Creates a custom database and user if specified
docker_init_database_user() {
	if [ "$MYSQL_DATABASE" ]; then
		docker_note "Creating database ${MYSQL_DATABASE}"
		echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
		mysql+=( "$MYSQL_DATABASE" )
	fi

	if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
		docker_note "Creating user ${MYSQL_USER}"
		echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

		if [ "$MYSQL_DATABASE" ]; then
			echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
		fi

		echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
	fi
}

# Mark root user as expired so the password must be changed before anything
# else can be done (only supported for 5.6+)
docker_expire_root_user() {
	if [ "${MYSQL_MAJOR}" = "5.5" ]; then
		_warn "MySQL 5.5 does not support PASSWORD EXPIRE (required for MYSQL_ONETIME_PASSWORD)"
	else
		"${mysql[@]}" <<-EOSQL
			ALTER USER 'root'@'%' PASSWORD EXPIRE;
		EOSQL
	fi
}

# Generate a random root password
docker_generate_root_password() {
	export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
	docker_note "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
}

# Load timezone info into database
docker_load_tzinfo() {
	# sed is for https://bugs.mysql.com/bug.php?id=20545
	mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
}

docker_main() {
	docker_note "Entrypoint script for MySQL Server ${MYSQL_VERSION} started."

	if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
		# Load various environment variables
		docker_init_env "$@"

		# If container is started as root user, restart as dedicated mysql user
		if [ "$(id -u)" = '0' ]; then
			mysql_check_config "$@"
			mkdir -p "$DATADIR"
			chown -R mysql:mysql "$DATADIR"
			docker_note "Switching to dedicated user 'mysql'"
			exec gosu mysql "$BASH_SOURCE" "$@"
		fi

		# still need to check config, container may have started with --user
		mysql_check_config "$@"

		# If this is true then there's no database, and it needs to be initialized
		if [ ! -d "$DATADIR/mysql" ]; then
			docker_verify_env
			docker_init_database_dir "$@"
			docker_init_client_command

			docker_note "Starting temporary server"
			docker_start_server "$@"
			# For 5.7+ the server is ready for use as soon as startup command unblocks
			if [ "${MYSQL_MAJOR}" = "5.5" ] || [ "${MYSQL_MAJOR}" = "5.6" ]; then
				docker_note "Waiting for server startup"
				docker_wait_for_server "${mysql[@]}"
			fi
			docker_note "Temporary server started."


			if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
				docker_load_tzinfo
			fi

			if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
				docker_generate_root_password
			fi

			docker_init_root_user

			docker_write_password_file

			docker_init_database_user

			echo
			for f in /docker-entrypoint-initdb.d/*; do
				docker_process_init_file "$f" "${mysql[@]}"
			done

			if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
				docker_expire_root_user
			fi
			docker_note "Stopping temporary server"
			docker_stop_server
			docker_note "Temporary server stopped"

			# Remove the password file now that initialization is complete
			rm -f "${PASSFILE}"
			unset PASSFILE
			echo
			docker_note "MySQL init process done. Ready for start up."
			echo
		fi
	fi
	exec "$@"
}
# This checks if the script has been sourced from elsewhere.
# If so we don't perform any further actions
if [ "${FUNCNAME[${#FUNCNAME[@]} - 1]}" != 'source' ]; then
	docker_main "$@"
fi
