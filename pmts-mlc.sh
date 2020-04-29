#!/usr/bin/env bash
#
# BSD-3-Clause
# Copyright 2020, Steve Scargall 
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
# 
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in
#       the documentation and/or other materials provided with the
#       distribution.
# 
#     * Neither the name of the copyright holder nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#
# This script uses Intel Memory Latency Checker (MLC) to measure 
# bandwidth and latency for Intel® Optane™ Persistent Memory 
# configured in App Direct mode.
#
# It will auomatically detect the number of PMem modules mapped
# to the specified pmem mount path (namespace).
#
# Before running this, you need to make a filesystem on the namespace and
# mount it using the dax option:
#
# Create an App Direct (Interleaved) goal/configuration
#   sudo ipmctl create -goal PersistentMemoryType=AppDirect
#   sudo systemctl reboot
#
# Create namespaces (ndctl v65 or later)
#   sudo ndctl create-namespace --continue
#
# Create namespaces (ndctl prior to v65)
#   2-Socket system:
#   sudo ndctl create-namespace --region 0 --mode fsdax
#   sudo ndctl create-namespace --region 1 --mode fsdax
#
#   4-Socket system:
#   sudo ndctl create-namespace --region 0 --mode fsdax
#   sudo ndctl create-namespace --region 1 --mode fsdax
#   sudo ndctl create-namespace --region 2 --mode fsdax
#   sudo ndctl create-namespace --region 3 --mode fsdax
#
# Create the file systems, repeat for each namespace:
#
# EXT4 example:
#   sudo mkdir /pmemfs0
#   sudo mkfs.ext4 /dev/pmem0
#   sudo mount -o dax /dev/pmem0 /pmemfs0
#
# XFS example:
#   sudo mkdir /pmemfs0
#   sudo mkfs.xfs /dev/pmem0
#   sudo mount -o dax /dev/pmem0 /pmemfs0
#
# See help output for list of optional arguments for this script

#################################################################################################
# Global Variables 
#################################################################################################

VERSION="1.0.2"					# version string

MLC=($(command -v mlc))                         # default, -m option to specify location of the mlc binary
NDCTL=($(command -v ndctl))                     # default, -n option to specify location of the ndctl binary 
IPMCTL=($(command -v ipmctl))                   # default, -i option to specify the location of the ipmctl binary 
BC=($(command -v bc))				# Path to bc
NUMACTL=($(command -v numactl))			# Path to numactl
LSCPU=($(command -v lscpu))                     # Path to lscpu
AWK=($(command -v awk))                         # Path to awk
GREP=($(command -v grep))			# Path to grep
EGREP=($(command -v egrep))			# Path to egrep
SED=($(command -v sed))				# Path to sed
PMEM_PATH=/pmemfs0                              # default, -p option to override
BUF_SZ=400000                                   # Buffer size used in MLC perthread files
OUTPUT_PATH="./mlc-outputs.`date +"%m%d-%H%M"`" # output directory created by the script
SAMPLE_TIME=15                                  # default, -t argument to MLC
socket=0					# default, -s argument to specify the CPU socket to run MLC
OPT_AVX512=1					# default, -a option to override
OPT_VERBOSITY=0					# default, -v, -vv, -vvv option to increase verbose output
OPT_RAMP_BANDWIDTH=false			# default, -r to override and perform ramp-up bandwidth tests
OPT_LOADED_LATENCY=false			# default, -l to override and perform loaded latency testing
OPT_X=false					# default, -X to override and use all cpu threads on all cores

# Injection delays used for loaded latency (to vary demand bitrate)
DELAYS=(0 50 100 200 300 400 500 700 850 1000 1150 1300 1500 1700 2500 3500 5000 20000 40000 80000)

#################################################################################################
# Helper Functions
#################################################################################################

# Handle Ctrl-C User Input
trap ctrl_c INT
function ctrl_c() {
   echo "INFO: Received CTRL+C - aborting"
   display_test_end_info
   popd &> /dev/null
   exit 1
}

# Display test start information
function display_test_start_info() {
  START_TIME=$(date +%s)
  echo "======================================================================="
  echo "Starting Intel PMem bandwidth and latency measurements using MLC"
  echo "${0##*/} Version ${VERSION}"
  echo "Test Started: $(date --date @${START_TIME})"
  echo "======================================================================="
}

