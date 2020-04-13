#!/bin/bash

# Copyright (c) 2006 Red Hat, Inc. All rights reserved. This copyrighted material
# is made available to anyone wishing to use, modify, copy, or
# redistribute it subject to the terms and conditions of the GNU General
# Public License v.2.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# Author: Bill Peck <bpeck@redhat.com>

# Environment Variables
# $JOBID
# $DISTRO
# $ARCH
# $TEST
# $FAMILY
# $VARIANT
# $ARGS
# $CI

# source the test script helpers
. ../../../cki_lib/libcki.sh || exit 1
. kstub.sh

# Turn debug on if DEBUG is 'yes' or 'true', which is helpful to dig out
# internals for trouble shooting
function DEBUG ()
{
    typeset -l s=$DEBUG
    [[ $s == "yes" || $s == "true" ]] && \
        export PS4='[${FUNCNAME}@${BASH_SOURCE}:${LINENO}|${SECONDS}]+ ' && \
        set -x
}

# Check the test is run via CI. If it is, we should make sure task param
# which is needed for kernel-ci is added, e.g.
#     <params>
#         <param name="CI" value="yes"/>
#     </params>
function is_run_byci ()
{
    [[ $CI == "yes" ]] && return 0 || return 1
}

# Check command /usr/bin/rup does exist because package 'rusers'
# is no longer available on RHEL 8
function check_cmd_rup ()
{
    [[ -x /usr/bin/rup ]] && return 0
    echo "Oops, /usr/bin/rup not found" >&2
    echo "$(uname -a)" >&2
    return 1
}

function checkServers ()
{
    local foundserver=0
    local offlineserver=0
    local onlineservers=""
    local offlineservers=""
    local thisdom=`dnsdomainname`

    echo "" | tee -a $OUTPUTFILE
    echo " ========== Confirming NFS servers in domain are online ==========" | tee -a $OUTPUTFILE
    echo " ***** INFO: Current domain is \"$thisdom\" *****" | tee -a $OUTPUTFILE

    for S in $servers; do
        local server=$(echo $S | cut -f1 -d:)
        ping -c 3 $server >> $OUTPUTFILE 2>&1
        if [ $? != 0 ]; then
            echo " ***** Warn: $server not online or unavailable in this domain *****" | tee -a $OUTPUTFILE
            offlineserver=$(expr "$offlineserver" + 1)
            offlineservers=${offlineservers}"$server "
        else
            echo " ***** Confirmed: $server is online *****" | tee -a $OUTPUTFILE
            foundserver=$(expr "$foundserver" + 1)
            onlineservers=${onlineservers}"$S "
        fi
    done

    if [[ $foundserver -gt 0 && $offlineserver -eq 0 ]]; then
        echo "" | tee -a $OUTPUTFILE
        echo " ***** INFO: All servers in domain are online *****" | tee -a $OUTPUTFILE
        echo " ========== Continue testing... ==========" | tee -a $OUTPUTFILE
        echo "" | tee -a $OUTPUTFILE
    elif [[ $foundserver -gt 0 && $offlineserver -gt 0 ]]; then
        echo "" | tee -a $OUTPUTFILE
        echo " ***** Warn: Some servers are offline or unavailable in this domain *****" | tee -a $OUTPUTFILE
        echo " ========== Continue testing with online servers only... ==========" | tee -a $OUTPUTFILE
        echo "" | tee -a $OUTPUTFILE

        # Update online servers list
        servers=${onlineservers}

        if is_run_byci ; then
            if [[ -z $servers ]]; then
                # Not found online nfs servers
                echo "Not found online nfs server from the list, aborting the task" | tee -a $OUTPUTFILE
                rstrnt-report-result $TEST WARN/ABORTED
                # Abort the task
                rstrnt-abort --server $RSTRNT_RECIPE_URL/tasks/$TASKID/status
                exit 0
            else
                # Found online nfs servers
                echo ""
                echo "===================================="
                echo "Testing on online nfs servers:" | tee -a $OUTPUTFILE
                for S in $servers; do
                    local server=$(echo $S | cut -f1 -d:)
                    echo "   |__"${server} | tee -a $OUTPUTFILE
                done
                echo ""

                # if found offline servers
                if [[ ! -z $offlineservers ]]; then
                    echo ""
                    echo "================================="
                    echo "Skipping offline nfs servers:" | tee -a $OUTPUTFILE
                    for S in $offlineservers; do
                        echo "   |__"${S} | tee -a $OUTPUTFILE
                    done
                    echo ""
                fi
            fi
       else
          rstrnt-report-result $TEST WARN/ABORTED
       fi
    else
        local s390chk=$(/bin/hostname | awk -F. '{print $2}')
        if [ $s390chk = "z900" ]; then
            rstrnt-report-result $TEST PASS
        else
            rstrnt-report-result $TEST WARN/ABORTED
            if  is_run_byci ; then
                # nfs server list is empty
                echo "nfs server list is empty, aborting the task" | tee -a $OUTPUTFILE
                # Abort the task
                rstrnt-abort --server $RSTRNT_RECIPE_URL/tasks/$TASKID/status
            fi
        fi
        exit 0
    fi
}

