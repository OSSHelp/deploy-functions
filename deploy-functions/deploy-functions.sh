#!/bin/bash
# shellcheck disable=SC2054,SC2015,SC2016,SC2034,SC2206,SC1001,SC2191,SC2128,SC2207

declare -r df_ver=1.20

yq_cmd=$(command -v yq); declare -r yq_cmd
jq_cmd=$(command -v jq); declare -r jq_cmd
curl_cmd=$(command -v curl); declare -r curl_cmd

declare -r uuid_url="https://oss.help/uuid"
declare -r force_ua="default-setup/${df_ver} (${LC_HOST:--}/${our_uuid}/${LC_SHIFT:--})"

our_uuid=$({ test -s /var/backups/uuid && cat /var/backups/uuid; } || curl --silent --user-agent "${force_ua}" ${uuid_url} | tee /var/backups/uuid)
declare -r our_uuid

declare -r download_retry=3
declare -r silent='no'

declare -r yml_dir="/usr/local/osshelp/profiles"
declare -r yml_default="${yml_dir}/default.yml"
declare -r yml_custom="${yml_dir}/custom.yml"
declare -r yml_current="${yml_dir}/current.yml"

server_name="${1}"; declare -r server_name
test -n "${INSTANCE_ID}" && { container_name="${INSTANCE_ID}"; declare -r container_name; }

## Helpers section
function show_notice()  { local -r log_date=$(date '+%Y/%m/%d %H:%M:%S'); test "${silent}" != "yes" && echo -e "[NOTICE ${log_date}] ${*}"; return 0; }
function show_warning() { local -r log_date=$(date '+%Y/%m/%d %H:%M:%S'); test "${silent}" != "yes" && echo -e "[WARNING ${log_date}] ${*}"; return 0; }
function show_error()   { local -r log_date=$(date '+%Y/%m/%d %H:%M:%S'); echo -e "[ERROR ${log_date}] ${*}" >&2; return 1; }
function show_fatal()   { local -r log_date=$(date '+%Y/%m/%d %H:%M:%S'); echo -e "[FATAL ${log_date}] ${*}" >&2; exit 1; }
function lock_user()    { id "${1}" >/dev/null 2>&1 && usermod -L "${1}"; }
function unlock_user()  { id "${1}" >/dev/null 2>&1 && usermod -U "${1}"; }

function make_dir() {
  test -d "${1}" && {
    chmod -v "${2:-750}" "${1}" && \
      chown -v "${3:-root:root}" "${1}"
  }
  test -d "${1}" || {
    mkdir -pv "${1}" && \
      chmod -v "${2:-750}" "${1}" && \
        chown -v "${3:-root:root}" "${1}"
  }
}

function make_file() {
  test -f "${1}" && {
    chmod -v "${2:-640}" "${1}" && \
      chown -v "${3:-root:root}" "${1}"
  }
  test -f "${1}" || {
    mkdir -pv "$(dirname "${1}")" && \
      touch "${1}" && \
        chmod -v "${2:-640}" "${1}" && \
          chown -v "${3:-root:root}" "${1}"
  }
}

function download_file() {
  local target_url="${1}"; local target_file="${2}"; local -r target_dir=$(dirname "${target_file}")
  test -d "${target_dir}" || { show_notice "Creating directory ${target_dir}"; mkdir -p "${target_dir}"; }
  test -f "${target_file}.info" && local time_opts="${target_file}.info"
  show_notice "Downloading ${target_url} to ${target_file}"
  error_code=$( ${curl_cmd} --silent --remote-time --retry ${download_retry} --user-agent "${force_ua}" --compressed --location --fail --time-cond "${time_opts:-1970 Jan 1}" --write-out '%{http_code}' --output "${target_file}" "${target_url}" )
  test "${error_code:-000}" -eq "200" && {
    { echo "date: $(date)"; echo "url: ${target_url}"; echo "file: ${target_file}"; } > "${target_file}.info"; touch -r "${target_file}" "${target_file}.info"
  }
  test "${error_code:-000}" -eq "200" -o "${error_code:-000}" -eq "304" && return 0 || return 1
}

function have_package() {
  case "${pkgm}" in
    yum)
      rpm -q "${1}" >/dev/null 2>&1
    ;;
    apt-get)
      dpkg -s "${1}" 2>&1 | grep -qE '^Status: install'
    ;;
    *)
      false
    ;;
  esac
}

function package_by_file() {
  case "${pkgm}" in
    yum)
      rpm -qf "${1}" 2> /dev/null
    ;;
    apt-get)
      dpkg -S "${1}" 2> /dev/null | cut -f 1 -d ':'
    ;;
  esac
}

function get_value() {
  local key_name="${1}"; local file_name="${2}"; local default_value="${3}"
  key_value=$(${yq_cmd} r "${file_name}" "${key_name}" 2>/dev/null)
  test -n "${key_value}" -a "${key_value}" != "null" && echo -n "${key_value}"
  test -z "${key_value}" -o "${key_value}" = "null" && echo -n "${default_value}"
}

function get_keys() {
  local key_name="${1}"; local file_name="${2}"
  keys_list=$(${yq_cmd} r "${file_name}" "${key_name}" 2>/dev/null)
  echo "${keys_list}" | sed -rn 's|^(\S+):.*|\1|p'
}

function key_exists_in_current_yml() {
  local key_name="${1}"; local key_does_not_exist=1; local value; local error_code
  test -r "${yml_current}" && {
    value=$(${yq_cmd} r "${yml_current}" "${key_name}" 2>/dev/null)
    error_code="${?}"
    test "${error_code}" -ne "0" && return "${error_code}"
    test "${value}" != "null" && key_does_not_exist=0
  }
  return "${key_does_not_exist}"
}

