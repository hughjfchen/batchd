#!/usr/bin/env bash
if ! type dirname > /dev/null 2>&1; then
    echo "Not even a linux or macOS, Windoze? We don't support it. Abort."
    exit 1
fi

. "$(dirname "$0")"/../../../common/common.sh

init_with_root_or_sudo "$0"

begin_banner "batchd" "deploy prepare"

if [ ! -L ${SCRIPT_ABS_PATH}/../../../../result ]; then
    warn "no batchd build result found, suppose that the image would be pull from registry"
else
    sudo sg docker -c "docker load -i ${SCRIPT_ABS_PATH}/../../../../result"
fi

set +e
myGroup2=$(awk -F":" '{print $1}' /etc/group | grep -w batchd)
set -e
if [ "X${myGroup2}" = "X" ]; then
    info "no batchd group defined yet, create it..."
    sudo groupadd -f --gid 90001 batchd
fi

set +e
myUser2=$(awk -F":" '{print $1}' /etc/passwd | grep -w batchd)
set -e
if [ "X${myUser2}" = "X" ]; then
    info "no batchd user defined yet, create it..."
    sudo useradd -G docker -m -p Passw0rd --uid 90001 --gid 90001 batchd
fi

if [ ! -d /var/batchd ]; then
    info "no /var/batchd directory found, create it..."
    sudo mkdir -p /var/batchd/data
    sudo mkdir -p /var/batchd/config
    sudo chown -R batchd:batchd /var/batchd
fi

sudo cp ${SCRIPT_ABS_PATH}/docker-compose.yml /var/batchd/docker-compose-batchd.yml.orig
sudo chown batchd:batchd /var/batchd/docker-compose-batchd.yml.orig

sudo sed "s:batchd_config_path:/var/batchd/config:g" < /var/batchd/docker-compose-batchd.yml.orig | sudo su -p -c "dd of=/var/batchd/docker-compose-batchd.yml.01" batchd 
sudo sed "s:batchd_data_path:/var/batchd/data:g" < /var/batchd/docker-compose-batchd.yml.01 | sudo su -p -c "dd of=/var/batchd/docker-compose-batchd.yml" batchd

if [ -L ${SCRIPT_ABS_PATH}/../../../../result ]; then
    batchd_IMAGE_ID=$(sudo sg docker -c "docker images"|grep -w batchd|awk '{print $3}')
    cmdPath=$(sudo sg docker -c "docker image inspect ${batchd_IMAGE_ID}" | grep "/nix/store/" | awk -F"/" '{print "/nix/store/"$4}')
    sudo sed "s:static_batchd_nix_store_path:${cmdPath}:g" < /var/batchd/docker-compose-batchd.yml | sudo su -p -c "dd of=/var/batchd/docker-compose-batchd.yml.02" batchd
    sudo cat /var/batchd/docker-compose-batchd.yml.02 | sudo su -p -c "dd of=/var/batchd/docker-compose-batchd.yml" batchd
fi

done_banner "batchd" "deploy prepare"