function _cthon04 ()
{
    # redirect stdout & stderr to $OUTPUTFILE
    exec 5>&1 6>&2
    exec > $OUTPUTFILE 2>&1

    if [ -n "$PROFILE" ]; then
        PS4='+ $(date "+%H:%M:%S.%N")\011 '
        set -x
    fi
    # _cthon04 $fstype $test_name $report_path $server $nfspath $options
    local fstype=$1
    local test_name=$2
    local report_path=$3
    local server=$4
    local nfspath=$5
    local options=$6
    local test=$(echo $test_name| cut -f1 -d:)
    local name=$(echo $test_name| cut -f2 -d:)
    local tethereal_out="/mnt/testarea/${server}_${report_path}_${name}"
    local NET_DUMPER="tcpdump"

    if [ -f /usr/sbin/tshark ]; then
        NET_DUMPER="/usr/sbin/tshark"
    fi
    if [ -f /usr/sbin/tethereal ]; then
        NET_DUMPER="/usr/sbin/tethereal"
    fi
    if [ -n "$DISABLE_NETDUMPER" ]; then
        NET_DUMPER="/bin/false"
    fi
    echo "NET_DUMPER is $NET_DUMPER"

    $NET_DUMPER -q -i any -w $tethereal_out.cap host $server or host localhost 2>&1 &
    local tpid=$!
    sleep 5

    echo ""
    echo "===== Starting '$report_path' test '$name' ====="
    check_cmd_rup && echo "----- Server load `/usr/bin/rup $server` -----"
    echo "----- start: `/bin/date` -----"
    # log the command we used
    echo ./server $test -N $testRuns -F $fstype ${options} -p $nfspath $server
    # retry mount if there is a connection time out
    local mount_timeout_file=`mktemp`
    local counter=1

    for i in {1..10};
      do
        ./server $test -N $testRuns -F $fstype ${options} -p $nfspath $server > $mount_timeout_file 2>&1
        local result=$?
        cat $mount_timeout_file
        if grep -q "mount.nfs4\?: Connection timed out" $mount_timeout_file; then
          sleep 10
          let "counter++"
          continue
        else
          break
        fi
      done

    echo "----- end: `/bin/date` -----"
    check_cmd_rup && echo "----- Server load `/usr/bin/rup $server` -----"
    echo "----- return code: $result -----"
    echo "----- The following number of attempts were made to mount the server: $counter -----"

    kill $tpid 2>&1 &

    # print the mount point information before unmounting
    # try to see why we get "mkdir: cannot create directory
    # $SERVER: Read-only file system"
    mount
    umount /mnt/$server
    mount
    if mount|grep -q /mnt/$server 2>&1; then
        echo "----- umount failed, pls check umount function -----"
        result=1
    fi

    # restore stdout & stderr
    if [ -n "$PROFILE" ]; then
        set -x
    fi
    exec 1>&5 2>&6

    if [ $result = 0 ]; then
        if [ -z "$SKIP_SUBRESULT" ]; then
            local iswarn=`/bin/grep WARNING! $OUTPUTFILE | wc -l`
            if [ $iswarn -gt $result ]; then
                rstrnt-report-result $TEST/$server/$report_path/$name PASS $iswarn
            else
                rstrnt-report-result $TEST/$server/$report_path/$name PASS $result
            fi
        fi
        if [ -z "$SAVECAPTURE" ]; then
            rm -f $tethereal_out.cap > /dev/null 2>&1
        else
            bzip2 $tethereal_out.cap
        fi
    else
        bzip2 $tethereal_out.cap
        rstrnt-report-log -l $tethereal_out.cap.bz2
        rstrnt-report-result $TEST/$server/$report_path/$name FAIL $result
        if [ -z "$SAVECAPTURE_FAILED" ]; then
            rm -f $tethereal_out.cap.bz2 > /dev/null 2>&1
        fi
    fi

    # do a lazy unmount so the next test will run
    umount -l /mnt/$server >/dev/null 2>&1

    # backup and clear log
    local old_log="`mktemp /tmp/tmp.XXXXXX`"
    cp $OUTPUTFILE $old_log
    : > $OUTPUTFILE
    echo "log moved to: '$old_log'"

    return $result
}