function get_list_items() {
  local key_name="${1}"; local file_name="${2}"
  keys_list=$(${yq_cmd} r "${file_name}" "${key_name}" 2>/dev/null)
  echo "${keys_list}" | sed -r 's/- //' | grep -vE '^(null|"")$'
}

function check_required_tools() {
  test -x "${yq_cmd}" || { show_error "Can't find yq (YAML processor), you should install it first"; exit 1; }
}

function prepare_config() {
    test -r "${yml_default}" -a -r "${yml_custom}"     && yq m "${yml_custom}" "${yml_default}" > "${yml_current}"
    test -r "${yml_default}" -a ! -e "${yml_custom}"   && cat "${yml_default}" > "${yml_current}"
    test -r "${yml_custom}"  -a ! -e "${yml_default}"  && cat "${yml_custom}" > "${yml_current}"
    test ! -e "${yml_default}" -a ! -e "${yml_custom}" && show_notice "No valid profiles found"
}

function prepare_vars() {
  codename=$(lsb_release -c | cut -f 2); dist_family=unknown
  test -f /etc/debian_version && { dist_family="debian"; pkgm="apt-get"; }
  test -f /etc/redhat-release && { dist_family="redhat"; pkgm="yum"; }
  mysql_pkgname=$(package_by_file "/usr/sbin/mysqld")
}

function update_conf_parameter() {
  local option="${1}"
  local key_name="${2}"
  local -A map_vals; eval "map_vals=(${3})"

  local value; local result_val
  local value; value=$(get_value "${key_name}" "${yml_current}")

  test -n "${value}" -a "${value}" != null && {
    test "${#map_vals[@]}" -eq "0" && result_val="${value}"
    test "${#map_vals[@]}" -gt "0" && result_val="${map_vals[${value}]}"

    grep -qP "^\s*${option}\s*" "${current_config_file}" && local param_found=1

    test -n "${param_found}" && {
      show_notice "Modifying param \"${option}\" in ${current_config_file}"
      sed -r "s|^(\s*${option}).+|\1${separator}${result_val/&/\\&}|" -i "${current_config_file}"
    }
    test -n "${param_found}" || {
      show_notice "Adding param \"${option}\" to ${current_config_file}"
      echo "${option}${separator}${result_val}" >> "${current_config_file}"
    }
  }
}

function update_ini_parameter() {
  local section="${1}"
  local option="${2}"
  local key_name="${3}"
  local -A map_vals; eval "map_vals=(${4})"

  grep -qP "^\[${section}\]" "${current_config_file}" || { show_error "Section [${section}] was not found if file ${current_config_file}"; return 1; }

  local value; local result_val
  local value; value=$(get_value "${key_name}" "${yml_current}")

  test -n "${value}" -a "${value}" != null && {
    grep -qP "^\[${section}\]" "${current_config_file}" && {
      test "${#map_vals[@]}" -eq 0 && result_val="${value}"
      test "${#map_vals[@]}" -gt 0 && result_val="${map_vals[${value}]}"

      grep -qP "^\s*${option}\s*" "${current_config_file}" && local param_found=1

      test -n "${param_found}" && {
        show_notice "Modifying param \"${option}\" in section \"${section}\" of ${current_config_file}"
        sed -r '/^\['"${section}"'\]/,/^\[.+\]/s/^(\s*'"${option}"'\s+).*$/\1'"${separator}${result_val}/" -i "${current_config_file}"
      }
      test -n "${param_found}" || {
        show_notice "Adding param \"${option}\" to section \"${section}\" of ${current_config_file}"
        sed -r '/^\['"${section}"'\]/a'"\    ${option}${separator}${result_val}" -i "${current_config_file}"
      }
    }
  }
}

function update_json_parameter() {
  local option="${1}"
  local key_name="${2}"
  local argjsn="${3}"
  local temp_json="/tmp/$$.json"
  local args=(); local value=()
  local result_args=()
  local result_jq_map=()
  local cnt=0
  
  test "${argjsn}" == "list" && args=($(get_list_items "${key_name}" "${yml_current}"))
  test "${argjsn}" == "dict" && args=($(get_keys "${key_name}" "${yml_current}"))
  test "${argjsn}" == "bool" -o "${argjsn}" == "number" -o "${argjsn}" == "string" && args=($(get_value "${key_name}" "${yml_current}"))

  test "${#args[@]}" -gt 0 -a "${args[0]}" != null && {
    total="${#args[@]}"
    grep -qP "^\s+.+${option}" "${current_config_file}" && local param_found=1
    test -n "${param_found}" && \
      show_notice "Modifying param \"${option}\" in ${current_config_file}"
    test -n "${param_found}" || \
      show_notice "Adding param \"${option}\" in ${current_config_file}"

    test "${argjsn}" == 'bool' -o "${argjsn}" == 'number' && {
      ${jq_cmd} --arg o "${option}" --argjson v "${args[@]}" '.[$o] = $v' "${current_config_file}" > "${temp_json}" && \
      mv "${temp_json}" "${current_config_file}"
    }
    test "${argjsn}" == 'string' && {
      ${jq_cmd} --arg o "${option}" --arg v "${args[@]}" '.[$o] = $v' "${current_config_file}" > "${temp_json}" && \
      mv "${temp_json}" "${current_config_file}"
    }
    test "${argjsn}" == 'list' && {
      cnt="${#args[@]}"
      result_jq_map=(.\[\$o\] \= \[)
      for arg in "${args[@]}"; do
        cnt=$((cnt - 1))
        result_args+=(--arg v${cnt} ${arg})
        test "${cnt}" -gt 0 && result_jq_map+=(\$v${cnt},)
        test "${cnt}" -eq 0 && result_jq_map+=(\$v${cnt}\])
      done
      ${jq_cmd} --arg o "${option}" "${result_args[@]}" "${result_jq_map[*]}" "${current_config_file}" > "${temp_json}" && \
      mv "${temp_json}" "${current_config_file}"
    }
    test "${argjsn}" == 'dict' && {
      cnt="${#args[@]}"
      result_jq_map=(.\[\$o\] \= \{)
      for arg in "${args[@]}"; do
        cnt=$((cnt - 1))
        value=($(get_value "${key_name}.${arg}" "${yml_current}"))
        result_args+=(--arg ${arg} ${value})
        test "${cnt}" -gt 0 && result_jq_map+=(\$${arg},)
        test "${cnt}" -eq 0 && result_jq_map+=(\$${arg}\})
      done
      ${jq_cmd} --arg o "${option}" "${result_args[@]}" "${result_jq_map[*]}" "${current_config_file}" > "${temp_json}" && \
      mv "${temp_json}" "${current_config_file}"
    }
  }
}

