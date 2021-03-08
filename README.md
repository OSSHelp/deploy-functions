# deploy-functions

[![Build Status](https://drone.osshelp.ru/api/badges/ansible/deploy-functions/status.svg)](https://drone.osshelp.ru/ansible/deploy-functions)

## About

This library is used for customization in the deploying process. It is used with default-setup script. And default-setup is run by cloud-init.

Supported software:

* Netdata
* Monit
* Postfix
* Ssmtp
* Nginx
* PHP-FPM
* Apache
* Cron
* SSH
* MySQL
* Consul

### How to use it

The library must be included in the default-setup script. How to use the library:

1. Place deploy-functions.sh library in the `/usr/local/include/osshelp/` path
1. Place default-setup script in the `/usr/local/osshelp` path and default-setup.local (if you need an additional customization)
1. Install yq and jq
1. Add nessary profiles to container yaml config which is using by lxhelper
1. Deploy container with lxhelper and make sure that the default-setup works as you expected

In the examples directory you can find a skeleton of default-setup.local and usage examples of available profiles.

There’re install/update scripts in the repository. Command for installation (deploy-function.sh, default-setup, yq and jq):

```shell
curl -s https://oss.help/scripts/backup/backup-functions/install.sh | bash
```

### Useful

As a library, deploy-functions is often used with [LXHelper](https://github.com/OSSHelp/lxhelper), but it's still possible to use it without LXHelper.

## FAQ

### Log

You can find log in `/var/log/default-setup.log`.

### Debug mode

If you want to run default-setup in debug mode, you need:

* Export INSTANCE_ID variable in the container
* Run default-setup by `bash -x` command

Example:

```bash
export INSTANCE_ID=container_name
bash -x /usr/local/osshelp/default-setup server_name
```

## Author

OSSHelp Team, see <https://oss.help>