# can return: 2 3 4 pNFS
function get_supported_client_versions ()
{
    local _nfsvers=""
    local kernel_supports_v2=1
    local kernel_supports_v3=1
    local kernel_supports_v4=1
    local kernel_supports_pnfs=1

    # old kernels do not support v4
    K_Vercmp "$(uname -r)" "2.4.22"
    if [ "$K_KVERCMP_RET" -le 0 ]; then
        echo "kernels <= 2.4.21 do not support nfs v4" | tee -a $OUTPUTFILE
        kernel_supports_v4=0
    fi

    # since RHEL7 kernels do not support NFSv2 as client
    # Bug 989238 - Remove NFS v2 support from RHEL 7 - kernel
    K_Vercmp "$(uname -r)" "3.10.0"
    if [ "$K_KVERCMP_RET" -ge 0 -a -e /boot/config-`uname -r` ]; then
        grep "CONFIG_NFS_V2=" /boot/config-`uname -r`
        if [ $? -ne 0 ]; then
            echo "This kernel does not support NFSv2" | tee -a $OUTPUTFILE
            kernel_supports_v2=0
        fi
    fi

    # only kernels above 6.4.z support pNFS
    K_Vercmp "$(uname -r)" "2.6.32-358"
    if [ "$K_KVERCMP_RET" -lt 0 ]; then
            echo "This kernel does not support pNFS" | tee -a $OUTPUTFILE
            kernel_supports_pnfs=0
    fi

    if [ $kernel_supports_v2 = 1 ]; then
        _nfsvers="$_nfsvers 2"
    fi
    if [ $kernel_supports_v3 = 1 ]; then
        _nfsvers="$_nfsvers 3"
    fi
    if [ $kernel_supports_v4 = 1 ]; then
        _nfsvers="$_nfsvers 4"
    fi
    if [ $kernel_supports_pnfs = 1 ]; then
        _nfsvers="$_nfsvers pNFS"
    fi

    echo "Client supports: $_nfsvers" | tee -a $OUTPUTFILE
    eval "$1='$_nfsvers'"
}

function get_supported_server_versions ()
{
    local server="$1"
    local _nfsvers=""
    local pnfs_test_mountpoint=`mktemp -d`
    local mount_pnfs_err_file=`mktemp`

    echo "Checking supported nfs versions for $server" | tee -a $OUTPUTFILE
    for n in 2 3 4; do
        rpcinfo -p "$server" | grep "nfs$" | awk '{print $2}' | grep "$n" >> $OUTPUTFILE 2>&1
        if [ $? -eq 0 ]; then
            _nfsvers="$_nfsvers $n"
        fi
    done

    mount -t nfs -o nfsvers=4 -ominorversion=1 $server:/ $pnfs_test_mountpoint > $mount_pnfs_err_file 2>&1
    if [ $? -eq 0 ]; then
        date > $pnfs_test_mountpoint/$(hostname).check && rm -f $pnfs_test_mountpoint/$(hostname).check
        if [ $? -eq 0 ]; then
            _nfsvers="$_nfsvers pNFS"
        else
            echo "Read-only file system" | tee -a $OUTPUTFILE
        fi
        umount $pnfs_test_mountpoint
    else
        grep -q "Protocol not supported" $mount_pnfs_err_file
        if [ $? -eq 0 ]; then
            echo "pNFS not supported by server"
        else
            grep -q "Bad nfs mount parameter: minorversion" $mount_pnfs_err_file
            if [ $? -eq 0 ]; then
                echo "pNFS not supported by client"
            else
                echo "Unexpected error from v41 mount of $server" | tee -a $OUTPUTFILE
                cat $mount_pnfs_err_file | tee -a $OUTPUTFILE
                rstrnt-report-result server_unexpected_v41_mount_err WARN/ABORTED
                if  is_run_byci ; then
                    # Abort the task
                   rstrnt-abort --server $RSTRNT_RECIPE_URL/tasks/$TASKID/status
                   exit 0
                fi

            fi
        fi
    fi

    echo "$server supports: $_nfsvers" | tee -a $OUTPUTFILE
    if [ -z "$_nfsvers" ]; then
            echo "No supported NFS versions for $server?" | tee -a $OUTPUTFILE
            rstrnt-report-result NoSupportedNFSVersions WARN/ABORTED
            if  is_run_byci ; then
                # Abort the task
                rstrnt-abort --server $RSTRNT_RECIPE_URL/tasks/$TASKID/status
                exit 0
            fi
    fi
    eval "$2='$_nfsvers'"
}