## Default section
function setup_default_varlog() {
  test "${dist_family}" == "unknown" -o -z "${codename}" && { show_error "Can't detect dist family, make sure lsb-release is installed. Skipping /var/log setup!"; return 1; }
  test "${dist_family}" == "debian" && {
    test "${codename}" == "focal" && {
      show_notice "Checking and creating default dirs and files in /var/log"
      make_dir  "/var/log/apt" "755"
      make_dir  "/var/log/sysstat" "755"
      make_dir  "/var/log/netdata" "750" "netdata:adm"
      make_dir  "/var/log/private" "700"
      make_dir  "/var/log/journal" "755" "root:systemd-journal"
      make_dir  "/var/log/unattended-upgrades" "750" "root:adm"
      make_file "/var/log/apt/history.log" "644"
      make_file "/var/log/apt/term.log" "640" "root:adm"
      make_file "/var/log/unattended-upgrades/unattended-upgrades-shutdown.log" "644"
      make_file "/var/log/alternatives.log" "644"
      make_file "/var/log/auth.log" "640" "syslog:adm"
      make_file "/var/log/btmp" "660" "root:utmp"
      make_file "/var/log/cloud-init-output.log" "644"
      make_file "/var/log/cloud-init.log" "644" "syslog:adm"
      make_file "/var/log/dmesg" "644" "root:adm"
      make_file "/var/log/dpkg.log" "644"
      make_file "/var/log/lastlog" "664" "root:utmp"
      make_file "/var/log/syslog" "640" "syslog:adm"
      make_file "/var/log/wtmp" "664" "root:utmp"
    }
    test "${codename}" == "bionic" && {
      show_notice "Checking and creating default dirs and files in /var/log"
      make_dir  "/var/log/apt" "755"
      make_dir  "/var/log/sysstat" "755"
      make_dir  "/var/log/netdata" "755"
      make_dir  "/var/log/journal" "755" "root:systemd-journal"
      make_dir  "/var/log/unattended-upgrades" "750" "root:adm"
      make_file "/var/log/apt/history.log" "644"
      make_file "/var/log/apt/term.log" "640" "root:adm"
      make_file "/var/log/alternatives.log" "644"
      make_file "/var/log/auth.log" "640" "syslog:adm"
      make_file "/var/log/unattended-upgrades/unattended-upgrades-shutdown.log" "644"
      make_file "/var/log/btmp" "660" "root:utmp"
      make_file "/var/log/cloud-init-output.log" "644"
      make_file "/var/log/cloud-init.log" "644" "syslog:adm"
      make_file "/var/log/dpkg.log" "644"
      make_file "/var/log/lastlog" "664" "root:utmp"
      make_file "/var/log/syslog" "640" "syslog:adm"
      make_file "/var/log/tallylog" "600"
      make_file "/var/log/wtmp" "664" "root:utmp"
    }
    test "${codename}" == "xenial" && {
      show_notice "Checking and creating default dirs and files in /var/log"
      make_dir  "/var/log/apt"
      make_dir  "/var/log/netdata"
      make_file "/var/log/apt/history.log" "640"
      make_file "/var/log/apt/term.log" "640" "root:adm"
      make_file "/var/log/auth.log" "640" "syslog:adm"
      make_file "/var/log/btmp" "600" "root:utmp"
      make_file "/var/log/dpkg.log" "640"
      make_dir  "/var/log/fsck" "755"
      make_dir  "/var/log/unattended-upgrades" "750" "root:adm"
      make_dir  "/var/log/dist-upgrade" "755"
      make_file "/var/log/fail2ban.log" "640" "root:adm"
      make_file "/var/log/kern.log" "640" "syslog:adm"
      make_file "/var/log/lastlog" "660" "root:utmp"
      make_file "/var/log/syslog" "640" "syslog:adm"
      make_file "/var/log/wtmp" "640" "root:utmp"
    }
    test "${codename}" == "trusty" && {
      show_notice "Checking and creating default dirs and files in /var/log"
      make_dir  "/var/log/apt"
      make_dir  "/var/log/netdata"
      make_file "/var/log/apt/history.log" "640"
      make_file "/var/log/apt/term.log" "640" "root:adm"
      make_file "/var/log/auth.log" "640" "syslog:adm"
      make_file "/var/log/btmp" "660" "root:utmp"
      make_file "/var/log/dmesg" "640" "root:adm"
      make_file "/var/log/dpkg.log" "640"
      make_file "/var/log/fail2ban.log" "640" "root:adm"
      make_file "/var/log/kern.log" "640" "syslog:adm"
      make_file "/var/log/lastlog" "660" "root:utmp"
      make_file "/var/log/syslog" "640" "syslog:adm"
      make_file "/var/log/wtmp" "640" "root:utmp"
    }
  }
  test "${dist_family}" == "redhat" && return
}

