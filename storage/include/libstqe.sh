#!/bin/bash
#
# Copyright (c) 2019 Red Hat, Inc. All rights reserved.
#
# This copyrighted material is made available to anyone wishing
# to use, modify, copy, or redistribute it subject to the terms
# and conditions of the GNU General Public License version 2.
#
# This program is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
# PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public
# License along with this program; if not, write to the Free
# Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
# Boston, MA 02110-1301, USA.
#

source $(dirname $(readlink -f $BASH_SOURCE))/../../cki_lib/libcki.sh

STQE_GIT="https://gitlab.com/rh-kernel-stqe/python-stqe.git"
STQE_STABLE_VERSION=${STQE_STABLE_VERSION:-"f1ddf69b"}
LIBSAN_STABLE_VERSION=${LIBSAN_STABLE_VERSION:-"0.3.0"}

function stqe_get_fwroot
{
    typeset fwroot="/var/tmp/$(basename $STQE_GIT | sed 's/.git//')"
    echo $fwroot
}

function stqe_init_fwroot
{
    typeset fwbranch=$1

    # clone the framework
    typeset fwroot=$(stqe_get_fwroot)
    cki_run_cmd_neu "rm -rf $fwroot"
    cki_run_cmd_pos "git clone $STQE_GIT $fwroot" || \
        cki_abort_task "fail to clone $STQE_GIT"

    # install the framework
    cki_cd $fwroot

    #
    # XXX: On RHEL7, should use python2 instead because python3
    #      is not available by default
    #
    typeset python=""
    typeset cmd=""
    for cmd in python python3 python2; do
        $cmd -V > /dev/null 2>&1 && python=$cmd && break
    done
    [[ -n $python ]] || cki_skip_task "python not found"

    typeset pip_cmd=$([[ $python == python3 ]] && echo pip3 || echo pip)
    if [[ $fwbranch != "master" ]]; then
        if [[ -n $STQE_STABLE_VERSION ]]; then
            cki_run_cmd_pos "git checkout $STQE_STABLE_VERSION" || \
                cki_abort_task "fail to checkout $STQE_STABLE_VERSION"
        fi
        if [[ -n $LIBSAN_STABLE_VERSION ]]; then
            cki_run_cmd_pos "$pip_cmd install libsan==$LIBSAN_STABLE_VERSION" || \
                cki_abort_task "fail to install libsan==$LIBSAN_STABLE_VERSION"
        fi
    fi

    # install required packages
    cki_run_cmd_neu "bash env_setup.sh"

    cki_run_cmd_pos "$python setup.py install --prefix=" || \
        cki_abort_task "fail to install test framework"

    cki_pd

    return 0
}

function stqe_fini_fwroot
{
    typeset fwroot=$(stqe_get_fwroot)
    cki_run_cmd_neu "rm -rf $fwroot"
}
