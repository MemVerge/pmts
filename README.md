---
author: Steve Scargall
title: Persistent Memory Test Suite (PMTS)
---

# Persistent Memory Test Suite (PMTS)

The Persistent Memory Test Suite (PMTS) is a collection of scripts to run popular benchmark tools on systems with Persistent Memory. 

## Supported Benchmark Tools

The following benchmarking tools are supported:

- [Intel&reg; MLC (Memory Latency Checker)](https://software.intel.com/en-us/articles/intelr-memory-latency-checker) v3.8 or later

## Prerequisites

The test suite requires the following:

- Intel&reg; Optane&trade; Persistent Memory installed in the system (one or more modules per CPU socket)
- At least one DAX file system (ext4 or XFS) using persistent memory
- [ipmctl](https://github.com/intel/ipmctl) 
- [ndctl](https://github.com/pmem/ndctl)
- numactl
- lscpu
- grep/egrep
- awk
- sed

## Running the Tests

Each benchmark has a dedicated script and readme file referenced by the table below

| Test Suite                         | Script      | README                      |
| ---------------------------------- | ----------- | --------------------------- |
| Intel Memory Latency Checker (MLC) | pmts-mlc.sh | [README-mlc](README-mlc.md) |

