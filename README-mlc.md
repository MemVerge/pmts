# pmts-mlc

The [Intel&reg; Memory Latency Checker (MLC)](https://software.intel.com/en-us/articles/intelr-memory-latency-checker) is a tool used to measure memory latencies and bandwidth, and how they change with increasing load on the system. It provides several options for more fine-grained investigation where bandwidth and latencies from a specific set of cores to caches, volatile memory (DRAM), and persistent memory (PMem) can be measured.

An important factor in determining application performance is the time required for the application to fetch data from the processor’s cache hierarchy and from the memory subsystem. In a multi-socket system where Non-Uniform Memory Access (NUMA) is enabled, local memory latencies and cross-socket memory latencies will vary significantly. Besides latency, bandwidth also plays a significant role in determining performance. So, measuring these latencies and bandwidth is important to establish a baseline for the system under test, and for performance analysis. 

pmts-mlc uses MLC to perform latency and bandwidth tests to determine performance profiles of persistent memory configured in file system dax (fsdax) mode. pmts-mlc is not intended for used on systems with Intel Optane persistent memory configured in Memory Mode or Device Dax/System-RAM.

## Prerequisites

This script requires the following:

- Intel&reg; Optane&trade; Persistent Memory installed in the system (One or more modules per CPU socket)
- At least one DAX file system (ext4 or XFS) using persistent memory
- [Intel MLC (Memory Latency Checker)](https://software.intel.com/en-us/articles/intelr-memory-latency-checker) v3.8 or later
- [ipmctl](https://github.com/intel/ipmctl) 
- [ndctl](https://github.com/pmem/ndctl)
- numactl
- lscpu
- grep/egrep
- awk
- sed
- bc



## Usage

```
Usage: ./pmts-mlc.sh [optional args]

Runs bandwidth and latency tests on PMem backed PMEM memory using MLC
Run with root privilege (MLC needs it)

Optional args:
   -a <Specify whether to enable or disable the AVX_512 option>
      Values:
        0: AVX_512 Option Disabled
        1: AVX_512 Option Enabled - Default
      By default, the AVX_512 option is enabled. If the non-OPT_AVX512
      version of MLC is being used, this option shall be set to 0

   -i <Path to IPMCTL executable>
      Specify the path to the IPMCTL executable

   -l
      Perform loaded latency bandwidth testing using increasing injected delays

   -m <Path to MLC executable>
      Specify the path to the MLC executable

   -n <Path to NDCTL executable>
      Specify the path to the NDCTL executable

   -p <Path to mounted PMEM directory>
      By default, The pmem memory is expected to be mounted to /pmemfs0

   -r
      Perform ramp-up bandwidth testing using incremental numbers of CPUs
      per test.

   -s <Socket>
      By default, Socket 0 is used to run mlc

   -v
      Print verbose output. Use -vv and -vvv to increase OPT_VERBOSITY.

   -X
      For bandwidth tests, mlc will use all cpu threads on each Hyperthread enabled core.
      Use this option to use only one thread on the core
```



## Creating DAX File Systems

Assuming the system has not yet been configured, or is currently configured in Memory Mode, perform the following actions to create the necessary fsdax file systems for testing.

1) Create an interleaved AppDirect configuration goal

```
sudo ipmctl create -goal PersistentMemoryType=AppDirect
```

2) Reboot the system for the changes to take effect

```
sudo systemctl reboot
```

3) Create the namespaces, one per region

```
sudo ndctl create-namespace --continue
```

4) Create the file system(s). This assumes a 2-socket system. Create as many file systems as required.

```
// XFS
sudo mkfs.xfs /dev/pmem0
sudo mkfs.xfs /dev/pmem1

// ext4
sudo mkfs.ext4 /dev/pmem0
sudo mkfs.ext4 /dev/pmem1
```

5) Mount the file systems

```
sudo mkdir /pmemfs0 /pmemfs1
sudo mount -o dax /dev/pmem0 /pmemfs0
sudo mount -o dax /dev/pmem1 /pmemfs1
```



## What the tool measures

When the tool is launched without any arguments, it automatically identifies the system topology and measures the following types of information. 

**Test 1)** Idle memory latencies for requests originating from the specified CPU socket (defaults to socket 0) and the persistent memory file system mount point. Two idle latency tests are run using sequential and random access patterns.

