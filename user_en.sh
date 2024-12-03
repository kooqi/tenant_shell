#!/bin/bash

# Check if the script is being run as the root user
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as the root user."
  exit 1
fi

# Check if the dev group exists, create it if not
if ! grep -q "^dev:" /etc/group; then
  echo "The user group 'dev' does not exist. Creating..."
  groupadd dev
  echo "The user group 'dev' has been created."
fi

# User input for username, validity period (in hours), and GPU IDs
read -p "Enter the username: " username
read -p "Enter the account validity period (in hours): " valid_hours
read -p "Enter the GPU IDs allowed (e.g., 0,1): " gpu_ids

# Check if any input is empty
if [ -z "$username" ] || [ -z "$valid_hours" ] || [ -z "$gpu_ids" ]; then
  echo "Username, validity period, and GPU IDs cannot be empty!"
  exit 1
fi

# Check if a user with the same username already exists
if id "$username" &>/dev/null; then
  echo "The user $username already exists!"
  exit 1
fi

# Apply a factor of 1.2 to calculate the actual validity period (in hours)
adjusted_hours=$(echo "$valid_hours * 1.2" | bc)
adjusted_seconds=$(echo "$adjusted_hours * 3600" | bc)

# Get the current time and calculate the expiration time
expire_time=$(date -d "+$adjusted_seconds seconds" +"%Y-%m-%d %H:%M")

# Generate a random initial password
initial_password=$(openssl rand -base64 12)

# Create the user, set the initial password, add them to the dev group, and configure password expiration
useradd -m -s /bin/bash -e "$(date -d "+$adjusted_seconds seconds" +%Y-%m-%d)" -g dev "$username"
echo "$username:$initial_password" | chpasswd
passwd --expire "$username"

# Create dedicated directories for the user under /data and set permissions
mkdir -p /data/"$username" /data/result/"$username"
chown "$username":dev /data/"$username" /data/result/"$username"
chmod 700 /data/"$username" /data/result/"$username"

# Configure GPU permissions
IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
for gpu_id in "${GPU_ARRAY[@]}"; do
  if [ -e /dev/nvidia"$gpu_id" ]; then
    chown "$username":dev /dev/nvidia"$gpu_id"
    echo "User $username has been granted access to GPU $gpu_id."
  else
    echo "Warning: GPU $gpu_id does not exist. Skipping configuration."
  fi
done

# Create a cleanup task to revoke GPU permissions and remove the user after expiration
cleanup_script="/usr/local/bin/cleanup_${username}.sh"
cat <<EOL > "$cleanup_script"
#!/bin/bash
# Revoke GPU permissions
for gpu_id in "${GPU_ARRAY[@]}"; do
  if [ -e /dev/nvidia\${gpu_id} ]; then
    chown root:root /dev/nvidia\${gpu_id}
    echo "Permissions for GPU \${gpu_id} have been revoked."
  fi
done
# Delete the user's data directory
rm -rf /data/"$username"
# Delete the user account
userdel -r "$username"
# Remove associated at tasks
for job in \$(atq | grep "$cleanup_script" | awk '{print \$1}'); do
  atrm \$job
done
# Delete this cleanup script
rm -f "$cleanup_script"
EOL
chmod +x "$cleanup_script"

# Schedule the cleanup task using the at command
echo "bash $cleanup_script" | at "$expire_time"

# Display user information
echo "User $username has been created and added to the 'dev' group."
echo "Initial password: $initial_password"
echo "Account valid until: $expire_time"
echo "Actual validity period (hours): $adjusted_hours (original $valid_hours hours multiplied by factor 1.2)"
echo "Allowed GPUs: $gpu_ids"
echo "The user must change their password immediately upon first login."
echo "After expiration, GPU permissions and user data will be automatically cleaned, and at tasks will be removed."
echo "Please save task results or models to /data/result/"$username", as this directory will not be deleted!"