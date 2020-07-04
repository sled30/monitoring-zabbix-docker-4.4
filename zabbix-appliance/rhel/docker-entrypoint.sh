#!/bin/bash

set -o pipefail

set +e

# Script trace mode
if [ "${DEBUG_MODE}" == "true" ]; then
    set -o xtrace
fi

# Default Zabbix installation name
# Used only by Zabbix web-interface
: ${ZBX_SERVER_NAME:="Zabbix docker"}

# Default timezone for web interface
: ${PHP_TZ:="Europe/Riga"}

# Default directories
# User 'zabbix' home directory
ZABBIX_USER_HOME_DIR="/var/lib/zabbix"
# Configuration files directory
ZABBIX_ETC_DIR="/etc/zabbix"
# Web interface www-root directory
ZBX_FRONTEND_PATH="/usr/share/zabbix"

# usage: file_env VAR [DEFAULT]
# as example: file_env 'MYSQL_PASSWORD' 'zabbix'
#    (will allow for "$MYSQL_PASSWORD_FILE" to fill in the value of "$MYSQL_PASSWORD" from a file)
# unsets the VAR_FILE afterwards and just leaving VAR
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local defaultValue="${2:-}"

    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo "**** Both variables $var and $fileVar are set (but are exclusive)"
        exit 1
    fi

    local val="$defaultValue"

    if [ "${!var:-}" ]; then
        val="${!var}"
        echo "** Using ${var} variable from ENV"
    elif [ "${!fileVar:-}" ]; then
        if [ ! -f "${!fileVar}" ]; then
            echo "**** Secret file \"${!fileVar}\" is not found"
            exit 1
        fi
        val="$(< "${!fileVar}")"
        echo "** Using ${var} variable from secret file"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

configure_db_mysql() {
    [ "${DB_SERVER_HOST}" != "localhost" ] && return

    echo "** Configuring local MySQL server"

    MYSQL_ALLOW_EMPTY_PASSWORD=true
    MYSQL_DATA_DIR="/var/lib/mysql"

    MYSQL_CONF_FILE="/etc/my.cnf.d/mariadb-server.cnf"
    DB_SERVER_SOCKET="/var/lib/mysql/mysql.sock"

    MYSQLD=/usr/libexec/mysqld

    sed -Ei 's/^(bind-address|log)/#&/' "$MYSQL_CONF_FILE"

    if [ ! -d "$MYSQL_DATA_DIR/mysql" ]; then
        [ -d "$MYSQL_DATA_DIR" ] || mkdir -p "$MYSQL_DATA_DIR"

        echo "** Installing initial MySQL database schemas"
        mysql_install_db --datadir="$MYSQL_DATA_DIR" 2>&1
    else
        echo "**** MySQL data directory is not empty. Using already existing installation."
    fi

    echo "** Starting MySQL server in background mode"

    nohup $MYSQLD --basedir=/usr --datadir=/var/lib/mysql --plugin-dir=/usr/lib/mysql/plugin \
            --log-output=none --pid-file=/var/lib/mysql/mysqld.pid \
            --port=3306 --character-set-server=utf8 --collation-server=utf8_bin &
}

prepare_system() {
    echo "** Preparing the system"

    DB_SERVER_HOST=${DB_SERVER_HOST:-"localhost"}

    configure_db_mysql
}

escape_spec_char() {
    local var_value=$1

    var_value="${var_value//\\/\\\\}"
    var_value="${var_value//[$'\n']/}"
    var_value="${var_value//\//\\/}"
    var_value="${var_value//./\\.}"
    var_value="${var_value//\*/\\*}"
    var_value="${var_value//^/\\^}"
    var_value="${var_value//\$/\\\$}"
    var_value="${var_value//\&/\\\&}"
    var_value="${var_value//\[/\\[}"
    var_value="${var_value//\]/\\]}"

    echo "$var_value"
}

