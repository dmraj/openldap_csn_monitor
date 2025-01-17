#!/bin/bash

# LDAP admin credentials
LDAP_ADMIN_DN="cn=admin,dc=example,dc=com"
LDAP_ADMIN_PASS="your_admin_password"

# Function to get syncrepl configurations
get_syncrepl_configs() {
    ldapsearch -x -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" -b "cn=config" "(olcSyncrepl=*)" olcSyncrepl | \
    grep -E 'olcSyncrepl|provider|binddn|credentials' | \
    awk '{print $2}' | \
    sed 'N;s/\n/ /' | \
    sed 's/^\(.*\) \(.*\) \(.*\) \(.*\)/\1 \2 \3/' | \
    sed 's/credentials=\(.*\)/credentials=\1/' 
}

# Declare an associative array to hold CSNs and bind details
declare -A csn_map
declare -A bind_details

# Collect syncrepl configurations
syncrepl_configs=$(get_syncrepl_configs)

# Parse syncrepl configurations into an associative array
while read -r line; do
    provider=$(echo "$line" | awk '{print $1}')
    binddn=$(echo "$line" | awk '{print $2}')
    credentials=$(echo "$line" | awk '{print $3}')
    
    # Store bind details in an associative array
    bind_details["$provider"]="$binddn $credentials"
done <<< "$syncrepl_configs"

# Function to get all ContextCSNs from a server
get_context_csns() {
    local server=$1
    local bind_info=${bind_details[$server]}
    
    # Extract binddn and credentials
    local binddn=$(echo "$bind_info" | awk '{print $1}')
    local credentials=$(echo "$bind_info" | awk '{print $2}')
    
    # Get ContextCSNs using ldapsearch
    ldapsearch -x -H "$server" -D "$binddn" -w "$credentials" -b "cn=monitor" "(objectClass=*)" contextCSN | grep contextCSN | awk '{print $2}'
}

# Collect CSNs from all servers
for server in "${!bind_details[@]}"; do
    csns=$(get_context_csns "$server")
    csn_map["$server"]="$csns"
    echo "$server: ContextCSNs=$csns"
done

# Function to convert CSN to a comparable format (removing colons)
convert_csn() {
    echo "$1" | tr -d ':'
}

# Find the latest CSN for each server and compare
for server in "${!csn_map[@]}"; do
    latest_csn=""
    
    # Split the CSNs into an array for comparison
    IFS=' ' read -r -a csn_array <<< "${csn_map[$server]}"
    
    # Determine the latest CSN for this server
    for csn in "${csn_array[@]}"; do
        current_csn_converted=$(convert_csn "$csn")
        if [[ -z "$latest_csn" || "$current_csn_converted" > "$latest_csn" ]]; then
            latest_csn="$current_csn_converted"
        fi
    done
    
    echo "Latest CSN for $server: $latest_csn"
    
    # Store the latest CSN for comparison later
    csn_map["$server_latest"]="$latest_csn"
done

# Compare all servers' latest CSNs with each other
for server in "${!csn_map[@]}"; do
    if [[ "$server" == *"_latest" ]]; then
        continue  # Skip the latest CSN entries in the comparison loop
    fi
    
    current_latest_csn="${csn_map["$server_latest"]}"
    
    if [[ "${csn_map[$server_latest]}" != "$current_latest_csn" ]]; then
        echo "Warning: $server is out of sync! Its latest CSN=${csn_map[$server_latest]}, expected latest CSN=$current_latest_csn"
        
        # Calculate the difference if needed (optional)
        diff=$((10#$current_latest_csn - 10#${csn_map[$server_latest]}))
        echo "Difference: $server is behind by $diff changes."
    else
        echo "Info: $server is in sync with the latest CSN."
    fi
done

echo "Synchronization check complete."
