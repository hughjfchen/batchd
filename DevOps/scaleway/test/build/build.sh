#!/usr/bin/env bash
if ! type dirname > /dev/null 2>&1; then
    echo "Not even a linux or macOS, Windoze? We don't support it. Abort."
    exit 1
fi

. "$(dirname "$0")"/../../../common/common.sh

init_with_root_or_sudo "$0"

begin_banner "batchd" "build build"

#set +u to workaround the nix script temperlately.
set +u
. $HOME/.nix-profile/etc/profile.d/nix.sh
set -u

if [ -f ${SCRIPT_ABS_PATH}/nix/batchd.nix ]; then
    if [ -e ${SCRIPT_ABS_PATH}/../../dev ] && [ -e ${SCRIPT_ABS_PATH}/../../../local ]; then
        # for doom-emacs
        [ -x ~/.emacs.d/bin/doom ] && echo "((nil . ((dante-target . \"batchd\"))))" > ${SCRIPT_ABS_PATH}/../../../../.dir-locals.el && nix-shell --run "~/.emacs.d/bin/doom env > /dev/null 2>&1" ${SCRIPT_ABS_PATH}/nix/shell.nix
        nix-shell ${SCRIPT_ABS_PATH}/nix/shell.nix
    else
        nix-build --show-trace -A batchd-docker ${SCRIPT_ABS_PATH}/nix/default.nix
    fi
else
    info "No ${SCRIPT_ABS_PATH}/nix/batchd.nix found, skip building"
fi

done_banner "batchd" "build build"