## Services section
function setup_custom_varlog() {
  test "${dist_family}" == "unknown" -o -z "${codename}" && { show_error "Can't detect dist family, make sure lsb-release is installed. Skipping /var/log setup!"; return 1; }
  test "${dist_family}" == "debian" && {
    show_notice "Checking installed packages and creating custom dirs and files in /var/log"
    have_package "nginx"            && make_dir "/var/log/nginx"   "755"  "root:adm"
    have_package "nginx-light"      && make_dir "/var/log/nginx"   "755"  "root:adm"
    have_package "nginx-full"       && make_dir "/var/log/nginx"   "755"  "root:adm"
    have_package "nginx-extras"     && make_dir "/var/log/nginx"   "755"  "root:adm"
    have_package "php5-fpm"         && make_dir "/var/log/php-fpm" "755"  "www-data:www-data"
    have_package "php-fpm5.5"       && make_dir "/var/log/php-fpm" "755"  "www-data:www-data"
    have_package "php-fpm5.6"       && make_dir "/var/log/php-fpm" "755"  "www-data:www-data"
    have_package "php-fpm7.0"       && make_dir "/var/log/php-fpm" "755"  "www-data:www-data"
    have_package "php-fpm7.1"       && make_dir "/var/log/php-fpm" "755"  "www-data:www-data"
    have_package "${mysql_pkgname}" && make_dir "/var/log/mysql"   "2750" "mysql:adm"
    have_package "redis-server"     && make_dir "/var/log/redis"   "750"  "redis:redis"
    have_package "proftpd-basic"    && make_dir "/var/log/proftpd" "755"
    have_package "lxd"              && make_dir "/var/log/lxd"     "755"
    return
  }
  test "${dist_family}" == "redhat" && return
}

function setup_netdata() {
  local -r netdata_main_cfg='/etc/netdata/netdata.conf'
  local -r netdata_stream_cfg='/etc/netdata/stream.conf'
  local -r netdata_id='/var/lib/netdata/registry/netdata.public.unique.id'
  key_exists_in_current_yml "netdata.hostname" && \
    netdata_hostname=$(get_value 'netdata.hostname' "${yml_current}") || \
      test -n "${netdata_hostname}" || netdata_hostname="${container_name}"

  test -f "${netdata_id}" && rm -vr "${netdata_id}"

  test -f "${netdata_main_cfg}" && {
    grep -qE '(\s*)?hostname(\s*)?=(\s*)?.*' "${netdata_main_cfg}" && no_hostname_in_cfg=0 || no_hostname_in_cfg=1
      test "${no_hostname_in_cfg}" == "0" && sed -e "s/\(hostname\).*\(=\).*/\1 \2 ${netdata_hostname}/" -i "${netdata_main_cfg}"
      test "${no_hostname_in_cfg}" == "1" && sed -e "s/\[global\]/\[global\]\n\thostname = ${netdata_hostname}/" -i "${netdata_main_cfg}"
  }
  key_exists_in_current_yml "netdata" && {
    test -f "${netdata_stream_cfg}" && {
      current_config_file="${netdata_stream_cfg}"
      separator=" = "
      update_ini_parameter 'stream' 'enabled'     'netdata.stream.enabled'     '[true]=yes [false]=no'
      update_ini_parameter 'stream' 'destination' 'netdata.stream.destination'
      update_ini_parameter 'stream' 'api key'     'netdata.stream.api-key'
    }
  }
}

function setup_ssmtp() {
    local -r ssmtp_main_cfg='/etc/ssmtp/ssmtp.conf'
    local -r ssmtp_aliases_file='/etc/ssmtp/revaliases'

    separator="="
    current_config_file="${ssmtp_main_cfg}"
    ssmtp_hostname=$(get_value 'ssmtp.hostname' "${yml_current}" "$(hostname -f)")

    grep -qP "^\s*hostname\s*" "${current_config_file}" && local param_found=1

    test -n "${param_found}" && {
      show_notice "Modifying param \"hostname\" in ${current_config_file}"
      sed -r "s|^(\s*hostname).+|\1${separator}${ssmtp_hostname/&/\\&}|" -i "${current_config_file}"
    }
    test -n "${param_found}" || {
      show_notice "Adding param \"hostname\" to ${current_config_file}"
      echo "hostname${separator}${ssmtp_hostname}" >> "${current_config_file}"
    }

  key_exists_in_current_yml "ssmtp" && {
    update_conf_parameter 'root'             'ssmtp.root'
    update_conf_parameter 'mailhub'          'ssmtp.mailhub'
    update_conf_parameter 'rewriteDomain'    'ssmtp.rewrite-domain'
    update_conf_parameter 'FromLineOverride' 'ssmtp.from-line-override' '[true]=YES [false]=NO'

    test -f "${ssmtp_aliases_file}" && {
      current_config_file="${ssmtp_aliases_file}"
      get_list_items 'ssmtp.revaliases' "${yml_current}" >> "${ssmtp_aliases_file}"
    }
  }
}