# Display test end information
function display_test_end_info() {
  END_TIME=$(date +%s)
  TEST_DURATION=$((${END_TIME}-${START_TIME}))
  echo "======================================================================="
  echo "Intel PMem bandwidth and latency measurements Complete"
  echo "Test Ended: $(date --date @${END_TIME})"
  echo "Test Duration: ${TEST_DURATION} seconds"
  echo "Test results: $OUTPUT_PATH"
  echo "======================================================================="
}

# Verify the required commands and utilities exist on the system
# We use either the defaults or user specified paths
function verify_cmds() {
   err_state=false
   if [ ! -x "${MLC}" ]; then
     echo "ERROR: mlc command not found! Use -m to specify the path."
     err_state=true
   else 
     echo "Using MLC command: ${MLC}"
     TOKENS=( $($MLC --version 2>&1 | head -n 1) )
     MLC_VER=${TOKENS[5]}
     echo "MLC version: $MLC_VER"
   fi
   if [ ${OPT_AVX512} == 1 ]; then
     echo "Using MLC AVX512: Yes"
   else
     echo "Using MLC AVX512: No"
   fi

   if [ ! -x "${NDCTL}" ]; then
     echo "ERROR: ndctl command not found! Use -n to specify the path."
     err_state=true 
   else 
     echo "Using NDCTL command: ${NDCTL}"
     echo "NDCTL version: $(${NDCTL} -v)"
   fi

   if [ ! -x "${IPMCTL}" ]; then
     echo "ERROR: ipmctl command not found! Use -i to specify the path."
     err_state=true 
   else 
     echo "Using IPMCTL command: ${IPMCTL}"
     TOKENS=( $(${IPMCTL} version 2>&1 ) )
     IPMCTL_VER=${TOKENS[-1]}
     echo "IPMCTL version: ${IPMCTL_VER}"
   fi

   for CMD in awk sed numactl lscpu grep egrep mount wc mountpoint cut bc; do
    CMD_PATH=($(command -v ${CMD}))
    if [ ! -x "${CMD_PATH}" ]; then
      echo "ERROR: ${CMD} command not found! Please install the ${CMD} package."
      err_state=true
    fi
   done

   if ${err_state}; then
     echo "Exiting due to previous error(s)"
     exit 1
   fi
}

function sysinfo() {
   echo "Test results: $OUTPUT_PATH"

   echo "Using pmem file system: $PMEM_PATH"
   if mountpoint -q -- "$PMEM_PATH"; then
      DAX_SUPPORT=$(mount | ${GREP} -w $PMEM_PATH | ${GREP} dax | wc -l)
      if (($DAX_SUPPORT <= 0)); then
         echo "Mounted filesystem doesn't support DAX"
      fi
      TOKENS=( $(mount | ${GREP} -w $PMEM_PATH) )
      FS_TYPE=${TOKENS[4]}
      echo "$PMEM_PATH file system type: $FS_TYPE"
   else
      echo "ERROR: $PMEM_PATH is not a mounted file system."
      echo "Create a dax supporting filesystem on the namespace and mount it to $PMEM_PATH"
   fi

   # Get the OS distribution and version if possible
   if [ -f "/etc/os-release" ]; then
     OS_PRETTY_NAME=$(${GREP} PRETTY_NAME /etc/os-release | cut -f2 -d'"')
     echo "Operating System: ${OS_PRETTY_NAME}"
   fi
}

# Display the help information
function display_usage() {
   echo " "
   echo "Usage: $0 [optional args]"
   echo " "
   echo "Runs bandwidth and latency tests on PMem backed PMEM memory using MLC"
   echo "Run with root privilege (MLC needs it)"
   echo " "
   echo "Optional args:"
   echo "   -a <Specify whether to enable or disable the AVX_512 option>"
   echo "      Values:"
   echo "        0: AVX_512 Option Disabled"
   echo "        1: AVX_512 Option Enabled - Default"
   echo "      By default, the AVX_512 option is enabled. If the non-AVX512"
   echo "      version of MLC is being used, this option shall be set to 0"
   echo " "
   echo "   -i <Path to IPMCTL executable>"
   echo "      Specify the path to the IPMCTL executable"
   echo " "
   echo "   -l "
   echo "      Perform loaded latency bandwidth testing using increasing injected delays" 
   echo " "
   echo "   -m <Path to MLC executable>"
   echo "      Specify the path to the MLC executable"
   echo " "
   echo "   -n <Path to NDCTL executable>"
   echo "      Specify the path to the NDCTL executable"
   echo " "
   echo "   -p <Path to mounted PMEM directory>"
   echo "      By default, The pmem memory is expected to be mounted to $PMEM_PATH"
   echo " "
   echo "   -r"
   echo "      Perform ramp-up bandwidth testing using incremental numbers of CPUs"
   echo "      per test."
   echo " " 
   echo "   -s <Socket>"
   echo "      By default, CPU Socket 0 is used to run mlc"
   echo " " 
   echo "   -v"
   echo "      Print verbose output. Use -v, -vv, and -vvv to increase verbosity."
   echo " "
   echo "   -X"
   echo "      For bandwidth tests, mlc will use all cpu threads on each Hyperthread enabled core."
   echo "      Use this option to use only one thread on the core"
   exit 0
}

