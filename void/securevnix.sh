#!/bin/sh

set -eu

sudo xbps-install -Syu ufw nftables iptables-nft cryptsetup google-authenticator-libpam libqrencode spectre-meltdown-checker lynis linux-firmware socklog-void cronie chrony
sudo xbps-alternatives -s iptables-nft

sudo ln -sf /etc/sv/ufw /var/service
sudo ln -sf /etc/sv/socklog-unix /var/service
sudo ln -sf /etc/sv/nanoklogd /var/service
sudo ln -sf /etc/sv/cronie /var/service
sudo ln -sf /etc/sv/chronyd /var/service

sudo sh -c 'echo integrity > /sys/kernel/security/lockdown'

mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
tee -a ~/.ssh/authorized_keys <~/.ssh/id_ed25519.pub

google-authenticator -t -d -r 3 -R 30 -W

#ga_pam_line="auth requisite pam_google_authenticator.so"
#pw_pam_line="auth requisite pam_unix.so"