update_config_var() {
    local config_path=$1
    local var_name=$2
    local var_value=$3
    local is_multiple=$4

    if [ ! -f "$config_path" ]; then
        echo "**** Configuration file '$config_path' does not exist"
        return
    fi

    echo -n "** Updating '$config_path' parameter \"$var_name\": '$var_value'... "

    # Remove configuration parameter definition in case of unset parameter value
    if [ -z "$var_value" ]; then
        sed -i -e "/^$var_name=/d" "$config_path"
        echo "removed"
        return
    fi

    # Remove value from configuration parameter in case of double quoted parameter value
    if [ "$var_value" == '""' ]; then
        sed -i -e "/^$var_name=/s/=.*/=/" "$config_path"
        echo "undefined"
        return
    fi

    # Use full path to a file for TLS related configuration parameters
    if [[ $var_name =~ ^TLS.*File$ ]]; then
        var_value=$ZABBIX_USER_HOME_DIR/enc/$var_value
    fi

    # Escaping characters in parameter value
    var_value=$(escape_spec_char "$var_value")

    if [ "$(grep -E "^$var_name=" $config_path)" ] && [ "$is_multiple" != "true" ]; then
        sed -i -e "/^$var_name=/s/=.*/=$var_value/" "$config_path"
        echo "updated"
    elif [ "$(grep -Ec "^# $var_name=" $config_path)" -gt 1 ]; then
        sed -i -e  "/^[#;] $var_name=$/i\\$var_name=$var_value" "$config_path"
        echo "added first occurrence"
    else
        sed -i -e "/^[#;] $var_name=/s/.*/&\n$var_name=$var_value/" "$config_path"
        echo "added"
    fi

}

update_config_multiple_var() {
    local config_path=$1
    local var_name=$2
    local var_value=$3

    var_value="${var_value%\"}"
    var_value="${var_value#\"}"

    local IFS=,
    local OPT_LIST=($var_value)

    for value in "${OPT_LIST[@]}"; do
        update_config_var $config_path $var_name $value true
    done
}

# Check prerequisites for MySQL database
check_variables_mysql() {
    DB_SERVER_HOST=${DB_SERVER_HOST:-"mysql-server"}
    DB_SERVER_PORT=${DB_SERVER_PORT:-"3306"}
    USE_DB_ROOT_USER=false
    CREATE_ZBX_DB_USER=false
    file_env MYSQL_USER
    file_env MYSQL_PASSWORD

    if [ "$type" != "" ]; then
        file_env MYSQL_ROOT_PASSWORD
    fi

    if [ ! -n "${MYSQL_USER}" ] && [ "${MYSQL_RANDOM_ROOT_PASSWORD}" == "true" ]; then
        echo "**** Impossible to use MySQL server because of unknown Zabbix user and random 'root' password"
        exit 1
    fi

    if [ ! -n "${MYSQL_USER}" ] && [ ! -n "${MYSQL_ROOT_PASSWORD}" ] && [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" != "true" ]; then
        echo "*** Impossible to use MySQL server because 'root' password is not defined and it is not empty"
        exit 1
    fi

    if [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || [ -n "${MYSQL_ROOT_PASSWORD}" ]; then
        USE_DB_ROOT_USER=true
        DB_SERVER_ROOT_USER="root"
        DB_SERVER_ROOT_PASS=${MYSQL_ROOT_PASSWORD:-""}
    fi

    [ -n "${MYSQL_USER}" ] && CREATE_ZBX_DB_USER=true

    # If root password is not specified use provided credentials
    DB_SERVER_ROOT_USER=${DB_SERVER_ROOT_USER:-${MYSQL_USER}}
    [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || DB_SERVER_ROOT_PASS=${DB_SERVER_ROOT_PASS:-${MYSQL_PASSWORD}}
    DB_SERVER_ZBX_USER=${MYSQL_USER:-"zabbix"}
    DB_SERVER_ZBX_PASS=${MYSQL_PASSWORD:-"zabbix"}

    DB_SERVER_DBNAME=${MYSQL_DATABASE:-"zabbix"}
}

check_db_connect() {
    echo "********************"
    echo "* DB_SERVER_HOST: ${DB_SERVER_HOST}"
    echo "* DB_SERVER_PORT: ${DB_SERVER_PORT}"
    echo "* DB_SERVER_DBNAME: ${DB_SERVER_DBNAME}"
    if [ "${DEBUG_MODE}" == "true" ]; then
        if [ "${USE_DB_ROOT_USER}" == "true" ]; then
            echo "* DB_SERVER_ROOT_USER: ${DB_SERVER_ROOT_USER}"
            echo "* DB_SERVER_ROOT_PASS: ${DB_SERVER_ROOT_PASS}"
        fi
        echo "* DB_SERVER_ZBX_USER: ${DB_SERVER_ZBX_USER}"
        echo "* DB_SERVER_ZBX_PASS: ${DB_SERVER_ZBX_PASS}"
        echo "********************"
    fi
    echo "********************"

    WAIT_TIMEOUT=5

    while [ ! "$(mysqladmin ping -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} -u ${DB_SERVER_ROOT_USER} \
                --password="${DB_SERVER_ROOT_PASS}" --silent --connect_timeout=10)" ]; do
        echo "**** MySQL server is not available. Waiting $WAIT_TIMEOUT seconds..."
        sleep $WAIT_TIMEOUT
    done
}

mysql_query() {
    query=$1
    local result=""

    result=$(mysql --silent --skip-column-names -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} \
             -u ${DB_SERVER_ROOT_USER} --password="${DB_SERVER_ROOT_PASS}" -e "$query")

    echo $result
}

create_db_user_mysql() {
    [ "${CREATE_ZBX_DB_USER}" == "true" ] || return

    echo "** Creating '${DB_SERVER_ZBX_USER}' user in MySQL database"

    USER_EXISTS=$(mysql_query "SELECT 1 FROM mysql.user WHERE user = '${DB_SERVER_ZBX_USER}' AND host = '%'")

    if [ -z "$USER_EXISTS" ]; then
        mysql_query "CREATE USER '${DB_SERVER_ZBX_USER}'@'%' IDENTIFIED BY '${DB_SERVER_ZBX_PASS}'" 1>/dev/null
    else
        mysql_query "ALTER USER ${DB_SERVER_ZBX_USER} IDENTIFIED BY '${DB_SERVER_ZBX_PASS}';" 1>/dev/null
    fi

    mysql_query "GRANT ALL PRIVILEGES ON $DB_SERVER_DBNAME. * TO '${DB_SERVER_ZBX_USER}'@'%'" 1>/dev/null
}

create_db_database_mysql() {
    DB_EXISTS=$(mysql_query "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_SERVER_DBNAME}'")

    if [ -z ${DB_EXISTS} ]; then
        echo "** Database '${DB_SERVER_DBNAME}' does not exist. Creating..."
        mysql_query "CREATE DATABASE ${DB_SERVER_DBNAME} CHARACTER SET utf8 COLLATE utf8_bin" 1>/dev/null
        # better solution?
        mysql_query "GRANT ALL PRIVILEGES ON $DB_SERVER_DBNAME. * TO '${DB_SERVER_ZBX_USER}'@'%'" 1>/dev/null
    else
        echo "** Database '${DB_SERVER_DBNAME}' already exists. Please be careful with database COLLATE!"
    fi
}

create_db_schema_mysql() {
    DBVERSION_TABLE_EXISTS=$(mysql_query "SELECT 1 FROM information_schema.tables WHERE table_schema='${DB_SERVER_DBNAME}' and table_name = 'dbversion'")

    if [ -n "${DBVERSION_TABLE_EXISTS}" ]; then
        echo "** Table '${DB_SERVER_DBNAME}.dbversion' already exists."
        ZBX_DB_VERSION=$(mysql_query "SELECT mandatory FROM ${DB_SERVER_DBNAME}.dbversion")
    fi

    if [ -z "${ZBX_DB_VERSION}" ]; then
        echo "** Creating '${DB_SERVER_DBNAME}' schema in MySQL"

        zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | mysql --silent --skip-column-names \
                    -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} \
                    -u ${DB_SERVER_ROOT_USER} --password="${DB_SERVER_ROOT_PASS}"  \
                    ${DB_SERVER_DBNAME} 1>/dev/null
    fi
}

prepare_web_server() {
    NGINX_CONFD_DIR="/etc/nginx/conf.d"
    NGINX_SSL_CONFIG="/etc/ssl/nginx"

    echo "** Disable default vhosts"
    rm -f $NGINX_CONFD_DIR/*.conf

    echo "** Adding Zabbix virtual host (HTTP)"
    if [ -f "$ZABBIX_ETC_DIR/nginx.conf" ]; then
        ln -s "$ZABBIX_ETC_DIR/nginx.conf" "$NGINX_CONFD_DIR"
    else
        echo "**** Impossible to enable HTTP virtual host"
    fi

    if [ -f "$NGINX_SSL_CONFIG/ssl.crt" ] && [ -f "$NGINX_SSL_CONFIG/ssl.key" ] && [ -f "$NGINX_SSL_CONFIG/dhparam.pem" ]; then
        echo "** Enable SSL support for Nginx"
        if [ -f "$ZABBIX_ETC_DIR/nginx_ssl.conf" ]; then
            ln -s "$ZABBIX_ETC_DIR/nginx_ssl.conf" "$NGINX_CONFD_DIR"
        else
            echo "**** Impossible to enable HTTPS virtual host"
        fi
    else
        echo "**** Impossible to enable SSL support for Nginx. Certificates are missed."
    fi

    if [ -d "/var/log/nginx/" ]; then
        ln -sf /dev/fd/2 /var/log/nginx/error.log
    fi
}

stop_databases() {
    if [ "${DB_SERVER_HOST}" == "localhost" ]; then
        mysql_query "DELETE FROM mysql.user WHERE host = 'localhost' AND user != 'root'" 1>/dev/null

        kill -TERM $(cat /var/lib/mysql/mysqld.pid)
    fi
}

clear_deploy() {
    echo "** Cleaning the system"

    stop_databases
}

update_zbx_config() {
    echo "** Preparing Zabbix server configuration file"

    ZBX_CONFIG=$ZABBIX_ETC_DIR/zabbix_server.conf

    update_config_var $ZBX_CONFIG "SourceIP" "${ZBX_SOURCEIP}"
    update_config_var $ZBX_CONFIG "LogType" "console"
    update_config_var $ZBX_CONFIG "LogFile"
    update_config_var $ZBX_CONFIG "LogFileSize"
    update_config_var $ZBX_CONFIG "PidFile"

    update_config_var $ZBX_CONFIG "DebugLevel" "${ZBX_DEBUGLEVEL}"

    update_config_var $ZBX_CONFIG "DBHost" "${DB_SERVER_HOST}"
    update_config_var $ZBX_CONFIG "DBName" "${DB_SERVER_DBNAME}"
    update_config_var $ZBX_CONFIG "DBSchema" "${DB_SERVER_SCHEMA}"
    update_config_var $ZBX_CONFIG "DBUser" "${DB_SERVER_ZBX_USER}"
    update_config_var $ZBX_CONFIG "DBPort" "${DB_SERVER_PORT}"
    update_config_var $ZBX_CONFIG "DBPassword" "${DB_SERVER_ZBX_PASS}"

    update_config_var $ZBX_CONFIG "HistoryStorageURL" "${ZBX_HISTORYSTORAGEURL}"
    update_config_var $ZBX_CONFIG "HistoryStorageTypes" "${ZBX_HISTORYSTORAGETYPES}"

    update_config_var $ZBX_CONFIG "DBSocket" "${DB_SERVER_SOCKET}"

    update_config_var $ZBX_CONFIG "StatsAllowedIP" "${ZBX_STATSALLOWEDIP}"

    update_config_var $ZBX_CONFIG "StartPollers" "${ZBX_STARTPOLLERS}"
    update_config_var $ZBX_CONFIG "StartIPMIPollers" "${ZBX_IPMIPOLLERS}"
    update_config_var $ZBX_CONFIG "StartPollersUnreachable" "${ZBX_STARTPOLLERSUNREACHABLE}"
    update_config_var $ZBX_CONFIG "StartTrappers" "${ZBX_STARTTRAPPERS}"
    update_config_var $ZBX_CONFIG "StartPingers" "${ZBX_STARTPINGERS}"
    update_config_var $ZBX_CONFIG "StartDiscoverers" "${ZBX_STARTDISCOVERERS}"
    update_config_var $ZBX_CONFIG "StartHTTPPollers" "${ZBX_STARTHTTPPOLLERS}"

    update_config_var $ZBX_CONFIG "StartPreprocessors" "${ZBX_STARTPREPROCESSORS}"
    update_config_var $ZBX_CONFIG "StartTimers" "${ZBX_STARTTIMERS}"
    update_config_var $ZBX_CONFIG "StartEscalators" "${ZBX_STARTESCALATORS}"
    update_config_var $ZBX_CONFIG "StartAlerters" "${ZBX_STARTALERTERS}"

    update_config_var $ZBX_CONFIG "JavaGateway" "localhost"
    update_config_var $ZBX_CONFIG "JavaGatewayPort" "10052"
    update_config_var $ZBX_CONFIG "StartJavaPollers" "${ZBX_STARTJAVAPOLLERS:-"5"}"

    update_config_var $ZBX_CONFIG "StartVMwareCollectors" "${ZBX_STARTVMWARECOLLECTORS}"
    update_config_var $ZBX_CONFIG "VMwareFrequency" "${ZBX_VMWAREFREQUENCY}"
    update_config_var $ZBX_CONFIG "VMwarePerfFrequency" "${ZBX_VMWAREPERFFREQUENCY}"
    update_config_var $ZBX_CONFIG "VMwareCacheSize" "${ZBX_VMWARECACHESIZE}"
    update_config_var $ZBX_CONFIG "VMwareTimeout" "${ZBX_VMWARETIMEOUT}"

    ZBX_ENABLE_SNMP_TRAPS=${ZBX_ENABLE_SNMP_TRAPS:-"false"}
    if [ "${ZBX_ENABLE_SNMP_TRAPS}" == "true" ]; then
        update_config_var $ZBX_CONFIG "SNMPTrapperFile" "${ZABBIX_USER_HOME_DIR}/snmptraps/snmptraps.log"
        update_config_var $ZBX_CONFIG "StartSNMPTrapper" "1"
    else
        update_config_var $ZBX_CONFIG "SNMPTrapperFile"
        update_config_var $ZBX_CONFIG "StartSNMPTrapper"
    fi

    update_config_var $ZBX_CONFIG "HousekeepingFrequency" "${ZBX_HOUSEKEEPINGFREQUENCY}"
    update_config_var $ZBX_CONFIG "MaxHousekeeperDelete" "${ZBX_MAXHOUSEKEEPERDELETE}"
    update_config_var $ZBX_CONFIG "SenderFrequency" "${ZBX_SENDERFREQUENCY}"

    update_config_var $ZBX_CONFIG "CacheSize" "${ZBX_CACHESIZE}"

    update_config_var $ZBX_CONFIG "CacheUpdateFrequency" "${ZBX_CACHEUPDATEFREQUENCY}"

    update_config_var $ZBX_CONFIG "StartDBSyncers" "${ZBX_STARTDBSYNCERS}"
    update_config_var $ZBX_CONFIG "HistoryCacheSize" "${ZBX_HISTORYCACHESIZE}"
    update_config_var $ZBX_CONFIG "HistoryIndexCacheSize" "${ZBX_HISTORYINDEXCACHESIZE}"

    update_config_var $ZBX_CONFIG "TrendCacheSize" "${ZBX_TRENDCACHESIZE}"
    update_config_var $ZBX_CONFIG "ValueCacheSize" "${ZBX_VALUECACHESIZE}"

    update_config_var $ZBX_CONFIG "Timeout" "${ZBX_TIMEOUT}"
    update_config_var $ZBX_CONFIG "TrapperTimeout" "${ZBX_TRAPPERIMEOUT}"
    update_config_var $ZBX_CONFIG "UnreachablePeriod" "${ZBX_UNREACHABLEPERIOD}"
    update_config_var $ZBX_CONFIG "UnavailableDelay" "${ZBX_UNAVAILABLEDELAY}"
    update_config_var $ZBX_CONFIG "UnreachableDelay" "${ZBX_UNREACHABLEDELAY}"

    update_config_var $ZBX_CONFIG "AlertScriptsPath" "/usr/lib/zabbix/alertscripts"
    update_config_var $ZBX_CONFIG "ExternalScripts" "/usr/lib/zabbix/externalscripts"

    # Possible few fping locations
    if [ -f "/usr/bin/fping" ]; then
        update_config_var $ZBX_CONFIG "FpingLocation" "/usr/bin/fping"
    else
        update_config_var $ZBX_CONFIG "FpingLocation" "/usr/sbin/fping"
    fi
    if [ -f "/usr/bin/fping6" ]; then
        update_config_var $ZBX_CONFIG "Fping6Location" "/usr/bin/fping6"
    else
        update_config_var $ZBX_CONFIG "Fping6Location" "/usr/sbin/fping6"
    fi

    update_config_var $ZBX_CONFIG "SSHKeyLocation" "$ZABBIX_USER_HOME_DIR/ssh_keys"
    update_config_var $ZBX_CONFIG "LogSlowQueries" "${ZBX_LOGSLOWQUERIES}"

    update_config_var $ZBX_CONFIG "StartProxyPollers" "${ZBX_STARTPROXYPOLLERS}"
    update_config_var $ZBX_CONFIG "ProxyConfigFrequency" "${ZBX_PROXYCONFIGFREQUENCY}"
    update_config_var $ZBX_CONFIG "ProxyDataFrequency" "${ZBX_PROXYDATAFREQUENCY}"

    update_config_var $ZBX_CONFIG "SSLCertLocation" "$ZABBIX_USER_HOME_DIR/ssl/certs/"
    update_config_var $ZBX_CONFIG "SSLKeyLocation" "$ZABBIX_USER_HOME_DIR/ssl/keys/"
    update_config_var $ZBX_CONFIG "SSLCALocation" "$ZABBIX_USER_HOME_DIR/ssl/ssl_ca/"
    update_config_var $ZBX_CONFIG "LoadModulePath" "$ZABBIX_USER_HOME_DIR/modules/"
    update_config_multiple_var $ZBX_CONFIG "LoadModule" "${ZBX_LOADMODULE}"

    update_config_var $ZBX_CONFIG "TLSCAFile" "${ZBX_TLSCAFILE}"
    update_config_var $ZBX_CONFIG "TLSCRLFile" "${ZBX_TLSCRLFILE}"

    update_config_var $ZBX_CONFIG "TLSCertFile" "${ZBX_TLSCERTFILE}"
    update_config_var $ZBX_CONFIG "TLSKeyFile" "${ZBX_TLSKEYFILE}"
}


prepare_zbx_web_config() {
    local server_name=""

    echo "** Preparing Zabbix frontend configuration file"

    ZBX_WWW_ROOT="/usr/share/zabbix"
    ZBX_WEB_CONFIG="$ZABBIX_ETC_DIR/web/zabbix.conf.php"

    if [ -f "$ZBX_WWW_ROOT/conf/zabbix.conf.php" ]; then
        rm -f "$ZBX_WWW_ROOT/conf/zabbix.conf.php"
    fi

    ln -s "$ZBX_WEB_CONFIG" "$ZBX_WWW_ROOT/conf/zabbix.conf.php"

    PHP_CONFIG_FILE="/etc/php.d/99-zabbix.ini"

    update_config_var "$PHP_CONFIG_FILE" "max_execution_time" "${ZBX_MAXEXECUTIONTIME:-"600"}"
    update_config_var "$PHP_CONFIG_FILE" "memory_limit" "${ZBX_MEMORYLIMIT:-"128M"}" 
    update_config_var "$PHP_CONFIG_FILE" "post_max_size" "${ZBX_POSTMAXSIZE:-"16M"}"
    update_config_var "$PHP_CONFIG_FILE" "upload_max_filesize" "${ZBX_UPLOADMAXFILESIZE:-"2M"}"
    update_config_var "$PHP_CONFIG_FILE" "max_input_time" "${ZBX_MAXINPUTTIME:-"300"}"
    update_config_var "$PHP_CONFIG_FILE" "date.timezone" "${PHP_TZ}"

    ZBX_HISTORYSTORAGETYPES=${ZBX_HISTORYSTORAGETYPES:-"[]"}

    # Escaping characters in parameter value
    server_name=$(escape_spec_char "${ZBX_SERVER_NAME}")
    server_user=$(escape_spec_char "${DB_SERVER_ZBX_USER}")
    server_pass=$(escape_spec_char "${DB_SERVER_ZBX_PASS}")
    history_storage_url=$(escape_spec_char "${ZBX_HISTORYSTORAGEURL}")
    history_storage_types=$(escape_spec_char "${ZBX_HISTORYSTORAGETYPES}")

    sed -i \
        -e "s/{DB_SERVER_HOST}/${DB_SERVER_HOST}/g" \
        -e "s/{DB_SERVER_PORT}/${DB_SERVER_PORT}/g" \
        -e "s/{DB_SERVER_DBNAME}/${DB_SERVER_DBNAME}/g" \
        -e "s/{DB_SERVER_SCHEMA}/${DB_SERVER_SCHEMA}/g" \
        -e "s/{DB_SERVER_USER}/$server_user/g" \
        -e "s/{DB_SERVER_PASS}/$server_pass/g" \
        -e "s/{ZBX_SERVER_HOST}/localhost/g" \
        -e "s/{ZBX_SERVER_PORT}/10051/g" \
        -e "s/{ZBX_SERVER_NAME}/$server_name/g" \
        -e "s/{ZBX_HISTORYSTORAGEURL}/$history_storage_url/g" \
        -e "s/{ZBX_HISTORYSTORAGETYPES}/$history_storage_types/g" \
    "$ZBX_WEB_CONFIG"

    [ -n "${ZBX_SESSION_NAME}" ] && sed -i "/ZBX_SESSION_NAME/s/'[^']*'/'${ZBX_SESSION_NAME}'/2" "$ZBX_WWW_ROOT/include/defines.inc.php"
}

prepare_java_gateway_config() {
    echo "** Preparing Zabbix Java Gateway log configuration file"

    ZBX_GATEWAY_CONFIG=$ZABBIX_ETC_DIR/zabbix_java_gateway_logback.xml

    if [ -n "${ZBX_DEBUGLEVEL}" ]; then
        echo "Updating $ZBX_GATEWAY_CONFIG 'DebugLevel' parameter: '${ZBX_DEBUGLEVEL}'... updated"
        if [ -f "$ZBX_GATEWAY_CONFIG" ]; then
            sed -i -e "/^.*<root level=/s/=.*/=\"${ZBX_DEBUGLEVEL}\">/" "$ZBX_GATEWAY_CONFIG"
        else
            echo "**** Zabbix Java Gateway log configuration file '$ZBX_GATEWAY_CONFIG' not found"
        fi
    fi
}

prepare_server() {
    echo "** Preparing Zabbix server"

    check_variables_mysql
    check_db_connect
    create_db_user_mysql
    create_db_database_mysql
    create_db_schema_mysql

    update_zbx_config
}

prepare_web() {
    echo "** Preparing Zabbix web-interface"

    check_variables_mysql
    check_db_connect
    prepare_web_server
    prepare_zbx_web_config
}

prepare_java_gateway() {
    echo "** Preparing Zabbix Java Gateway"

    prepare_java_gateway_config
}

#################################################

echo "** Deploying Zabbix server (nginx) with MySQL database"

prepare_system

prepare_server

prepare_web

prepare_java_gateway

clear_deploy

echo "########################################################"

if [ "$1" != "" ]; then
    echo "** Executing '$@'"
    exec "$@"
elif [ -f "/usr/bin/supervisord" ]; then
    echo "** Executing supervisord"
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
else
    echo "Unknown instructions. Exiting..."
    exit 1
fi

#################################################