# Process command arguments and options
function process_args() {

   # Process the command arguments and options
   while getopts "h?a:i:lm:n:p:rs:vX" opt; do
      case "$opt" in
      h|\?)
         display_usage $0
         ;;
      a) # Enable/Disable AVX512 instructions 
	 OPT_AVX512=$OPTARG
         ;;
      i) # Set the location of the ipmctl binary
         IPMCTL=$OPTARG
         ;;
      l) # Enable/Disable running loaded latency bandwidth tests
         OPT_LOADED_LATENCY=true
         ;;
      m) # Set the location of the mlc binary 
	 MLC=$OPTARG
         ;;
      n) # Set the location of the ndctl binary
         NDCTL=$OPTARG
         ;;
      p) # Set the mounted file system path
	 PMEM_PATH=$OPTARG
	 ;;
      r) # Enable/Disable running rampu-up bandwidth tests 
	 OPT_RAMP_BANDWIDTH=true
         ;;
      s) # Specify which CPU socket to execute MLC on
	 socket=$OPTARG
         ;;
      v) # Each -v should increase OPT_VERBOSITY level
         OPT_VERBOSITY=$(($OPT_VERBOSITY+1))
         ;;
      X) # Use all CPU threads on all cores
         OPT_X=true
         ;;
      *) # Invalid argument
	 display_usage $0
	 exit 1
	 ;;
      esac
   done

   # Verify the script is executed with root privileges
   if [[ $EUID -ne 0 ]]; then
      echo "Please run this script with root privilege or use -h to display help information."
      exit 1
   fi

   # Sanity check verbosity levels
   if [ ${OPT_VERBOSITY} -gt 3 ]; then
     OPT_VERBOSITY=3
   fi

   # Socket sanity check
   verify_cpu_socket
}

