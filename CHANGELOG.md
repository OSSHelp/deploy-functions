# Changelog

## v1.20

* Container name is now used as the default value for Promtail instance/source labels

## v1.19

* Auto replacement of instance/source labels for Promtail
* Improved Promtail limits_config section generation (any future param changes support)

## v1.18

* Added Promtail profiles support

## v1.13

* Added default logs generation opportunity for Focal and Bionic (as it was made for Xenial and Trusty)

## v1.12

* Added Consul profiles support

## v1.11

* Added profiles names support for default_setup.local

## v1.10

* Fixed a bug when default-setup stops if profiles is absent in the container
* Fixed bugs in the functions that customize services (Nginx, Monit, etc)

## v1.09

* Fixed bug when default-setup sometimes stops if there was null value in profiles

## v1.08

* Nginx.stat-server-name key was renamed to nginx.stat-servername
* Added MySQL configuration files management
* Added system users management (lock/unlock)
* Updated setup_postfix function. Added header customization opportunity (for Cron emails).
* Updated setup_monit function. Now it doesn't delete files from conf.d but are moved to conf-disabled. It deletes only symlinks from conf-enabled. Fixed mail format in the main configuration file.
* Updated a list of folders for generation in `/var/log` (if they are absent)
* Added the package list checking. If a package is installed the library adds a folder into `/var/log`. Supported packages:
  * nginx
  * nginx-light
  * nginx-full
  * nginx-extras
  * php5-fpm
  * php-fpm5.5
  * php-fpm5.6
  * php-fpm7.0
  * php-fpm7.1
  * redis-server
  * proftpd-basic
  * lxd
  * MySQL
* Fixed a bug in the generation process of Monit main configuration file (related with monit.start-delay key)
* Fixed behavior of some functions. Now they don't try to change files if they are absent. This fix reduced log output.
* Fixed functions call order in default-setup

## v1.06

* Changed log path by /var/log/default-setup.log
* Added hlreports parameters management
* Fixed the type of /usr/local/osshelp/default-setup.local check
* Deleted duplicated functions (make_dir/make_file)
* Fixed bug with missing separator in `/etc/netdata/stream.conf` configuration process
* Added highload configuration (it works when Monit is present)
* Updated setup_phpfpm function (enable/disable ini files)