function setup_monit() {
  local -r monit_conf_d='/etc/monit/conf.d'
  local -r monit_conf_available='/etc/monit/conf-available'
  local -r monit_conf_enabled='/etc/monit/conf-enabled'
  local -r monit_conf_disabled='/etc/monit/conf-disabled'
  local -r monit_main_cfg="${monit_conf_d}/main"
  local -r monit_default_cfg='/etc/default/monit'
  local -r monit_highload_cfg="${monit_conf_d}/highload"
  key_exists_in_current_yml "monit.hostname" && \
    monit_hostname=$(get_value 'monit.hostname' "${yml_current}") || \
      test -n "${monit_hostname}" || monit_hostname="${container_name}"

  #fixing highload config
  test -f "${monit_highload_cfg}" && \
    sed -r "s/^\s*(check\s+system).+$/\1 ${monit_hostname}/" -i "${monit_highload_cfg}"

  key_exists_in_current_yml "monit" && {
    test -f "${monit_default_cfg}" && {
      #start
      current_config_file="${monit_default_cfg}"
      separator="="
      update_conf_parameter 'START' 'monit.start' '[true]=yes [false]=no'
    }
    test -f "${monit_main_cfg}" && {
      #mailserver and set alert
      current_config_file="${monit_main_cfg}"
      separator=" "
      update_conf_parameter 'set mailserver' 'monit.mailserver'
      update_conf_parameter 'set alert'      'monit.set-alert'

      #hostname
      sed -r 's|(subject:).+$|\1 ['"${server_name}/${monit_hostname}"'] Monit: $SERVICE $EVENT }|' -i "${monit_main_cfg}"

      #start-delay
      grep -qP '^[^#]+\s+start delay' "${monit_main_cfg}" && local start_delay_found=1
      test -n "${start_delay_found}" && {
        sed -r 's/(start\s+delay).+/\1 '"$(get_value 'monit.start-delay' "${yml_current}" "120")/" -i "${monit_main_cfg}"
      }
      test -n "${start_delay_found}" || {
        echo "set daemon 120 with start delay $(get_value 'monit.start-delay' "${yml_current}" "120")" >> "${monit_main_cfg}"
      }
    }

    #enable configs
    for cnf in $(get_list_items 'monit.enable' "${yml_current}"); do
      test -f "${monit_conf_available}/${cnf}" && \
        ln -svrf "${monit_conf_available}/${cnf}" "${monit_conf_enabled}/${cnf}"
    done

    #disable configs
    for cnf in $(get_list_items 'monit.disable' "${yml_current}"); do
      test -L "${monit_conf_enabled}/${cnf}" && \
        rm -vf "${monit_conf_enabled}/${cnf}"
      test -f "${monit_conf_d}/${cnf}" && {
        test -d "${monit_conf_disabled}" || mkdir -p "${monit_conf_disabled}"
        mv -vf "${monit_conf_d}/${cnf}" "${monit_conf_disabled}/${cnf}"
      }
    done
  }
}

function setup_nginx() {
  key_exists_in_current_yml "nginx" && {
    local -r nginx_stat_cfg='/etc/nginx/sites-available/stat'
    local -r nginx_sites_available='/etc/nginx/sites-available'
    local -r nginx_sites_enabled='/etc/nginx/sites-enabled'
    local stat_server_name
    stat_server_name=$(get_value 'nginx.stat-servername' "${yml_current}" "none")
    test "${stat_server_name}" == "none" && {
      stat_server_name=$(get_value 'nginx.stat-server-name' "${yml_current}" "none")
      test "${stat_server_name}" != "none" && \
        show_warning "Key nginx.stat-server-name is deprecated and will be removed in future library versions! Use nginx.stat-servername instead."
    }

    test "${stat_server_name}" != "none" && {
      #change server_name in stat host
      test -f "${nginx_stat_cfg}" -a -n "${stat_server_name}" && \
        sed -e "s/\(server_name\)\(.*\)\(;\)/\1 ${stat_server_name} localhost\3/" -i "${nginx_stat_cfg}"
    }

    #enable vhosts
    for vhost in $(get_list_items 'nginx.enable-vhosts' "${yml_current}"); do
      test -f "${nginx_sites_available}/${vhost}" && \
        ln -svrf "${nginx_sites_available}/${vhost}" "${nginx_sites_enabled}/${vhost}"
    done

    #disable vhosts
    for vhost in $(get_list_items 'nginx.disable-vhosts' "${yml_current}"); do
      test -L "${nginx_sites_enabled}/${vhost}" && \
        rm -vf "${nginx_sites_enabled}/${vhost}"
    done
  }
}

function setup_phpfpm () {
  key_exists_in_current_yml "php-fpm" && {
    # shellcheck disable=SC2207
    local -r phpfpm_pool_d=($(find /etc/php* -type d -name pool.d 2>/dev/null))
    test "${#phpfpm_pool_d[@]}" -gt 1 && show_error "Multiple pool.d directories found, skipping php-fpm setup!"
    test "${#phpfpm_pool_d[@]}" -lt 1 && { show_notice "No pool.d directories found, skipping php-fpm setup."; return 1; }
    test "${#phpfpm_pool_d[@]}" -eq 1 && {
      test -d "${phpfpm_pool_d[0]}" && {
        local -r storage_dir="${phpfpm_pool_d/.d/.disabled}"
        test -d "${phpfpm_pool_d/\/fpm\/pool.d/}" && local -r php_dir="${phpfpm_pool_d/\/fpm\/pool.d/}"
      }
      local -r mods_available_dir="${php_dir}/mods-available"

        #enable pools
        for pool in $(get_list_items 'php-fpm.enable-pools' "${yml_current}"); do
          test -f "${storage_dir}/${pool}.conf" && \
            cp -vf "${storage_dir}/${pool}.conf" "${phpfpm_pool_d[0]}/${pool}.conf"
        done

        #disable pools
        for pool in $(get_list_items 'php-fpm.disable-pools' "${yml_current}"); do
          test -f "${phpfpm_pool_d[0]}/${pool}.conf" && {
            test -d "${storage_dir}" || mkdir -p "${storage_dir}"
            mv -vf "${phpfpm_pool_d[0]}/${pool}.conf" "${storage_dir}/${pool}.conf"
          }
        done
    }
    #manage mods
    for section in $(${yq_cmd} r "${yml_current}" 'php-fpm.enable-mods' | sed -e "/^\s/d;s/://"); do
      test -n "${section}" && {
        local target_dir="${php_dir}/${section}/conf.d"
        test -d "${target_dir}" && {

          #enable mods
          for mod in $(get_list_items "php-fpm.enable-mods.${section}" "${yml_current}"); do
            test -f "${mods_available_dir}/${mod}" && \
              ln -svrf "${mods_available_dir}/${mod}" "${target_dir}/35-${mod}"
          done

          #disable mods
          for mod in $(get_list_items "php-fpm.disable-mods.${section}" "${yml_current}"); do
            test -h "${target_dir}/${mod}" && \
              rm -vf "${target_dir}/${mod}"
          done
        }
      }
    done
  }
}