function get_ip_types ()
{
    local _types=""
    local server="$1"
    local nfsver="$2"
    local ipv6="$3"

    # Special condition:
    # Only if the special_server is rhel6 and the special_nfsver is v3,
    # the default transport protocol types are both tcp and udp.
    # For all other testing the default transport protocol type is tcp only.
    # Unless, of course, a param has been passed.
    # UDP and UDP6 are still filtered out of CTHONPROTOCOL parameter unless
    # CTHONPOVERRIDE parameter is also set.
    local special_server=${server%-*}

    if [ -z "$CTHONPROTOCOL" ]; then
      if [ "$nfsver" -ge 3 -a "$ipv6" -eq 1 ]; then
        _types="tcp tcp6"
      else
        _types="tcp"
      fi
    else
      if [ -n $CTHONPOVERRIDE ]; then
        _types=$CTHONPROTOCOL
      fi
    fi

    # Do not test ipv6 on rhel4 or rhel5 clients
    if [[ -e /boot/config-`uname -r` && "$K_VER" == "2.6.9" || "$K_VER" == "2.6.18" ]]; then
       _types=`echo $_types | sed -r "s/(tcp|udp)6//g"`
    fi

    echo "Supported IP types for $server/$nfsver: $_types" | tee -a $OUTPUTFILE
    eval "$4='$_types'"
}

function cthon_all ()
{
    local server=$1
    local nfspath=$2
    local ipv6=$3
    local SCORE=0
    local rc=0
    # globals:
    #   client_nfsvers
    #   server_nfsvers
    #   types

    get_supported_client_versions client_nfsvers
    get_supported_server_versions "$server" server_nfsvers
    [[ -n "$NFS_VERS" ]] && client_nfsvers=$NFS_VERS

    for nfsver in $client_nfsvers; do
        # check if server supports this nfsver
        echo "$server_nfsvers" | grep "$nfsver" > /dev/null
        if [ -z "$NFS_VERS" -a $? -ne 0 ]; then
            echo "$server does not support NFS:$nfsver"
            continue
        fi

        get_ip_types "$server" "$nfsver" $ipv6 types
        for type in $types; do
            for test_name in $tests; do
                echo "cthon_all: NFS v$nfsver IP:$type TEST:$test_name" | tee -a $OUTPUTFILE
                case $nfsver in
                [2-3])
                        # _cthon04 fstype test_name report_path server nfspath options
                        _cthon04 nfs $test_name "nfsvers=${nfsver}_${type}" $server $nfspath -onfsvers=$nfsver,proto=$type
                        rc=$?
                        ;;
                4)
                        # _cthon04 $fstype $test_name $report_path $server $nfspath $options
                        _cthon04 nfs4 $test_name "nfsvers=${nfsver}_${type}" $server $nfspath -oproto=$type,$MOUNT_OPT
                        rc=$?
                        ;;
                pNFS)
                        _cthon04 nfs4 $test_name "pNFS_${type}" $server / -ominorversion=1,proto=$type,$MOUNT_OPT
                        rc=$?
                        ;;
                esac
                [ $rc -ne 0 ] && SCORE=$(expr $SCORE + 1)
                echo -e "nfsvers=$nfsver\t$type\t$test_name\t$rc" >> result.txt
            done
        done
    done

    return $SCORE
}


