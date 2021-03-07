#!/bin/bash
# shellcheck disable=SC2015

umask 0077
export LANG=C
export LC_ALL=C

df_ver=1.15
silent=no
tmpdir="${TEMP:=/tmp}"

index_url="${REMOTE_URI:-https://oss.help/scripts/lxc/deploy-functions/.list}"
list_name=$(basename "${index_url}")
script_name="default-setup"
script_path="/usr/local/osshelp"
lib_name="deploy-functions.sh"
lib_path="/usr/local/include/osshelp"
yq_bin='yq'
yq_bin_path='/usr/local/bin'
shacmd=$(command -v sha256sum || command -v gsha256sum 2>/dev/null)
err=0

function show_notice() { test "${silent}" != "yes" && echo -e "[NOTICE] ${*}"; return 0; }
function show_error() { echo -e "[ERROR] ${*}" >&2; err=1; return 1; }

function fetch_files() {
  cd "${1}" && {
    {
      wget -q -P "${1}" "${index_url}" && \
        wget -q -i "${1}/${list_name}" -P "${1}"
        test -f  SHA256SUMS || show_error "File SHA256SUMS does not found."
    } && {
      "${shacmd}" -c --status SHA256SUMS 2> /dev/null || {
        show_error "Something went wrong, checksums of downloaded files mismatch."
        "${shacmd}" -c "${1}/SHA256SUMS"
        return 1
      }
    }
  }
}

function install_files() {
        test -d "${script_path}" || mkdir "${script_path}"
        cd "${script_path}" && \
        mv "${tmp_dir}/${script_name}" "${script_path}/${script_name}" && \
        chmod 700 "${script_path}/${script_name}"

        test -d "${lib_path}" || mkdir "${lib_path}"
        cd "${lib_path}" && \
        mv "${tmp_dir}/${lib_name}" "${lib_path}/${lib_name}" && \
        chmod 600 "${lib_path}/${lib_name}"

       test -x "${script_path}/${script_name}" || show_error "${script_name} hasn't been installed."
       test -f "${lib_path}/${lib_name}"|| show_error "${lib_name} hasn't been installed."
}

function install_jq() {
        command -v apt-get > /dev/null 2>&1 && {
            apt-get -qq update && apt-get -qqy install jq
        }
        command -v yum > /dev/null 2>&1 && yum -qy install jq
        command -v jq > /dev/null 2>&1 && show_notice "Jq ($(jq --version)) has been installed."
        command -v jq > /dev/null 2>&1 || show_error "Jq hasn't been installed."
}

test "$(id -u)" != "0" && { show_error "Sorry, but you must run this script as root."; exit 1; }

tmp_dir="${tmpdir}/deploy-functions.$$"
mkdir -p "${tmp_dir}" && \
fetch_files "${tmp_dir}" && \
install_files "${tmp_dir}" && {
        test -x "${yq_bin_path}/${yq_bin}" || curl -s https://oss.help/scripts/tools/yq/install.sh | bash
        install_jq
        show_notice "Library ${lib_name} (v${df_ver}) was installed to ${lib_path}."
        show_notice "Script ${script_name} was installed to ${script_path}."
}

test -d "${tmp_dir}" && rm -rf "${tmp_dir}"
exit "${err}"