function setup_apache() {
  key_exists_in_current_yml "apache" && {
    local -r apache_stat_cfg='/etc/apache2/sites-available/stat.conf'
    local -r apache_sites_available='/etc/apache2/sites-available'
    local -r apache_sites_enabled='/etc/apache2/sites-enabled'
    local -r stat_servername=$(get_value 'apache.stat-servername' "${yml_current}")

    #change ServerName in stat host
    test -f "${apache_stat_cfg}" -a -n "${stat_servername}" && {
      sed -e "s/\(ServerName\)\(.*\)/\1 ${stat_servername}\n    ServerAlias localhost/" -i "${apache_stat_cfg}"
    }

    #enable vhosts
    for vhost in $(get_list_items 'apache.enable-vhosts' "${yml_current}"); do
      test -f "${apache_sites_available}/${vhost}.conf" && \
        ln -svrf "${apache_sites_available}/${vhost}.conf" "${apache_sites_enabled}/${vhost}.conf"
    done

    #disable vhosts
    for vhost in $(get_list_items 'apache.disable-vhosts' "${yml_current}"); do
      test -L "${apache_sites_enabled}/${vhost}.conf" && \
        rm -vf "${apache_sites_enabled}/${vhost}.conf"
    done
  }
}

function setup_postfix() {
  local -r postfix_main_cfg='/etc/postfix/main.cf'
  test -f "${postfix_main_cfg}" && {

    separator=" = "
    current_config_file="${postfix_main_cfg}"
    postfix_myhostname=$(get_value 'postfix.myhostname' "${yml_current}" "$(hostname -f)")

    grep -qP "^\s*${option}\s*" "${current_config_file}" && local param_found=1

    test -n "${param_found}" && {
      show_notice "Modifying param \"myhostname\" in ${current_config_file}"
      sed -r "s|^(\s*myhostname).+|\1${separator}${postfix_myhostname/&/\\&}|" -i "${current_config_file}"
    }
    test -n "${param_found}" || {
      show_notice "Adding param \"myhostname\" to ${current_config_file}"
      echo "myhostname${separator}${postfix_myhostname}" >> "${current_config_file}"
    }


    key_exists_in_current_yml "postfix" && {
      update_conf_parameter 'mynetworks'        'postfix.mynetworks'
      update_conf_parameter 'relayhost'         'postfix.relayhost'
      update_conf_parameter 'inet_interfaces'   'postfix.inet_interfaces'
      update_conf_parameter 'inet_protocols'    'postfix.inet_protocols'

      cron_subject_hostname=$(get_value 'postfix.cron-subject-hostname' "${yml_current}" "none")
      test "${cron_subject_hostname}" != "none" && {
        smtp_header_checks_string="$(grep -Pm1 "^(\s+)?smtp_header_checks" "${postfix_main_cfg}")"
        smtp_header_checks_cfg="${smtp_header_checks_string#*:}"
        show_notice "Modifying ${smtp_header_checks_cfg}"
        test -f "${smtp_header_checks_cfg}" && \
          sed -e "/^\/\^Subject: Cron.*REPLACE Subject/s/\[.*\]/\[${server_name}\/${cron_subject_hostname}\]/" -i "${smtp_header_checks_cfg}"
      }
    }
  }
}

function setup_ssh() {
  key_exists_in_current_yml "ssh" && {
    for user in $(get_keys 'ssh.authorized-keys' "${yml_current}"); do
      local public_key_file; public_key_file=$(get_value "ssh.authorized-keys.${user}" "${yml_current}")
      id "${user}" > /dev/null 2>&1 && test -f "${public_key_file}" && {
        local user_home; user_home=$(eval echo ~"${user}")
        test -d "${user_home}/.ssh" || mkdir -p "${user_home}/.ssh"
        cat "${public_key_file}" >> "${user_home}/.ssh/authorized_keys"
        chmod --quiet 600 "${user_home}/.ssh/authorized_keys"
        chown --quiet --recursive "${user}:" "${user_home}/.ssh"
      }
    done
  }
}

