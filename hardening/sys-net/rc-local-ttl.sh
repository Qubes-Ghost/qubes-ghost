# from the sys-net checklist by tommy, forum.qubes-os.org topic 43535
# Check name of vm first
REAL_VM_NAME=$(qubesdb-read /name)

# Only set TTL rule if it is vm sys-net
if [ "$REAL_VM_NAME" = "sys-net" ]; then
    # Create the table if it doesn't exist
    nft add table ip target_mangle
    # Create the chain linked to the postrouting hook
    nft add chain ip target_mangle outbound_normalize '{ type filter hook postrouting priority mangle ; }'
    # Force TTL to 64 for all outward traffic (except local loopback)
    nft add rule ip target_mangle outbound_normalize oif != "lo" ip ttl set 64
fi
