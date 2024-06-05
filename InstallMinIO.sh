#!/bin/bash
# Created by Dien Duong
# Variable config
user_name="minio-user"
group_name="minio-user"
login_user_name="admin"
login_password=""
disk_prefix="disk-"
service_file_path="/usr/lib/systemd/system/minio.service"
config_run_file_path="/etc/default/minio.sh"
nginx_config_path="/etc/nginx/sites-enabled/"
ip_subnet=$(ip route get 1.2.3.4 | awk '{print $7}')
public_ip=$(curl -s https://api.ipify.org)
unmountdisk=false
enableddomain=false
domainconsole=""
domaindashboardview=""

if [ $(whoami) != "root" ]; then
	echo "Please use the [root] user to execute the MinIO installation script!"
	exit 1
fi

is64bit=$(getconf LONG_BIT)
if [ "${is64bit}" != '64' ]; then
	echo "Sorry, min does not support 32-bit systems"
	exit 1
fi

echo
echo "======================================="
echo "Server Info"
echo "Subnet IP: ${ip_subnet}"
echo "Public IP: ${public_ip}"
echo "======================================="
echo

# Install update
apt-get update -y

# Install minIO
if [ -f "/usr/local/bin/minio" ]
then
	echo "minio existed"
else
	wget https://dl.min.io/server/minio/release/linux-amd64/minio
	chmod +x minio
	mv minio /usr/local/bin
	minio --version
fi

# Check create group_name
if grep -q "^$group_name:" /etc/group
then
	echo "group ${group_name} existed"
else
	echo "create group ${group_name}"
	sudo groupadd -r $group_name
fi

# Check create user
if id -u $user_name >/dev/null 2>&1; then
	echo "user ${user_name} existed"
else
	echo "create user ${user_name}"
	sudo useradd -M -r -g $user_name $group_name
fi

# Init disk
typedisk=""
while [[ -z $typedisk ]]; do
	read -p "Enter Load all disk type (mounted/unmount): " typedisk
done
if [[ $answer == "unmount" || $answer == "Unmount" ]]; then
	echo "List unmount disk"
	echo $(lsblk -nr | awk '$7 == "" {print $1,"\t\t",$4}')
else
	echo "List mounted disk"
	echo $(lsblk -nr | awk '$6 == "disk" {print $1,"\t\t",$4,"\n"}')
	unmountdisk=true
fi

num_disks=0
while [[ ! $num_disks =~ ^[1-9][0-9]*$ ]]; do
	read -p "Enter number disk unmount to add: " num_disks
done

disks=()

# Yêu cầu nhập tên từng ổ đĩa
for ((i=1; i<=num_disks; i++))
do
	disk_name=""
	while [[ -z $disk_name ]]; do
		read -p "Enter disk name $i: " disk_name
	done
	disks+=("$disk_name")
done

if (( ${#disks[@]} < 1 )); then
    echo "No disk name "
	exit 0
fi

# Hiển thị thông tin ổ đĩa đã nhập
echo "View list disk:"
for ((i=0; i<num_disks; i++))
do
	echo "Disk $((i+1)): ${disks[$i]}"
done

# Mount and grant disk to user
for ((i=0; i<num_disks; i++))
do
	foldermount="/${disk_prefix}$((i+1))"
	diskmount="/dev/${disks[$i]}"
	echo $foldermount
	echo $diskmount
	if [[ $unmountdisk == "true" ]]; then
		sudo umount $diskmount
	fi
	sudo mkdir -p $foldermount
	sudo file -s $diskmount
	sudo sudo mkfs -t ext4 $diskmount
	sudo mount $diskmount $foldermount
	sudo chown -R $user_name:$group_name $foldermount
	echo "$diskmount $foldermount ext4 defaults,nofail 0 0" >> /etc/fstab
done

# Create service systemd file
service_content="[Unit]
Description=MinIO
Documentation=https://min.io/docs/minio/linux/index.html
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=/usr/local/bin/minio

[Service]
WorkingDirectory=/usr/local

User=${user_name}
Group=${group_name}
ProtectProc=invisible
ExecStart=/etc/default/minio.sh

# MinIO RELEASE.2023-05-04T21-44-30Z adds support for Type=notify (https://www.freedesktop.org/software/systemd/man/systemd.service.html#Type=)
# This may improve systemctl setups where other services use \`After=minio.server\`
# Uncomment the line to enable the functionality
# Type=notify

# Let systemd restart this service always
Restart=always

# Specifies the maximum file descriptor number that can be opened by this process
LimitNOFILE=65536

# Specifies the maximum number of threads this process can create
TasksMax=infinity

# Disable timeout logic and wait until process is stopped
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target

# Built for \${project.name}-\${project.version} (\${project.name})"
echo "$service_content" | sudo tee "$service_file_path" >/dev/null

#Create password admin
while true; do
	read -s -p "Enter password admin: " login_password
	echo    # In một dòng trống để xuống dòng

	# Kiểm tra độ dài tối thiểu 8
	if (( ${#login_password} >= 8 )); then
		break  # Thoát khỏi vòng lặp nếu mật khẩu hợp lệ
	else
		echo "Password is too short. Minimum length requirement is 8."
	fi
done

#Create min config file
config_content="#!/bin/bash
# MINIO_ROOT_USER and MINIO_ROOT_PASSWORD sets the root account for the MinIO server.
# This user has unrestricted permissions to perform S3 and administrative API operations on any resource in the deployment.
# Omit to use the default values 'minioadmin:minioadmin'.
# MinIO recommends setting non-default values as a best practice, regardless of environment

export MINIO_ROOT_USER=${login_user_name}
export MINIO_ROOT_PASSWORD=${login_password}

# MINIO_VOLUMES sets the storage volume or path to use for the MinIO server.

export MINIO_VOLUMES=\"/disk-{1...${num_disks}}\" #multi drive 

# MINIO_OPTS sets any additional commandline options to pass to the MinIO server.
# For example, --console-address :9001 sets the MinIO Console listen port
export MINIO_OPTS=\"--console-address :9001\"

# MINIO_SERVER_URL sets the hostname of the local machine for use with the MinIO Server
# MinIO assumes your network control plane can correctly resolve this hostname to the local machine

# Uncomment the following line and replace the value with the correct hostname for the local machine and port for the MinIO server (9000 by default).

#MINIO_SERVER_URL=\"http://minio.example.net:9000\"

/usr/local/bin/minio server \$MINIO_OPTS \$MINIO_VOLUMES
"
echo "$config_content" | sudo tee "$config_run_file_path" >/dev/null
chmod +x $config_run_file_path

# Start MinIO service
sudo systemctl daemon-reload
sudo systemctl start minio.service
# sudo systemctl status minio.service
sudo systemctl enable minio.service

# Ip connect
read -p "Allow Ip connect dashboard? (y/n): " answer
if [[ $answer == "y" || $answer == "Y" ]]; then
	sudo ufw allow 9000:9001/tcp
fi

# Domain Connect
read -p "Allow domain connect? (y/n): " allowdomainanswer
if [[ $allowdomainanswer == "y" || $allowdomainanswer == "Y" ]]; then
	if which nginx >/dev/null 2>&1; then
		echo "Nginx is installed."
	else
		echo "Nginx is not installed."
		echo "Installing nginx"
		sudo apt update
		sudo apt install -y nginx
		sudo ufw allow 'Nginx Full'
		sudo systemctl enable nginx
	fi
	# Config nginx
	read -p "Enter domain console name (ex: s3.lizai.co): " domain
	read -p "Enter domain dashboard name (ex: dashboard.s3.lizai.co): " domaindashboard
	nginx_minio_content="upstream minio_s3 {
   least_conn;
   server 127.0.0.1:9000;
}

upstream minio_console {
   least_conn;
   server 127.0.0.1:9001;
}

server {
   listen       80;
   listen  [::]:80;
   server_name  ${domain};

   # Allow special characters in headers
   ignore_invalid_headers off;
   # Allow any size file to be uploaded.
   # Set to a value such as 1000m; to restrict file size to a specific value
   client_max_body_size 0;
   # Disable buffering
   proxy_buffering off;
   proxy_request_buffering off;

   location / {
	  proxy_set_header Host \$http_host;
	  proxy_set_header X-Real-IP \$remote_addr;
	  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	  proxy_set_header X-Forwarded-Proto \$scheme;

	  proxy_connect_timeout 300;
	  # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
	  proxy_http_version 1.1;
	  proxy_set_header Connection \"\";
	  chunked_transfer_encoding off;

	  proxy_pass http://minio_s3; # This uses the upstream directive definition to load balance
   }

}
server {
   listen       80;
   listen  [::]:80;
   server_name  ${domaindashboard};

   # Allow special characters in headers
   ignore_invalid_headers off;
   # Allow any size file to be uploaded.
   # Set to a value such as 1000m; to restrict file size to a specific value
   client_max_body_size 0;
   # Disable buffering
   proxy_buffering off;
   proxy_request_buffering off;

   location / {
	  rewrite ^/minio/ui/(.*) /\$1 break;
	  proxy_set_header Host \$http_host;
	  proxy_set_header X-Real-IP \$remote_addr;
	  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	  proxy_set_header X-Forwarded-Proto \$scheme;
	  proxy_set_header X-NginX-Proxy true;

	  # This is necessary to pass the correct IP to be hashed
	  real_ip_header X-Real-IP;

	  proxy_connect_timeout 300;

	  # To support websockets in MinIO versions released after January 2023
	  proxy_http_version 1.1;
	  proxy_set_header Upgrade \$http_upgrade;
	  proxy_set_header Connection \"upgrade\";
	  # Some environments may encounter CORS errors (Kubernetes + Nginx Ingress)
	  # Uncomment the following line to set the Origin request to an empty string
	  # proxy_set_header Origin '';

	  chunked_transfer_encoding off;

	  proxy_pass http://minio_console; # This uses the upstream directive definition to load balance
   }
}"
	echo "$nginx_minio_content" | sudo tee "$nginx_config_path${domain}.conf" >/dev/null
	sudo systemctl nginx restart
	enableddomain=true
	domainconsole="http://$domain"
	domaindashboardview="http://$domaindashboard"
	# Install ssl 
	read -p "Enable SSL for domain: $domain, $domaindashboard ? (y/n): " sslanswer
	if [[ $sslanswer == "y" || $sslanswer == "Y" ]]; then
		while true; do
			read -p "Did you set up the DNS for domain $domain and $domaindashboard to Public IP $public_ip? (y): " dnsanswer
			echo
			if [[ $dnsanswer == "y" || $dnsanswer == "Y" ]]; then
				sudo apt update
				sudo apt install -y certbot python3-certbot-nginx
				sudo certbot --nginx -d $domain -d $domaindashboard
				sudo certbot renew --dry-run
				domainconsole="https://$domain"
				domaindashboardview="https://$domaindashboard"
				break
			else
				echo "Please confirm that"
			fi
		done
		echo "Enable ssl success"
	fi
	
fi

echo
echo "======================================="
echo "Connect Dashboard: ${public_ip}:9001 or ${ip_subnet}:9001"
if [[ $enableddomain == "true" ]]; then
	echo "Domain connect: ${domaindashboardview}"
	echo "Console connect: ${domainconsole}"
fi
echo "Login Info"
echo "Username: ${login_user_name}"
echo "Password: ${login_password}"
echo "======================================="
echo