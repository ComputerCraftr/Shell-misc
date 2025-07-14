#!/bin/sh
sudo ipfw table fail2ban list | awk -F '[ ./]' '{
    # Extract first three octets for subnet
    subnet = sprintf("%s.%s.%s.0", $1, $2, $3)
    count[subnet]++

    # Extract full IP
    full_ip = sprintf("%s.%s.%s.%s", $1, $2, $3, $4)

    # Ensure we do NOT add the subnet itself (e.g., 167.94.145.0)
    if (full_ip != subnet) {
        ips[subnet] = ips[subnet] ? ips[subnet] " " full_ip : full_ip  # Store as space-separated list
    }
}
END {
    for (subnet in count) {
        if (count[subnet] > 1) {
            print subnet "/24|" ips[subnet];
        }
    }
}' | while IFS='|' read -r subnet ip_list; do
    echo "Banning subnet: $subnet"
    sudo fail2ban-client set manualbans banip "$subnet"

    # Iterate over each IP in ip_list
    for ip in $ip_list; do
        # Ensure we're only unbanning individual IPs (not the subnet itself)
        if [ "$ip" != "${subnet%/24}" ]; then
            echo "Unbanning individual IP: $ip (Already covered by $subnet)"
            sudo fail2ban-client set manualbans unbanip "$ip"
        fi
    done
done