Example output:

```
--- Idle Latency Tests ---
DEBUG: Using CPU 24
PMem idle sequential latency: Each iteration took 414.0 core clocks (172.9 ns)
PMem idle random latency: Each iteration took 752.1 core clocks     (314.1 ns)
--- End ---
```

The idle latency test is always run. 

MLC uses a single thread on the specified socket for the workload and starts another thread on the other core to avoid the CPU dropping into low-power mode due to inactivity.



**Test 2)** Peak memory bandwidth is measured (assuming all accesses are to local memory) for requests with varying read/write access patterns. Both sequential and random access patterns are used for each test. All available CPU cores and threads are used for this test. 

Example output:

```
--- Bandwidth Tests ---
Using CPUs:                24-47,72-95
max PMem bandwidth for bw_seq_READ.txt (MiB/sec): 45804.5
max PMem bandwidth for bw_rnd_READ.txt (MiB/sec): 13550.7
max PMem bandwidth for bw_seq_WRITE_NT.txt (MiB/sec): 7035.3
max PMem bandwidth for bw_rnd_WRITE_NT.txt (MiB/sec): 4007.5
max PMem bandwidth for bw_seq_2READ_1WRITE_NT.txt (MiB/sec): 20096.1
max PMem bandwidth for bw_rnd_2READ_1WRITE_NT.txt (MiB/sec): 7536.7
max PMem bandwidth for bw_seq_1READ_1WRITE.txt (MiB/sec): 8093.8
max PMem bandwidth for bw_rnd_1READ_1WRITE.txt (MiB/sec): 6444.5
max PMem bandwidth for bw_seq_2READ_1WRITE.txt (MiB/sec): 11771.6
max PMem bandwidth for bw_rnd_2READ_1WRITE.txt (MiB/sec): 7669.6
--- End ---
```

The filenames represent the tests executed by MLC, eg:

- Sequential Read (bw_seq_READ.txt)

- Random Read (bw_rnd_READ.txt)

- Sequential Writes using Non-Temporal operations (bw_seq_WRITE_NT.txt)

- Random Writes using Non-Temporal operations (bw_rnd_WRITE_NT.txt)

- Sequential Non-Temporal Read & Write using 2 Read/1 Write (bw_seq_2READ_1WRITE_NT.txt)

- Random Non-Temporal Read & Write using 2 Read/1 Write (bw_rnd_2READ_1WRITE_NT.txt)

- Sequential Read & Write using 1 Read/1 Write (bw_seq_1READ_1WRITE.txt)

- Random Read & Write using 1 Read/1 Write (bw_rnd_1READ_1WRITE.txt)

- Sequential Read & Write using 2 Read/1 Write (bw_seq_2READ_1WRITE.txt)

- Random Read & Write using 2 Read/1 Write (bw_rnd_2READ_1WRITE.txt)

  

## What the tool does not measure

The tool does not automatically produce a matrix output based on local and remote accesses from multiple CPUs to the dax file system nor does it currently support accesses to multiple mounted dax file systems from one or more CPU sockets. 

If you want to measure the latency and bandwidth from a remote CPU (eg: CPU1) to a dax filesystem on socket 0, use the `-s` and `-p` options to specify the socket on which to run mlc and the file system to test, eg:

```
// Run mlc on cpu socket 1 and access data local to CPU0
sudo pmts-mlc -s 1 -p /pmemfs0
```

To produce the data necessary for the matrix, execute the tool using different input arguments to gather local and remote data. See 'Examples' section.



## Capturing pmts-mlc output

By default, the information displayed to STDOUT is not saved. To save this output, use:

```
sudo ./pmts-mlc [options] | tee pmts-mlc.out
```



## Test Results

pmts-mlc will create a directory in the current working directory with the format of  `mlc-outputs.MMDD-HHMM`, representing the date and time the test was ran. Each test will have a dedicated output file, eg:

```
# ls ./mlc-outputs.0319-1614
bw_rand_R_10CPU.txt  bw_rand_R_24CPU.txt   bw_rand_W2_16CPU.txt  bw_rand_W2_6CPU.txt  bw_seq_R_20CPU.txt   bw_seq_W2_12CPU.txt  bw_seq_W2_2CPU.txt  PMem_perthread.txt
bw_rand_R_12CPU.txt  bw_rand_R_2CPU.txt    bw_rand_W2_18CPU.txt  bw_rand_W2_8CPU.txt  bw_seq_R_22CPU.txt   bw_seq_W2_14CPU.txt  bw_seq_W2_4CPU.txt
bw_rand_R_14CPU.txt  bw_rand_R_4CPU.txt    bw_rand_W2_1CPU.txt   bw_seq_R_10CPU.txt   bw_seq_R_24CPU.txt   bw_seq_W2_16CPU.txt  bw_seq_W2_6CPU.txt
bw_rand_R_16CPU.txt  bw_rand_R_6CPU.txt    bw_rand_W2_20CPU.txt  bw_seq_R_12CPU.txt   bw_seq_R_2CPU.txt    bw_seq_W2_18CPU.txt  bw_seq_W2_8CPU.txt
bw_rand_R_18CPU.txt  bw_rand_R_8CPU.txt    bw_rand_W2_22CPU.txt  bw_seq_R_14CPU.txt   bw_seq_R_4CPU.txt    bw_seq_W2_1CPU.txt   delays.txt
bw_rand_R_1CPU.txt   bw_rand_W2_10CPU.txt  bw_rand_W2_24CPU.txt  bw_seq_R_16CPU.txt   bw_seq_R_6CPU.txt    bw_seq_W2_20CPU.txt  dimm_info.dat
bw_rand_R_20CPU.txt  bw_rand_W2_12CPU.txt  bw_rand_W2_2CPU.txt   bw_seq_R_18CPU.txt   bw_seq_R_8CPU.txt    bw_seq_W2_22CPU.txt  idle_rnd.txt
bw_rand_R_22CPU.txt  bw_rand_W2_14CPU.txt  bw_rand_W2_4CPU.txt   bw_seq_R_1CPU.txt    bw_seq_W2_10CPU.txt  bw_seq_W2_24CPU.txt  idle_seq.txt
```



## Examples

#### Example 1 - Show the usage instructions

To display the usage instructions and help, use any of the following:

```
sudo pmts-mlc -?
sudo pmts-mlc -h
```



#### Example 2 - Idle Latency and bandwidth (Local)

The default operation is to expect the dax file system to be created from persistent memory on socket 0. MLC will be executed using CPUs available from socket0.

```
sudo ./pmts-mlc
```



#### Example 3 - Idle latency and bandwidth (Local - Alternative socket)

To run the tests using a socket other than socket 0 with the socket-local persistent memory, use the `-s` and `-p` options. For example, to use CPU socket1 to run MLC tests with PMem from socket1 mounted to /pmemfs1, run:

```
sudo ./pmts-mlc -s1 -p /pmemfs1
```

To confirm which CPUs are being used, see the information displayed in the output, eg:

```
CPUs on Socket 1: 24-47,72-95
```

You can use `htop` to display CPU utilization to confirm MLC is using the correct CPU sockets, cores, and threads.



#### Example 4 - Idle latency and Mixed Bandwidth (Remote CPU)

On Non-Uniform Memory Architecture (NUMA) servers with multiple CPU sockets, it is often useful to understand the impact of remote (or cross) NUMA operations. For example, where Socket0 is accessing data local to Socket1. 

To perform remote access tests, use `-s` and  `-p`. 

```
// Data on socket0 mounted to /pmemfs0. MLC uses socket1 for workload generation
sudo ./pmts-mlc -s1 -p /pmemfs0

// Data on socket1 mounted to /pmemfs1. MLC uses socket0 for workload generation
sudo ./pmts-mlc -s0 -p /pmemfs1
```



#### Example 5 - Idle latency and Ramp-Up Bandwidth (All CPU cores/threads)

On systems with high core count CPUs that do not have a fully populated DDR/PMem configuration, the default bandwidth test may show lower than expected results due to over saturating the PMem device(s). In these situations, it may be necessary to determine how many CPU cores (running at 100%) are required to achieve maximum bandwidth for the given configuration. This is what the ramp-up bandwidth test is designed to do. It will start testing using 1 CPU core (or hyperthread if `-X` is used) and it will increment the number of CPUs used to generate workloads until all CPU cores are used. The `-r` option is used to generate ramp-up metrics.  