function setup_upstart() {
  key_exists_in_current_yml "upstart" && {
    local -r upstart_dir='/etc/init'
    test -d "${upstart_dir}" && {
      #enable
      enable_list=$(get_list_items 'upstart.enable' "${yml_current}")
      for service in ${enable_list}; do
        test -f "${upstart_dir}/${service}.conf" && {
          test -f "${upstart_dir}/${service}.override" && {
            sed -i '/^\s*manual\s*$/d' "${upstart_dir}/${service}.override"
          }
        }
        test -f "${upstart_dir}/${service}.conf" || {
          update-rc.d "${service}" enable
        }
      done

      #disable
      disable_list=$(get_list_items 'upstart.disable' "${yml_current}")
      for service in ${disable_list}; do
        test -f "${upstart_dir}/${service}.conf" && {
          echo manual >> "${upstart_dir}/${service}.override"
        }
        test -f "${upstart_dir}/${service}.conf" || {
          update-rc.d "${service}" disable
        }
      done
    }
  }
}

function setup_systemd() {
  key_exists_in_current_yml "systemd" && {
    local systemctl_bin; systemctl_bin=$(command -v systemctl) && {
      #enable
      enable_list=$(get_list_items 'systemd.enable' "${yml_current}")
      for service in ${enable_list}; do
        test -n "${service}" -a "${service}" != null && {
          "${systemctl_bin}" enable "${service}.service"
          "${systemctl_bin}" --no-block start "${service}.service"
        }
      done

      #disable
      disable_list=$(get_list_items 'systemd.disable' "${yml_current}")
      for service in ${disable_list}; do
        "${systemctl_bin}" disable "${service}.service"
        "${systemctl_bin}" --no-block stop "${service}.service"
      done
    }
  }
}

function setup_cron() {
  key_exists_in_current_yml "cron" && {
    local -r crontabs_dir='/var/spool/cron/crontabs'
    local -r storage_dir='cron.disabled'
    for user in $(get_keys 'cron' "${yml_current}"); do
      local crontab_file; crontab_file="${crontabs_dir}/${user}"
      test -f "${crontab_file}" && {
        for var in MAILTO PATH SHELL; do
          local value; value=$(get_value "cron.${user}.${var,,}" "${yml_current}")
          test -n "${value}" && {
            grep -qP "^${var^^}=" "${crontab_file}" && sed -r 's|^('"${var^^}"'=).+$|\1'"${value}"'|' -i "${crontab_file}"
            grep -qP "^${var^^}=" "${crontab_file}" || sed '1s|^|'"${var^^}=${value}"'\n|' -i "${crontab_file}"
          }
        done
      }
    done

    #managing /etc/cron.(d|daily|weekly|monthly)
    for section in $(${yq_cmd} r "${yml_current}" 'cron.system' | sed -e "/^\s/d;s/://"); do
      test -n "${section}" && {
        local target_dir="/etc/cron.${section/general/d}"
        test -d "${target_dir}" && {
          #enable
          for file in $(get_list_items "cron.system.${section}.enable" "${yml_current}"); do
            test -f "${target_dir}/${storage_dir}/${file}" && \
              cp -vf "${target_dir}/${storage_dir}/${file}" "${target_dir}/${file}"
          done

          #disable
          for file in $(get_list_items "cron.system.${section}.disable" "${yml_current}"); do
            test -f "${target_dir}/${file}" && {
              test -d "${target_dir}/${storage_dir}" || mkdir -p "${target_dir}/${storage_dir}"
              mv -vf "${target_dir}/${file}" "${target_dir}/${storage_dir}/${file}"
            }
          done
        }
      }
    done
  }
}

function setup_conf_backup() {
  local -r conf_backup_sl='/etc/cron.daily/conf-backup'
  local -r conf_backup_cnf='/usr/local/etc/backup-params.conf'
  test -h "${conf_backup_sl}" && rm -v "${conf_backup_sl}"
  test -f "${conf_backup_cnf}" && rm -v "${conf_backup_cnf}"
}

function setup_hlreport() {
  key_exists_in_current_yml "hlreport" && {
    local -r hlreport_main_cfg='/etc/default/hlreport'

    current_config_file="${hlreport_main_cfg}"
    separator="="

    test -f "${hlreport_main_cfg}" && {
      update_conf_parameter 'REPORT_DIR'            'hlreport.report_dir'
      update_conf_parameter 'REPORT_MYSQL'          'hlreport.report_mysql'
      update_conf_parameter 'REPORT_NGINX'          'hlreport.report_nginx'
      update_conf_parameter 'NGINX_STATUS'          'hlreport.nginx_status'
      update_conf_parameter 'REPORT_APACHE'         'hlreport.report_apache'
      update_conf_parameter 'APACHE_STATUS'         'hlreport.apache_status'
      update_conf_parameter 'REPORT_CONTAINERS'     'hlreport.report_containers'
      update_conf_parameter 'PROCS_TREE'            'hlreport.procs_tree'
      update_conf_parameter 'MYSQL_CLIENTCFG_FILE'  'hlreport.mysql_clientcfg_file'
    }
  }
}

function setup_mysql() {
  key_exists_in_current_yml "mysql" && {
    local -r mysql_conf_available='/etc/mysql/conf-available'
    local -r mysql_conf_enabled='/etc/mysql/conf-enabled'

    #enable configs
    for cnf in $(get_list_items 'mysql.enable-cfg' "${yml_current}"); do
      test -f "${mysql_conf_available}/${cnf}" && \
        ln -svrf "${mysql_conf_available}/${cnf}" "${mysql_conf_enabled}/${cnf}"
    done

    #disable configs
    for cnf in $(get_list_items 'mysql.disable-cfg' "${yml_current}"); do
      test -L "${mysql_conf_enabled}/${cnf}" && \
        rm -vf "${mysql_conf_enabled}/${cnf}"
    done
  }
}