# Review the system configuration
function validate_config() {
   err_state=false # Used for error reporting

   # Save detailed DIMM information
   ${IPMCTL} show -a -dimm > "${OUTPUT_PATH}/dimm_info.dat"
   if [ $? -ne 0 ]; then
     echo "ERROR: validate_config: 'ipmctl show -a -dimm' returned error $?. Cannot generate dimm information. Exiting."
     exit 1
   fi

   # Create an array of DimmID and DeviceLocator information for error reporting 
   DIMM_ID_LOCATOR=($(${EGREP} -w "DimmID|DeviceLocator" "${OUTPUT_PATH}/dimm_info.dat" | ${SED} -e "s/[- ]//g" | paste -d "=" - - | ${AWK} -F'[/=]' '{print $2"("$4")"}'))
   if [ -z ${DIMM_ID_LOCATOR} ]; then
     echo "ERROR: validate_config: Could not get a list of PMem Devices. Exiting"
     err_state=true
     exit 1
   fi 

   # Validate all DIMMs are Healthy
   DIMMS_HEALTH=($(${GREP} -w "HeathState" "${OUTPUT_PATH}/dimm_info.dat" | cut -d'=' -f 2 | ${AWK} '{ print $1}'))
   for (( i=0; i<${#DIMMS_HEALTH[@]}; i++ )); do
     if [ "${DIMMS_HEALTH[i]}" != "Healthy" ]; then
       echo "ERROR: PMem DIMM ${DIMM_ID_LOCATOR[i]} is not in a 'Healthy' state. Please repair this DIMM and try again."
       err_state=true
     fi
   done
   if ${err_state}; then
     echo "Exiting due to previous error(s)."
     exit 1
   else
     echo "PMem DIMM Health: Healthy"
   fi

   # Validate all DIMMs are same size
   DIMMS_SIZE=($(${GREP} -w "Capacity" "${OUTPUT_PATH}/dimm_info.dat" | cut -d'=' -f 2 | ${AWK} '{ print $1}'))
   for (( i=0; i<${#DIMMS_SIZE[@]}; i++ )); do
     if [ "${DIMMS_SIZE[0]}" != "${DIMMS_SIZE[$i]}" ]; then
       echo "ERROR: This system has mixed capacity PMem DIMMs. It is not recommended to benchmark this config. Exiting."
       # ENHANCEMENT: We could allow the user to override this using '-f' since it is possible to create an asymentric config across sockets
       exit 1;
     fi
   done
   # Identify the DIMM capacity
   # The available capacity varies depending on the type
   DIMM_SIZE=${DIMMS_SIZE[0]}
   if (( $( ${BC} <<< "${DIMM_SIZE} > 116") )) && (( $( ${BC} <<< "${DIMM_SIZE} < 128") )); then
     DIMM_SIZE=128
     DIMM_TYPE="SDP"
   elif (( $( ${BC} <<< "${DIMM_SIZE} > 245") )) && (( $( ${BC} <<< "${DIMM_SIZE} < 256") )); then
     DIMM_SIZE=256
     DIMM_TYPE="DDP"
   elif (( $( ${BC} <<< "${DIMM_SIZE} > 500") )) && (( $( ${BC} <<< "${DIMM_SIZE} < 512") )); then
     DIMM_SIZE=512
     DIMM_TYPE="QDP"
   else
     echo "ERROR: DIMM capacity ${DIMM_SIZE}GiB is not supported"
     exit 1;
   fi
   echo "PMem DIMM Capacity: ${DIMM_SIZE}GiB"

   # Verify the ARS (Address Range Scrub) has completed. 
   # ARS is commonly started at boot time automatically (see BIOS Option), or manually initiated.
   DIMMS_ARS_STATUS=($(${GREP} -w "ARSStatus" "${OUTPUT_PATH}/dimm_info.dat" | cut -d'=' -f 2 | ${AWK} '{ print $1}'))
   for (( i=0; i<${#DIMMS_ARS_STATUS[@]}; i++ )); do
     if [ ${OPT_VERBOSITY} -ge 3 ]; then 
       echo "DEBUG: validate_config: ARS_Status for ${DIMM_ID_LOCATOR[i]} = ${DIMMS_ARS_STATUS[$i]}"
     fi 
     if [ "${DIMMS_ARS_STATUS[$i]}" != "Completed" ]; then
       echo "WARNING: Address Range Scrub (ARS) has not yet completed for ${DIMM_ID_LOCATOR[i]}. Please wait for ARS to complete before benchmarking."
       err_state=true
     fi
   done
   if ${err_state}; then
     echo "INFO: Run 'ndctl wait-scrub all' and wait for ARS to complete before running benchmark."
     echo "Exiting due to previous error(s)."
     exit 1
   else
     echo "ARS Status: Completed"
   fi


   # Validate all DIMMs have the same power budget
   DIMMS_POWER_BUDGET=($(${GREP} -w "AvgPowerBudget" "${OUTPUT_PATH}/dimm_info.dat" | cut -d'=' -f 2 | ${AWK} '{ print $1}'))
   if [ ! -z "${DIMMS_POWER_BUDGET}" ]; then 
     for i in $(seq 0 $(($NUM_DIMMS-1))); do
       if [ "${DIMMS_POWER_BUDGET[0]}" != "${DIMMS_POWER_BUDGET[$i]}" ]; then
         echo "ERROR: PMem are not in same power budget. Please use same power budget for all PMem. Exiting."
         exit 1;
       fi
     done
     DIMM_POWER_BUDGET=${DIMMS_POWER_BUDGET[0]}
     if (( ${DIMM_POWER_BUDGET} > 9500 )) && (( ${DIMM_POWER_BUDGET} < 11500 )); then
       DIMM_POWER="10W"
     elif (( ${DIMM_POWER_BUDGET} > 11501 )) && (( ${DIMM_POWER_BUDGET} < 14500 )); then
       DIMM_POWER="12W"
     elif (( ${DIMM_POWER_BUDGET} > 14501 )) && (( ${DIMM_POWER_BUDGET} < 17500 )); then
       DIMM_POWER="15W"
     elif (( ${DIMM_POWER_BUDGET} > 17501 )) && (( ${DIMM_POWER_BUDGET} < 21000 )); then
       DIMM_POWER="18W"
     else
       echo "INFO: PMem DIMM power budget of '${DIMM_POWER_BUDGET}' is not supported"
     fi
     echo "PMem DIMM AvgPowerBudget: ${DIMM_POWER_BUDGET}"
   else
     echo "PMem DIMM AvgPowerBudget: Not Available"
   fi
}

function init_outputs() {
   rm -rf $OUTPUT_PATH 2> /dev/null
   mkdir $OUTPUT_PATH

   DELAYS_FILE=$OUTPUT_PATH/delays.txt
   for DELAY in "${DELAYS[@]}"; do 
      echo $DELAY >> $DELAYS_FILE
   done
   DRAM_PERTHREAD=$OUTPUT_PATH/DRAM_perthread.txt
   PMem_PERTHREAD=$OUTPUT_PATH/PMem_perthread.txt
}

function check_cpus() {
   TOKENS=( $(lscpu | ${GREP} "Core(s) per socket:") )
   CORES_PER_SOCKET=${TOKENS[3]}

   # Only using the CPUs on this NUMA node
   CPUS=$CORES_PER_SOCKET

   echo "CPU cores per socket: $CPUS"

   # One CPU used to measure latency, so the rest can be for bandwidth generation
   BW_CPUS=$(($CPUS-1))
}

# Verify the user supplied socket number is valid on this system
function verify_cpu_socket() {
   SOCKETS_IN_SYSTEM=$( lscpu | ${GREP} "Socket(s):" | ${AWK} '{print $2}' )
   if [ -z "${SOCKETS_IN_SYSTEM}" ]; then
     echo "ERROR: verify_cpu_socket: Could not identify the number of sockets in this system. Exiting."
     exit 1
   fi
   if (( $socket >= $SOCKETS_IN_SYSTEM )); then
      echo "ERROR: Socket ${socket} does not exist in this system. Valid sockets are 0-$(( ${SOCKETS_IN_SYSTEM} - 1 )). Exiting."
      exit 1
   fi
}

# Verify if CPU Hyperthreading is enabled or disabled
function verify_hyperthreading() {
   THREADS_PER_CORE=$( lscpu | ${GREP} "Thread(s) per core" | cut -f2 -d ":")
   if [ ${THREADS_PER_CORE} -gt 1 ]; then
     CPU_HYPERTHREADING=true
   else
     CPU_HYPERTHREADING=false
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: verify_hyperthreading: CPU Hyperthreading = ${CPU_HYPERTHREADING}"
   fi
}

# Identify the CPU IDs per socket.
function get_cpu_range_per_socket(){
   CPU_RANGE=$( lscpu | ${GREP} "NUMA node${socket} CPU(s)" | cut -f2 -d ":" )
   if [ -z "${CPU_RANGE}" ]; then
     echo "ERROR: get_cpu_range_per_socket: Could not identify cpu range for socket ${socket}. Exiting"
     exit 1
   fi
   echo "CPUs on Socket $socket: $CPU_RANGE"
}

# Identifies the first CPU ID for the specified socket
function get_first_cpu_in_socket() {
   NUMA_CPUS=$( ${NUMACTL} --hardware | ${GREP} "node ${socket} cpus" | cut -f2 -d ":" )
   if [ -z "${NUMA_CPUS}" ]; then
     echo "ERROR: get_first_cpu_in_socket: Could not identify cpus for numa node ${socket}. Exiting"
     exit 1
   fi
   TOK=( ${NUMA_CPUS} )
   FIRST_CPU_ON_SOCKET=${TOK[0]}
}

# Identify the number of CPU Core(s) per socket
function get_cpu_cores_per_socket() {
   CPU_CORES_PER_SOCKET=$( lscpu | ${GREP} "Core(s) per socket" | cut -f2 -d ":" )
   if [ -z "${CPU_CORES_PER_SOCKET}" ]; then
     echo "ERROR: get_cpu_cores_per_socket: Could not identify cpu cores per socket for socket ${socket}. Exiting"
     exit 1
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: get_cpu_cores_per_socket: Core(s) per socket = ${CPU_CORES_PER_SOCKET}"
   fi
}

# Identify the number of CPU Thread(s) per core
function get_cpu_threads_per_core() {
   CPU_THREADS_PER_CORE=$( lscpu | ${GREP} "Thread(s) per core" | cut -f2 -d ":" )
   if [ -z "${CPU_THREADS_PER_CORE}" ] ; then
     echo "ERROR: get_cpu_threads_per_core: Could not identify cpu threads for per core on socket ${socket}. Exiting"
     exit 1
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: get_cpu_threads_per_core: Thread(s) per core = ${CPU_THREADS_PER_CORE}"
   fi
}

function check_dimms() {
   # Find the number of PMem devices in the namespace for the specificed file system
   NUM_DIMMS=0

   # First try with ndctl as we can follow the namespace to the DIMMs
   DEV_PATH=$(mount | ${GREP} -w $PMEM_PATH | ${AWK} '{print $1;}')
   if [[ $DEV_PATH == /dev/pmem* ]]; then
     DEV=$(echo $DEV_PATH | cut -c10-)
     NUM_DIMMS=$(${NDCTL} list -DR -r $DEV | ${GREP} '"dimm":"' | wc -l)
   else
     echo "ERROR: Don't understand dev path $DEV_PATH. Exiting"
     exit 1
   fi

   if (($NUM_DIMMS <= 0)); then
     # Assuming namespace is on socket 0, so just looking at DIMMS there
     echo "INFO: Using ipmctl to determine the number of PMem devices"
     echo "INFO: ASSUMING NAMESPACE IS ON SOCKET 0!"
     NUM_DIMMS=$(${IPMCTL} show -topology | ${GREP} "Logical Non-Volatile Device" | ${GREP} CPU${socket} | wc -l)
   fi

   # if still 0, ask the caller
   if (($NUM_DIMMS <= 0)); then
     echo "Unable to automatically determine the number of PMem devices in the namespace"
     echo -n "Please enter the number of PMem devices: "
     read NUM_DIMMS
     if (($NUM_DIMMS < 1 )); then
       echo "ERROR: Cannot have < 1 PMem in the namespace, exiting"
       exit 1
     fi
     if (($NUM_DIMMS > 6 )); then
       echo "ERROR: Cannot have > 6 PMem in the namespace, exiting"
       exit 1
     fi
   fi

   echo "PMem device count in namespace for ${PMEM_PATH}: $NUM_DIMMS"

   # Check the PMem firmware version using ipmctl
   echo "Intel PMem Firmware versions:"
   ${IPMCTL} show -firmware -dimm
}

#################################################################################################
# Metric measuring functions
#################################################################################################

function idle_latency() {
   get_first_cpu_in_socket

   echo ""
   echo --- Idle Latency Tests ---
   echo "Using CPU ${FIRST_CPU_ON_SOCKET}"
   echo -n "PMem idle sequential latency: "
   $MLC --idle_latency -c${FIRST_CPU_ON_SOCKET} -J$PMEM_PATH > $OUTPUT_PATH/idle_seq.txt
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_seq.txt

   echo -n "PMem idle random latency: "
   $MLC --idle_latency -c${FIRST_CPU_ON_SOCKET} -l256 -J$PMEM_PATH > $OUTPUT_PATH/idle_rnd.txt
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_rnd.txt
   echo "--- End ---"
}

# Use all available CPUs on the specified socket to run MLC
# Note: Depending on the number of PMem devices, power budget, BIOS settings, and other factors, this may not 
#       yield the maximum bandwidth. Use ramp_bandwidth() to check bandwidth using different CPU counts.
#
# MLC Traffic Type
# ----------------
# Instead of generating 100% reads as in the default case, -W3 will select 3 reads and 1
# write to memory. The following are the possible options for –Wn where n can take the
# following values (reads and writes are as observed on the memory controller):
# W2 =  2 reads and 1 write22
# W3 =  3 reads and 1 write
# W5 =  1 read and 1 write
# W6 =  100% non-temporal write
# W7 =  2 reads and 1 non-temporal write
# W8 =  1 read and 1 non-temporal write
# W9 =  3 reads and 1 non-temporal write
# W10 = 2 reads and 1 non-temporal write (similar to stream triad)
# 	 (same as -W7 but the 2 reads are from 2 different buffers while those 2
# 	 reads are from a single buffer on –W7)
# W11 = 3 reads and 1 write
# 	 (same as –W3 but the 2 reads are from 2 different buffers while those 2
# 	 reads are from a single buffer on –W3)
# W12 = 4 reads and 1 write

function bandwidth() {
   echo ""
   echo "--- Bandwidth Tests ---"
   echo "Using CPUs: ${CPU_RANGE}"
   BW_ARRAY=(
      #CPUs         Traffic type   seq or rand  buffer size   pmem or dram   pmem path     output filename
      "${CPU_RANGE} R              seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_READ.txt"
      "${CPU_RANGE} R              rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_READ.txt"
      "${CPU_RANGE} W6             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_WRITE_NT.txt"
      "${CPU_RANGE} W6             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_WRITE_NT.txt"
      "${CPU_RANGE} W7             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_2READ_1WRITE_NT.txt"
      "${CPU_RANGE} W7             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_2READ_1WRITE_NT.txt"
      "${CPU_RANGE} W5             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_1READ_1WRITE.txt"
      "${CPU_RANGE} W5             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_1READ_1WRITE.txt"
      "${CPU_RANGE} W2             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_2READ_1WRITE.txt"
      "${CPU_RANGE} W2             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_2READ_1WRITE.txt"
   )
   for LN in "${BW_ARRAY[@]}"; do
      TOK=( $LN )
      echo ${TOK[0]} ${TOK[1]} ${TOK[2]} ${TOK[3]} ${TOK[4]} ${TOK[5]} > $PMem_PERTHREAD
      echo -n "max PMem bandwidth for ${TOK[6]} (MiB/sec): "
      if [ ${OPT_AVX512} == 1 ]; then
        if [ ${TOK[1]} == "W7" ]; then
          Z="-Z"
        else
          Z=""
        fi
      fi
      ${MLC} --loaded_latency -d0 -o${PMem_PERTHREAD} -t${SAMPLE_TIME} -T ${Z} > ${OUTPUT_PATH}/${TOK[6]}
      cat ${OUTPUT_PATH}/${TOK[6]} | ${SED} -n -e '/==========================/,$p' | tail -n+2 | ${AWK} '{print $3}'
      sleep 3
   done
   echo "--- End ---"
}

# Using incremental number of CPUs, test bandwidth for each range
function ramp_bandwidth() {

   # Initialize the workload file for MLC to execute
   RAMP_BW_ARRAY=(
       #CPUs         Traffic type   seq or rand  buffer size   pmem or dram   pmem path     output filename
   )

   echo ""
   echo "--- Ramp-up Bandwidth Tests ---"
   
   # Get a list of CPU IDs from numactl for the specified socket/numa node
   NUMA_CPUS=$( ${NUMACTL} --hardware | ${GREP} "node ${socket} cpus" | cut -f2 -d ":" )
   get_cpu_range_per_socket
   get_cpu_cores_per_socket
   get_cpu_threads_per_core

   # Do we need to use one thread per core or all threads per core?
   if ${OPT_X}; then 
     # Use one thread per core
     MAX_CPUS=${CPU_CORES_PER_SOCKET} 
   else 
     # Use all threads per core (default)
     MAX_CPUS=$(( ${CPU_CORES_PER_SOCKET}*${CPU_THREADS_PER_CORE} ))
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: ramp_bandwidth: OPT_X='${OPT_X}'. Using ${MAX_CPUS} cpus for testing."
   fi
   # Start at the lowest CPU number for the socket and work up to the max 
   TOK=( ${NUMA_CPUS} )
   NUMCPUS=${#NUMA_CPUS[@]}
   CPU_INCREMENT=2
   #for (( CPU=0; CPU<${MAX_CPUS}; CPU+=${CPU_INCREMENT} )); do
   for CPU in 0 1 $( seq 3 ${CPU_INCREMENT} ${MAX_CPUS} ); do
     if [ ${CPU} -ge ${CPU_CORES_PER_SOCKET} ]; then
       TEST_CPU_RANGE="${TOK[0]}-${TOK[((${CPU_CORES_PER_SOCKET}-1))]},${TOK[${CPU_CORES_PER_SOCKET}]}-${TOK[${CPU}]}"
     else
       TEST_CPU_RANGE="${TOK[0]}-${TOK[${CPU}]}"
     fi
     if [ ${OPT_VERBOSITY} -ge 3 ]; then
       echo "DEBUG: ramp_bandwidth: CPU=${CPU}, TEST_CPU_RANGE = '${TEST_CPU_RANGE}'"
     fi
     for TT in R W2; do
       for IOT in seq rand; do
         NEW_ARRAY_ENTRY="${TEST_CPU_RANGE} ${TT} ${IOT} ${BUF_SZ} pmem ${PMEM_PATH} bw_${IOT}_${TT}_$((${CPU} + 1))CPU.txt"
         RAMP_BW_ARRAY+=( "${NEW_ARRAY_ENTRY}" )
     	 if [ ${OPT_VERBOSITY} -ge 3 ]; then
          echo "DEBUG: ramp_bandwidth: Adding "${NEW_ARRAY_ENTRY}" to RAMP_BW_ARRAY"
        fi
       done
     done
   done

   for LN in "${RAMP_BW_ARRAY[@]}"; do
      TOK=( $LN )
      if [ ${OPT_VERBOSITY} -ge 3 ]; then
        echo "DEBUG: ramp_bandwidth: ${LN}"
      fi
      echo ${TOK[0]} ${TOK[1]} ${TOK[2]} ${TOK[3]} ${TOK[4]} ${TOK[5]} > $PMem_PERTHREAD
      echo -n "max PMem bandwidth for ${TOK[6]} (MiB/sec): "
      if [ ${OPT_AVX512} == 1 ]; then
        if [ ${TOK[1]} == "W7" ]; then
          Z="-Z"
        else
          Z=""
        fi
      fi
      ${MLC} --loaded_latency -d0 -o${PMem_PERTHREAD} -t${SAMPLE_TIME} -T ${Z} > ${OUTPUT_PATH}/${TOK[6]}
      cat ${OUTPUT_PATH}/${TOK[6]} | ${SED} -n -e '/==========================/,$p' | tail -n+2 | ${AWK} '{print $3}'
      sleep 3 #Cooldown time for MLC
   done
   echo "--- End ---"
}

# Perform loaded latency bandwidth tests using injected delays
# TODO: Produce live output for each result rather than wait for the mlc command to complete, which can take a long time.
function loaded_latency() {
  get_cpu_range_per_socket
  echo ""
  echo "--- Loaded Latency Tests ---"
  echo "0  R seq  $BUF_SZ pmem $PMEM_PATH" >  $PMem_PERTHREAD
  echo "${CPU_RANGE} R seq  $BUF_SZ pmem $PMEM_PATH" >> $PMem_PERTHREAD
  echo "PMem sequential read loaded latency sweep:"
  echo " Delay nS         MBPS"
  $MLC --loaded_latency -g$DELAYS_FILE -o$PMem_PERTHREAD -t$SAMPLE_TIME > $OUTPUT_PATH/out_llat_seq_READ_$RD_SEQ_CPUS.txt
  cat $OUTPUT_PATH/out_llat_seq_READ_$RD_SEQ_CPUS.txt | ${SED} -n -e '/==========================/,$p' | tail -n+2

  echo "0  R rand $BUF_SZ pmem $PMEM_PATH" >  $PMem_PERTHREAD
  echo "${CPU_RANGE} R rand  $BUF_SZ pmem $PMEM_PATH" >> $PMem_PERTHREAD 
  echo "PMem random read loaded latency sweep:"
  echo " Delay nS         MBPS"
  $MLC --loaded_latency -g$DELAYS_FILE -o$PMem_PERTHREAD -t$SAMPLE_TIME -r > $OUTPUT_PATH/out_llat_rnd_READ_$RD_RND_CPUS.txt
  cat $OUTPUT_PATH/out_llat_rnd_READ_$RD_RND_CPUS.txt | ${SED} -n -e '/==========================/,$p' | tail -n+2
  echo "--- End ---"
}


#################################################################################################
# Main
#################################################################################################

# Add the current working directory to $PATH
pushd $PWD &> /dev/null

display_test_start_info

process_args $@
verify_cmds
sysinfo
init_outputs
check_cpus
get_cpu_range_per_socket
verify_hyperthreading
validate_config
check_dimms

# Execute the tests
idle_latency
if ${OPT_RAMP_BANDWIDTH}; then 
  ramp_bandwidth
else
  bandwidth
fi 
if ${OPT_LOADED_LATENCY}; then 
  loaded_latency
fi

display_test_end_info

# Remove the current directory from $PATH 
popd &> /dev/null
exit 0