```
sudo ./pmts_mlc.sh -r
```

The default for this operation is to use both hyperthreads on a core, assuming hyperthreading is enabled. See `-X` to use only the first thread on each hyperthread core which may provide better results in certain configurations. See 'Example 6'.

Unlike the default bandwidth tests described in 'What the tool measures', the ramp-up bandwidth test only uses the following tests:

- Sequential Read
- Random Read
- Sequential Read & Write using 2 Read/1 Write
- Random Read & Write using 2 Read/1 Write

Each test is executed using increasing number of CPU cores/threads.

Example output:

```
--- Ramp-up Bandwidth Tests ---
CPUs on Socket 0:                0-23,48-71
max PMem bandwidth for bw_seq_R_1CPU.txt (MiB/sec): 4077.7
max PMem bandwidth for bw_rand_R_1CPU.txt (MiB/sec): 2778.5
max PMem bandwidth for bw_seq_W2_1CPU.txt (MiB/sec): 5432.9
max PMem bandwidth for bw_rand_W2_1CPU.txt (MiB/sec): 2739.5
max PMem bandwidth for bw_seq_R_2CPU.txt (MiB/sec): 7650.5
max PMem bandwidth for bw_rand_R_2CPU.txt (MiB/sec): 4791.5
max PMem bandwidth for bw_seq_W2_2CPU.txt (MiB/sec): 9381.2
max PMem bandwidth for bw_rand_W2_2CPU.txt (MiB/sec): 4389.8
max PMem bandwidth for bw_seq_R_4CPU.txt (MiB/sec): 14597.7
max PMem bandwidth for bw_rand_R_4CPU.txt (MiB/sec): 8325.6
max PMem bandwidth for bw_seq_W2_4CPU.txt (MiB/sec): 12952.0
[...snip...]
max PMem bandwidth for bw_seq_R_48CPU.txt (MiB/sec): 45636.5
max PMem bandwidth for bw_rand_R_48CPU.txt (MiB/sec): 13586.6
max PMem bandwidth for bw_seq_W2_48CPU.txt (MiB/sec): 11774.4
max PMem bandwidth for bw_rand_W2_48CPU.txt (MiB/sec): 7664.3
--- End ---
```



#### Example 6 - Idle latency and Ramp-Up Bandwidth (One Hyperthread per core)

To determine if Hyperthreading is beneficial, `-X` can be used in conjunction with `-r` (ramp-up bandwidth test) to run the test using the first thread on each core. 

```
sudo ./pmts_mlc.sh -rX
```

Example output showing up to 24 CPUs are used for testing Vs all 48:

```
--- Ramp-up Bandwidth Tests ---
CPUs on Socket 0:                0-23,48-71
max PMem bandwidth for bw_seq_R_1CPU.txt (MiB/sec): 4077.7
max PMem bandwidth for bw_rand_R_1CPU.txt (MiB/sec): 2778.5
max PMem bandwidth for bw_seq_W2_1CPU.txt (MiB/sec): 5432.9
max PMem bandwidth for bw_rand_W2_1CPU.txt (MiB/sec): 2739.5
max PMem bandwidth for bw_seq_R_2CPU.txt (MiB/sec): 7650.5
max PMem bandwidth for bw_rand_R_2CPU.txt (MiB/sec): 4791.5
max PMem bandwidth for bw_seq_W2_2CPU.txt (MiB/sec): 9381.2
max PMem bandwidth for bw_rand_W2_2CPU.txt (MiB/sec): 4389.8
max PMem bandwidth for bw_seq_R_4CPU.txt (MiB/sec): 14597.7
max PMem bandwidth for bw_rand_R_4CPU.txt (MiB/sec): 8325.6
max PMem bandwidth for bw_seq_W2_4CPU.txt (MiB/sec): 12952.0
[...snip...]
max PMem bandwidth for bw_seq_R_24CPU.txt (MiB/sec): 46422.8
max PMem bandwidth for bw_rand_R_24CPU.txt (MiB/sec): 13658.3
max PMem bandwidth for bw_seq_W2_24CPU.txt (MiB/sec): 12322.0
max PMem bandwidth for bw_rand_W2_24CPU.txt (MiB/sec): 7631.8
--- End ---
```



