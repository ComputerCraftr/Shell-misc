#!/bin/sh
sudo cat /var/log/security | grep -F ' 3499 Count ' | awk '{print $10}' | cut -d ':' -f1 | sort -u | sudo xargs -I{} fail2ban-client set manualbans banip "{}"
