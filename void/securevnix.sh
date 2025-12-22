#!/bin/sh
set -eu

if command -v torsocks >/dev/null 2>&1; then
    sudo torsocks xbps-install -Syu ufw nftables iptables-nft cryptsetup google-authenticator-libpam libqrencode spectre-meltdown-checker lynis linux-firmware socklog-void cronie chrony
else
    sudo xbps-install -Syu ufw nftables iptables-nft cryptsetup google-authenticator-libpam libqrencode spectre-meltdown-checker lynis linux-firmware socklog-void cronie chrony
fi
sudo xbps-alternatives -s iptables-nft

sudo ln -sf /etc/sv/ufw /var/service
sudo ln -sf /etc/sv/socklog-unix /var/service
sudo ln -sf /etc/sv/nanoklogd /var/service
sudo ln -sf /etc/sv/cronie /var/service
sudo ln -sf /etc/sv/chronyd /var/service

# Reset UFW to flush any existing rules and disable it
sudo ufw --force reset
sudo ufw enable
sudo ufw allow in from 10.1.0.0/16 to any port 22 proto tcp
sudo ufw allow in from 10.1.0.0/16 to any port 5201
sudo ufw allow in from fe80::/10 to any port 22 proto tcp
sudo ufw allow in from fe80::/10 to any port 5201

# Set kernel lockdown if it is not currently active
if [ -r /sys/kernel/security/lockdown ] && grep -qF '[none]' /sys/kernel/security/lockdown 2>/dev/null; then
    sudo sh -c 'echo integrity > /sys/kernel/security/lockdown 2>/dev/null || :'
fi
if [ ! -f /etc/rc.local ]; then
    sudo tee /etc/rc.local <<EOF
#!/bin/sh
set -eu
if [ -r /sys/kernel/security/lockdown ] && grep -qF '[none]' /sys/kernel/security/lockdown 2>/dev/null; then
    echo integrity > /sys/kernel/security/lockdown 2>/dev/null || :
fi
EOF
    sudo chmod +x /etc/rc.local
fi

# Ensure kernel lockdown is set on every boot
if ! sudo grep -qF 'echo integrity > /sys/kernel/security/lockdown' /etc/rc.local; then
    sudo tee -a /etc/rc.local <<EOF
if [ -r /sys/kernel/security/lockdown ] && grep -qF '[none]' /sys/kernel/security/lockdown 2>/dev/null; then
    echo integrity > /sys/kernel/security/lockdown 2>/dev/null || :
fi
EOF
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519.pub ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
    tee -a ~/.ssh/authorized_keys <~/.ssh/id_ed25519.pub
fi

if [ ! -f ~/.google_authenticator ]; then
    google-authenticator -t -d -r 3 -R 30 -W
fi

# Configure PAM for SSHD: require Google Authenticator and Unix auth, handle different include lines
pam_file=/etc/pam.d/sshd
ga_line="auth requisite pam_google_authenticator.so"
pw_line="auth requisite pam_unix.so"
ga_re='^auth[[:space:]]+requisite[[:space:]]+pam_google_authenticator\.so([[:space:]]|$)'
pw_re='^auth[[:space:]]+requisite[[:space:]]+pam_unix\.so([[:space:]]|$)'

# Determine which include directive exists (system-auth or common-auth)
if sudo grep -qE '^auth[[:space:]]+include[[:space:]]+system-auth' "$pam_file"; then
    target='system-auth'
elif sudo grep -qE '^auth[[:space:]]+include[[:space:]]+common-auth' "$pam_file"; then
    target='common-auth'
else
    target=''
fi

# Insert Google Authenticator line if missing
if ! sudo grep -qE "$ga_re" "$pam_file"; then
    if [ -n "$target" ]; then
        sudo sed -i -E "/^auth[[:space:]]+include[[:space:]]+$target/i $ga_line" "$pam_file"
    else
        sudo sed -i "1i $ga_line" "$pam_file"
    fi
fi

# Insert Unix auth line if missing, placing it immediately after the GA line or at top
if ! sudo grep -qE "$pw_re" "$pam_file"; then
    if sudo grep -qE "$ga_re" "$pam_file"; then
        sudo sed -i -E "/$ga_re/a $pw_line" "$pam_file"
    else
        sudo sed -i "1i $pw_line" "$pam_file"
    fi
fi

# Enforce PAM and 2FA in sshd_config
sudo sed -i \
    -e 's/^#\?UsePAM .*/UsePAM yes/' \
    -e 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' \
    -e 's/^#\?AuthenticationMethods .*/AuthenticationMethods publickey,password publickey,keyboard-interactive/' \
    -e 's/^#\?UseDNS .*/UseDNS no/' \
    /etc/ssh/sshd_config

# Restart SSH service
echo 'sudo sv restart sshd'