function cthon_main ()
{
    pushd cthon04
    for server_path in $servers; do
        : > result.txt

        # start time
        local STIME=`date +%s`
        local server=$(echo $server_path| cut -f1 -d:)
        local nfspath=$(echo $server_path| cut -f2 -d:)
        local SCORE=0
        local server_is_pnfs=0
        local now=`date`
        local ipv6=0

        #
        # ServerStatus: Lets see if the server is online
        #
        ping -c 3 $server >> $OUTPUTFILE 2>&1
        if [ $? -ne 0 ]; then
            echo "" | tee -a $OUTPUTFILE
            echo " ===== cthon_main: $server is offline =====" | tee -a $OUTPUTFILE
            echo " ***** INFO: $now *****" | tee -a $OUTPUTFILE
            echo "" | tee -a $OUTPUTFILE
            continue
        fi

        # check ipv6 availability if server advertises NFS over tcp6
        # rpcinfo query goes over IPv4, so we try to ping it too
        if rpcinfo -s $server | grep 100003 | grep tcp6; then
            ipv6=1
            ping6 -c 3 $server >> $OUTPUTFILE 2>&1
            if [ $? -ne 0 ]; then
                local servertype=${server%-*}
                ipv6=0
                echo "" | tee -a $OUTPUTFILE
                echo " ===== cthon_main: $server is not reachable with ipv6 =====" | tee -a $OUTPUTFILE
                echo " ***** INFO: $now *****" | tee -a $OUTPUTFILE
                echo "" | tee -a $OUTPUTFILE
                continue
            fi
        fi

        echo "cthon_main, $server is online" | tee -a $OUTPUTFILE

        echo "Running cthon_all" | tee -a $OUTPUTFILE
        cthon_all $server $nfspath $ipv6
        SCORE=$(expr $SCORE + $?)

        # end & test time
        local ETIME=`date +%s`
        local TTIME=`expr $ETIME - $STIME`

        # format result.txt for tabbed alignment
        sed -i 's/lock/lock\t/g;s/base/base\t/g' result.txt
        echo "***** Summary for server '$server': '$SCORE' tests failed *****" | tee -a $OUTPUTFILE
        echo -e "NFS version\tType\tTest\tReturn code" | tee -a $OUTPUTFILE
        cat result.txt | tee -a $OUTPUTFILE
        echo "Total time: $TTIME" | tee -a $OUTPUTFILE

        if [ $SCORE -eq 0 ]; then
            if [ $TTIME -lt 1000 ]; then
                rstrnt-report-result $TEST/$server PASS $TTIME
            else
                echo "Time exceeded 1000 seconds" | tee -a $OUTPUTFILE
                if is_run_byci; then
                    echo "but it is run via CI, so also mark it as PASSED" | tee -a $OUTPUTFILE
                    rstrnt-report-result $TEST/$server PASS $TTIME
                else
                    rstrnt-report-result $TEST/$server WARN/COMPLETED $TTIME
                fi
            fi
        else
            rstrnt-report-result $TEST/$server FAIL $TTIME
        fi
    done
    popd
}

# ---------- Start Test -------------
#
DEBUG

echo "" | tee -a $OUTPUTFILE
echo " ***** Start of runtest.sh *****" | tee -a $OUTPUTFILE
echo "" | tee -a $OUTPUTFILE

if [ "$CTHONTESTRUNS" ]; then
    # We can specify the number of times to run the cthon test
    testRuns="$CTHONTESTRUNS"
    echo " ========== Override # of test runs =========="
    echo " ***** INFO: CTHONTESTRUNS=$CTHONTESTRUNS *****"
else
    # Default # of test runs is 1
    testRuns="1"
    echo " ========== Use default single test run ============"
fi

if [ -n "$CTHONSERVERS" ]; then
    # We can specify a list of servers it test against
    # For example, we can provide a customized list of
    # servers CTHONSERVER="host1-nfs host2-nfs host3-nfs"
    servers="$CTHONSERVERS"
    echo " ========== Override server list =========="
    echo " ***** INFO: CTHONSERVERS=$CTHONSERVERS *****"
else
    echo "server list should defined via env CTHONSERVERS" | tee -a $OUTPUTFILE
    if is_run_byci; then
        rstrnt-report-result $TEST WARN/ABORTED
        rstrnt-abort --server $RSTRNT_RECIPE_URL/tasks/$TASKID/status
        exit 0
    else
        exit 1
    fi
fi

# RHEL4 is no longer supported
servers=$(sed 's/rhel4[^[:space:]]*//' <<<$servers)

if [ "$CTHONTESTS" ]; then
    tests="$CTHONTESTS"
    echo " ========== Override cthon test list =========="
    echo " ***** INFO: CTHONTESTS=$CTHONTESTS *****"
else
    tests="-b:base -g:general -s:special -l:lock"
    echo " ========== Use default cthon test list =========="
fi

if [ "$CTHONPROTOCOL" ]; then
    types="$CTHONPROTOCOL"
    echo " ========== Override transport protocol type =========="
    echo " ***** INFO: CTHONPROTOCOL=$CTHONPROTOCOL *****"
else
    echo " ========== Use default transport protocol types =========="
    echo " ***** INFO: udp tcp - for RHEL6 NFSv3 testing only *****"
    echo " ***** INFO: tcp     - for all other testing *****"
    echo " ***** INFO: NFSv2   - for RHEL7 only if supported by kernel *****"
fi

checkRebootCount

checkServers

cthon_main

# End runtest.sh
