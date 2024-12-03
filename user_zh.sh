#!/bin/bash

# 检查是否以 root 用户运行脚本
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本。"
  exit 1
fi

# 检查是否存在 dev 组，如果不存在则创建
if ! grep -q "^dev:" /etc/group; then
  echo "用户组 dev 不存在，正在创建..."
  groupadd dev
  echo "用户组 dev 已创建。"
fi

# 用户输入用户名、有效期（小时）、和 GPU ID
read -p "请输入用户名: " username
read -p "请输入用户账户有效期（小时）: " valid_hours
read -p "请输入允许使用的 GPU 编号（例如 0,1）: " gpu_ids

# 检查是否输入为空
if [ -z "$username" ] || [ -z "$valid_hours" ] || [ -z "$gpu_ids" ]; then
  echo "用户名、有效期和 GPU 编号不能为空！"
  exit 1
fi

# 检查是否已经存在相同用户名的用户
if id "$username" &>/dev/null; then
  echo "用户 $username 已经存在！"
  exit 1
fi

# 应用系数 1.2 计算实际有效期（小时）
adjusted_hours=$(echo "$valid_hours * 1.2" | bc)
adjusted_seconds=$(echo "$adjusted_hours * 3600" | bc)

# 获取当前时间并计算到期时间
expire_time=$(date -d "+$adjusted_seconds seconds" +"%Y-%m-%d %H:%M")

# 生成随机初始密码
initial_password=$(openssl rand -base64 12)

# 创建用户，设置初始密码、添加到 dev 组，并设置密码过期策略
useradd -m -s /bin/bash -e "$(date -d "+$adjusted_seconds seconds" +%Y-%m-%d)" -g dev "$username"
echo "$username:$initial_password" | chpasswd
passwd --expire "$username"

# 在 /data 目录下为用户创建专属目录，并设置权限
mkdir -p /data/"$username" /data/result/"$username"
chown "$username":dev /data/"$username" /data/result/"$username"
chmod 700 /data/"$username" /data/result/"$username"

# 配置 GPU 权限
IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
for gpu_id in "${GPU_ARRAY[@]}"; do
  if [ -e /dev/nvidia"$gpu_id" ]; then
    chown "$username":dev /dev/nvidia"$gpu_id"
    echo "用户 $username 已被赋予 GPU $gpu_id 的访问权限。"
  else
    echo "警告: GPU $gpu_id 不存在，跳过设置。"
  fi
done

# 创建清理任务，在账户过期后收回 GPU 权限并清理 at 任务
cleanup_script="/usr/local/bin/cleanup_${username}.sh"
cat <<EOL > "$cleanup_script"
#!/bin/bash
# 收回 GPU 使用权限
for gpu_id in "${GPU_ARRAY[@]}"; do
  if [ -e /dev/nvidia\${gpu_id} ]; then
    chown root:root /dev/nvidia\${gpu_id}
    echo "GPU \${gpu_id} 的权限已收回。"
  fi
done
# 删除用户的数据目录
rm -rf /data/"$username"
# 删除用户账户
userdel -r "$username"
# 删除关联的 at 任务
for job in \$(atq | grep "$cleanup_script" | awk '{print \$1}'); do
  atrm \$job
done
# 删除此清理脚本
rm -f "$cleanup_script"
EOL
chmod +x "$cleanup_script"

# 使用 at 命令安排清理任务
echo "bash $cleanup_script" | at "$expire_time"

# 显示用户信息
echo "用户 $username 已创建，并加入 dev 用户组。"
echo "初始密码: $initial_password"
echo "账户有效期至: $expire_time"
echo "实际有效期（小时）: $adjusted_hours (原始 $valid_hours 小时，乘以系数 1.2)"
echo "允许访问的 GPU: $gpu_ids"
echo "用户登录后需要立即更改密码。"
echo "账户过期后将自动清理 GPU 权限和用户数据，并移除 at 任务。"
echo "任务输出的结果或模型请保存到/data/result/"$username"，此目录不会被删除！"