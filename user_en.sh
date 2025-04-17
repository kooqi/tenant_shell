#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi

# Check if the dev group exists, create it if it doesn't
if ! getent group dev >/dev/null; then
  echo "Group dev does not exist, creating..."
  groupadd dev
  echo "Group dev has been created."
fi

# Prompt user for username, validity period (hours), and GPU IDs
read -p "Enter username: " username
read -p "Enter account validity period (hours): " valid_hours
read -p "Enter allowed GPU IDs (e.g., 0,1): " gpu_ids

# Check if inputs are empty
if [ -z "$username" ] || [ -z "$valid_hours" ] || [ -z "$gpu_ids" ]; then
  echo "Username, validity period, and GPU IDs cannot be empty!"
  exit 1
fi

# Validate that validity period is a number
if ! [[ "$valid_hours" =~ ^[0-9]+$ ]]; then
  echo "Validity period must be a positive integer!"
  exit 1
fi

# Check if a user with the same username already exists
if id "$username" >/dev/null 2>&1; then
  echo "User $username already exists!"
  exit 1
fi

# Apply a factor of 1.2 to calculate the actual validity period (hours)
adjusted_hours=$(echo "$valid_hours * 1.2" | bc)
adjusted_seconds=$(echo "$adjusted_hours * 3600" | bc | cut -d. -f1)

# Get current time and calculate expiration time
expire_time=$(date -d "+$adjusted_seconds seconds" +"%Y-%m-%d %H:%M" 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "Date calculation error, please check system time settings!"
  exit 1
fi

# Generate a random initial password
initial_password=$(openssl rand -base64 12)

# Create user, set initial password, add to dev group
useradd -m -s /bin/bash -e "$(date -d "+$adjusted_seconds seconds" +%Y-%m-%d)" -g dev "$username"
if [ $? -ne 0 ]; then
  echo "Failed to create user!"
  exit 1
fi

echo "$username:$initial_password" | chpasswd
passwd -e "$username"  # Force user to change password on login

# Check and add user to docker group (if it exists)
if getent group docker >/dev/null; then
  usermod -aG docker "$username"
fi

# Create dedicated directories for the user under /data and set permissions
mkdir -p /data/"$username" /data/result/"$username"
chown "$username":dev /data/"$username" /data/result/"$username"
chmod 700 /data/"$username" /data/result/"$username"

# Configure GPU permissions
IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
for gpu_id in "${GPU_ARRAY[@]}"; do
  if [ -e "/dev/nvidia$gpu_id" ]; then
    chown "$username":dev "/dev/nvidia$gpu_id"
    echo "User $username has been granted access to GPU $gpu_id."
  else
    echo "Warning: GPU $gpu_id does not exist, skipping."
  fi
done

# Create cleanup script
cleanup_script="/usr/local/bin/cleanup_${username}.sh"
cat <<EOL > "$cleanup_script"
#!/bin/bash
# Revoke GPU permissions
for gpu_id in ${GPU_ARRAY[*]}; do
  if [ -e "/dev/nvidia\${gpu_id}" ]; then
    chown root:root "/dev/nvidia\${gpu_id}"
    echo "GPU \${gpu_id} permissions have been revoked."
  fi
done
# Delete user's data directory
rm -rf "/data/$username"
# Delete user account
userdel -r "$username" 2>/dev/null
# Delete associated at jobs
for job in \$(atq | awk '\$6 ~ /${username}/ {print \$1}'); do
  atrm "\$job" 2>/dev/null
done
# Delete this cleanup script
rm -f "$cleanup_script"
EOL
chmod +x "$cleanup_script"

# Schedule cleanup task using at
echo "bash $cleanup_script" | at -t "$(date -d "$expire_time" +%Y%m%d%H%M)" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "Failed to schedule cleanup task!"
  exit 1
fi

# Display user information
echo "User $username has been created and added to the dev group."
echo "Initial password: $initial_password"
echo "Account valid until: $expire_time"
echo "Actual validity period (hours): $adjusted_hours (original $valid_hours hours, multiplied by 1.2)"
echo "Allowed GPUs: $gpu_ids"
echo "User must change password immediately upon login."
echo "After account expiration, GPU permissions and user data will be automatically cleaned up, and at jobs will be removed."
echo "Task outputs or models should be saved to /data/result/$username, this directory will not be deleted!"
