#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>>/var/log/first-boot.log 2>&1
set -x
set -e

# create user
grep -q "^ubuntu:" /etc/passwd && userdel ubuntu
grep -q "^ubuntu:" /etc/group && groupdel ubuntu

grep -q "^$LOGIN:" /etc/passwd || useradd -m -u 1000 "$LOGIN"

# set up data disk as DATA_DIR
# export data="/dev/disk/by-id/google-data
# try to mount data partition
mkdir -p /mnt/disks/data
if ! mount /dev/disk/by-id/google-data-part1 /mnt/disks/data; then
    # create partition
    parted -s /dev/disk/by-id/google-data mktable gpt
    parted -s /dev/disk/by-id/google-data mkpart primary 0% 100%
    # format data disk
    mkfs -t ext4 /dev/disk/by-id/google-data-part1
    # mount /dev/disk/by-id/google-data /mnt/
    # copy persistent data to data disk
    # tar c -C /var/lib . | tar x -C /mnt
    # umount /mnt
    mount /dev/disk/by-id/google-data-part1 /mnt/disks/data
fi
echo -e "/dev/disk/by-id/google-data-part1 /mnt/disks/data ext4 defaults,discard 0 0" >> /etc/fstab

# put images on the data disk
mkdir -p /mnt/disks/data/docker/
mkdir -p /var/lib/docker/
mount --bind /mnt/disks/data/docker/ /var/lib/docker/
echo -e "/mnt/disks/data/docker/ /var/lib/docker/ none defaults,bind 0 0" >> /etc/fstab

apt-get update && apt-get upgrade -y

# install docker
addgroup --system docker
adduser "$LOGIN" docker
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose

# enable docker over tls
sed -ie 's/-H fd:\/\/ //' /lib/systemd/system/docker.service
cat > /etc/docker/daemon.json <<EOF
{
  "tlsverify": true,
  "tlscacert": "/etc/docker/tls/ca.pem",
  "tlscert"  : "/etc/docker/tls/server-cert.pem",
  "tlskey"   : "/etc/docker/tls/server-key.pem",
  "hosts"    : ["fd://", "tcp://0.0.0.0:2376"]
}
EOF
systemctl daemon-reload
systemctl restart docker
systemctl enable docker

