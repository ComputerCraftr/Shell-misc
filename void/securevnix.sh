#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[ -n "$RUN_HOME" ] || RUN_HOME="/root"

run_as_user() {
    chpst -u "$RUN_USER" -- "$@"
}

xbps_install() {
    if command -v torsocks >/dev/null 2>&1; then
        torsocks xbps-install "$@"
    else
        xbps-install "$@"
    fi
}

xbps_install -Suy ufw nftables iptables-nft cryptsetup google-authenticator-libpam libqrencode spectre-meltdown-checker lynis linux-firmware socklog-void cronie chrony
xbps-alternatives -s iptables-nft

ln -sf /etc/sv/ufw /var/service
ln -sf /etc/sv/socklog-unix /var/service
ln -sf /etc/sv/nanoklogd /var/service
ln -sf /etc/sv/cronie /var/service
ln -sf /etc/sv/chronyd /var/service

# Reset UFW to flush any existing rules and disable it
ufw --force reset
ufw enable
ufw allow in from 10.1.0.0/16 to any port 22 proto tcp
ufw allow in from 10.1.0.0/16 to any port 5201
ufw allow in from fe80::/10 to any port 22 proto tcp
ufw allow in from fe80::/10 to any port 5201

ensure_kernel_lockdown() {
    LOCKDOWN_BLOCK=$(
        cat <<EOF
if [ -r /sys/kernel/security/lockdown ] && grep -qF '[none]' /sys/kernel/security/lockdown 2>/dev/null; then
    echo integrity >/sys/kernel/security/lockdown 2>/dev/null || true
fi
EOF
    )

    if [ ! -f /etc/rc.local ]; then
        cat <<EOF >/etc/rc.local
#!/bin/sh
set -eu
$LOCKDOWN_BLOCK
EOF
        chmod +x /etc/rc.local
        return
    fi

    # Ensure kernel lockdown is set on every boot
    if ! grep -qF 'echo integrity >/sys/kernel/security/lockdown' /etc/rc.local; then
        printf '%s\n' "$LOCKDOWN_BLOCK" >>/etc/rc.local
    fi

    # Set kernel lockdown if it is not currently active
    if [ -r /sys/kernel/security/lockdown ] && grep -qF '[none]' /sys/kernel/security/lockdown 2>/dev/null; then
        echo integrity >/sys/kernel/security/lockdown 2>/dev/null || true
    fi
}

ensure_kernel_lockdown

run_as_user mkdir -p "$RUN_HOME/.ssh"
run_as_user chmod 700 "$RUN_HOME/.ssh"
if [ ! -f "$RUN_HOME/.ssh/id_ed25519.pub" ]; then
    run_as_user ssh-keygen -t ed25519 -f "$RUN_HOME/.ssh/id_ed25519" -N ''
    run_as_user dd if="$RUN_HOME/.ssh/id_ed25519.pub" of="$RUN_HOME/.ssh/authorized_keys" oflag=append conv=notrunc status=none
fi

if [ ! -f "$RUN_HOME/.google_authenticator" ]; then
    run_as_user google-authenticator -t -d -r 3 -R 30 -W -s "$RUN_HOME/.google_authenticator"
fi

# Configure PAM for SSHD: require Google Authenticator and Unix auth, handle different include lines
pam_file=/etc/pam.d/sshd
ga_line="auth requisite pam_google_authenticator.so"
pw_line="auth requisite pam_unix.so"
ga_re='^auth[[:space:]]+requisite[[:space:]]+pam_google_authenticator\.so([[:space:]]|$)'
pw_re='^auth[[:space:]]+requisite[[:space:]]+pam_unix\.so([[:space:]]|$)'

# Determine which include directive exists (system-auth or common-auth)
if grep -qE '^auth[[:space:]]+include[[:space:]]+system-auth' "$pam_file"; then
    target='system-auth'
elif grep -qE '^auth[[:space:]]+include[[:space:]]+common-auth' "$pam_file"; then
    target='common-auth'
else
    target=''
fi

# Insert Google Authenticator line if missing
if ! grep -qE "$ga_re" "$pam_file"; then
    if [ -n "$target" ]; then
        sed -i -E "/^auth[[:space:]]+include[[:space:]]+$target/i $ga_line" "$pam_file"
    else
        sed -i "1i $ga_line" "$pam_file"
    fi
fi

# Insert Unix auth line if missing, placing it immediately after the GA line or at top
if ! grep -qE "$pw_re" "$pam_file"; then
    if grep -qE "$ga_re" "$pam_file"; then
        sed -i -E "/$ga_re/a $pw_line" "$pam_file"
    else
        sed -i "1i $pw_line" "$pam_file"
    fi
fi

# Enforce PAM and 2FA in sshd_config
sed -i \
    -e 's/^#\?UsePAM .*/UsePAM yes/' \
    -e 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' \
    -e 's/^#\?AuthenticationMethods .*/AuthenticationMethods publickey,password publickey,keyboard-interactive/' \
    -e 's/^#\?UseDNS .*/UseDNS no/' \
    /etc/ssh/sshd_config

# Restart SSH service
echo 'Please restart the SSH service with: sv restart sshd'