function manage_users() {
  key_exists_in_current_yml "users" && {
    #lock users
    for username in $(get_list_items 'users.lock' "${yml_current}"); do
      show_notice "Locking user \"${username}\""
      lock_user "${username}" || show_fatal "User \"${username}\" locking failed!"
    done
    #unlock users
    for username in $(get_list_items 'users.unlock' "${yml_current}"); do
      show_notice "Unlocking user \"${username}\""
      unlock_user "${username}" || show_error "User \"${username}\" unlocking failed!"
    done
  }
}

function declare_profile_name() {
  current_profile_name=$(get_value profile.name "${yml_current}")
  test -n "${current_profile_name}" && { profile_name="${current_profile_name}"; declare -r profile_name; }
}

function setup_consul() {
  local -r consul_cfg_dir='/etc/consul.d'
  local -r consul_storage_dir="${consul_cfg_dir}/disabled"
  local -r consul_main_cfg="${consul_cfg_dir}/consul.json"
  local -r consul_srv_cfg="${consul_cfg_dir}/server.json"
  key_exists_in_current_yml "consul" && {
    test -f "${consul_main_cfg}" && {
      current_config_file="${consul_main_cfg}"
      update_json_parameter 'advertise_addr' 'consul.main.advertise_addr' 'string'
      update_json_parameter 'data_dir' 'consul.main.data_dir' 'string'
      update_json_parameter 'datacenter' 'consul.main.datacenter' 'string'
      update_json_parameter 'enable_local_script_checks' 'consul.main.enable_local_script_checks' 'bool'
      update_json_parameter 'server' 'consul.main.server' 'bool'
      update_json_parameter 'enable_syslog' 'consul.main.enable_syslog' 'bool'
      update_json_parameter 'disable_remote_exec' 'consul.main.disable_remote_exec' 'bool'
      update_json_parameter 'rejoin_after_leave' 'consul.main.rejoin_after_leave' 'bool'
      update_json_parameter 'encrypt' 'consul.main.encrypt' 'string'
      update_json_parameter 'node_name' 'consul.main.node_name' 'string'
      update_json_parameter 'pid_file' 'consul.main.pid_file' 'string'
      update_json_parameter 'retry_join' 'consul.main.retry_join' 'list'
    }
    test -f "${consul_srv_cfg}" && {
      current_config_file="${consul_srv_cfg}"
      update_json_parameter 'addresses' 'consul.server.addresses' 'dict'
      update_json_parameter 'ui' 'consul.server.ui' 'bool'
      update_json_parameter 'bootstrap' 'consul.server.bootstrap' 'bool'
    }

    #enable services
    test -d "${consul_storage_dir}" && {
      for service in $(get_list_items 'consul.enable-services' "${yml_current}"); do
        test -f "${consul_storage_dir}/${service}.json" && \
          cp -vf "${consul_storage_dir}/${service}.json" "${consul_cfg_dir}/${service}.json"
      done
    }

    #disable services
    for service in $(get_list_items 'consul.disable-services' "${yml_current}"); do
      test -f "${consul_cfg_dir}/${service}.json" && {
        test -d "${consul_storage_dir}" || mkdir -p "${consul_storage_dir}"
        mv -vf "${consul_cfg_dir}/${service}.json" "${consul_storage_dir}/${service}.json"
      }
    done
  }
}

function setup_hostname() {
  local -r system_hostname_file='/etc/hostname'
  local -r system_hosts_file='/etc/hosts'
  local -r key_name='hostname'
  local hostname_invalid=0

  key_exists_in_current_yml "${key_name}" && {

    old_hostname=$(hostname -f)
    new_hostname=$(get_value "${key_name}" "${yml_current}")
    hostname "${new_hostname}" &>/dev/null || {
      hostname_invalid=1
      show_error "Provided hostname is invalid"
    }
    test "${hostname_invalid}" -ne 1 && {
      show_notice "Modifying system hostname"
      sed -ri "s@(\s+)?${old_hostname}(\s+|$)?@\1${new_hostname}\2@g" "${system_hosts_file}"
      echo "${new_hostname}" > "${system_hostname_file}"
    }
  }
}

function setup_promtail() {
  local promtail_conf='/etc/promtail/promtail.yml'
  key_exists_in_current_yml "promtail.conffile" && {
    promtail_conf=$(get_value 'promtail.conffile' "${yml_current}")
  }

  # manage instance/source labels
  key_exists_in_current_yml "promtail.labels.instance" && \
    promtail_instance=$(get_value 'promtail.labels.instance' "${yml_current}") || \
      test -n "${promtail_instance}" || promtail_instance="${container_name}"
  key_exists_in_current_yml "promtail.labels.source" && \
    promtail_source=$(get_value 'promtail.labels.source' "${yml_current}") || \
      test -n "${promtail_source}" || promtail_source="${container_name}"
  sed -e "s/\(instance:\).*/\1 ${promtail_instance}/g" -i "${promtail_conf}"
  sed -e "s/\(source:\).*/\1 ${promtail_instance}/g" -i "${promtail_conf}"

  key_exists_in_current_yml "promtail.labels.env" && {
    promtail_env=$(get_value 'promtail.labels.env' "${yml_current}" "production")
    sed -e "s/\(env:\).*/\1 ${promtail_env}/g" -i "${promtail_conf}"
  }
  key_exists_in_current_yml "promtail.tenant-id" && {
    promtail_tenantid=$(get_value 'promtail.tenant-id' "${yml_current}")
    sed -e "s/\(tenant_id:\).*/\1 ${promtail_tenantid}/" -i "${promtail_conf}"
  }

  # manage limits
  for param in $(get_keys "promtail.limits" "${yml_current}"); do
    value="$(get_value "promtail.limits.${param}" "${yml_current}")"
    yq w -i "${promtail_conf}" "limits_config.${param}" "${value}"
  done

}
