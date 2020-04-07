#!/usr/bin/env bash
if ! type dirname > /dev/null 2>&1; then
    echo "Not even a linux or macOS, Windoze? We don't support it. Abort."
    exit 1
fi

. "$(dirname "$0")"/../../../common/common.sh

init_with_root_or_sudo "$0"

begin_banner "batchd" "deploy undeploy"

sudo sg docker -c "docker-compose -f /var/batchd/docker-compose-batchd.yml down"

done_banner "batchd" "deploy undeploy"
