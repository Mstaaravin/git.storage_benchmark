#!/bin/bash
#
# Copyright (c) 2025. All rights reserved.
#
# Name: storage_benchmark.sh
# Version: 2.0.0
# Author: Mstaaravin
# Contributors: Developed with assistance from Claude AI
# Description: Comprehensive storage device benchmark tool for Linux
#              Performs and compares performance tests across multiple devices
#
# Changelog v2.0.0:
#   - Added FIO error validation and JSON verification
#   - Added device name sanitization for security
#   - Added disk space validation before tests
#   - Added cleanup trap for interrupted executions
#   - Added secure temporary file handling
#   - Fixed device ordering in graphs
#   - Added cache clearing between tests
#   - Added CLI parameter overrides
#   - Added test selection capability
#   - Added progress indicators
#   - Added dry-run mode
#   - Added verbose mode
#   - Added extended metrics (percentiles, std dev)
#   - Added system and device information capture
#   - Added JSON and Markdown report formats
#   - Code refactoring for maintainability
#
# =================================================================
# Linux Storage Benchmark Tool
# =================================================================
#
# DESCRIPTION:
#   This script provides a straightforward interface for benchmarking storage devices
#   on Linux systems. It performs standardized tests including sequential read/write,
#   random read/write, IOPS measurements, and latency tests using the FIO tool.
#   Results are saved in CSV format and visualized with comparative graphs.
#
#   Features include:
#   - Benchmarking multiple storage devices in a single run
#   - Measuring sequential and random read/write performance
#   - Testing IOPS (Input/Output Operations Per Second)
#   - Measuring access latency
#   - Generating comparative graphs between devices
#   - Creating detailed reports in txt and CSV formats
#   - Configurable test parameters via global variables
#
#   The script uses fio for benchmark tests and gnuplot for visualization.
#
# DEPENDENCIES:
#   - fio: Main benchmark tool (apt install fio)
#   - jq: JSON processing (apt install jq)
#   - gnuplot: Optional for graph generation (apt install gnuplot)
#
# CONFIGURATION:
#   The following parameters can be adjusted by modifying the global variables:
#   - SEQ_TEST_SIZE: Size for sequential read/write tests
#   - RAND_TEST_SIZE: Size for random read/write tests
#   - SEQ_BLOCK_SIZE: Block size for sequential operations
#   - RAND_BLOCK_SIZE: Block size for random operations
#   - TEST_RUNTIME: Duration of each test in seconds
#   - USE_DIRECT_IO: Whether to use direct I/O (1) or cached I/O (0)
#   - FIO_FSYNC: Whether to use fsync for write tests (1) or not (0)
#   - And more (see Global configuration parameters section)
#
# USAGE:
#   sudo ./storage_benchmark.sh DEVICE_NAME MOUNT_PATH [DEVICE_NAME2 MOUNT_PATH2 ...]
#
# PARAMETERS:
#   DEVICE_NAME    Logical name for the device (e.g., EMMC_32GB, SSD_1TB)
#   MOUNT_PATH     Path to the mount point of the device to test
#
# OPTIONS:
#   Root privileges are recommended for accurate benchmarking (cache clearing)
#
# EXAMPLES:
#   # Benchmark a single eMMC device:
#   sudo ./storage_benchmark.sh EMMC_32GB /home/user/emmc_mount
#
#   # Compare an eMMC device with an HDD:
#   sudo ./storage_benchmark.sh EMMC_32GB /home/user/emmc_mount HDD6TB /archive
#
#   # Compare three different storage devices:
#   sudo ./storage_benchmark.sh EMMC_32GB /mnt/emmc SSD_NVME /mnt/nvme HDD6TB /data
#
#   # Benchmark with fsync enabled for writes:
#   sudo ./storage_benchmark.sh --fsync=1 SSD_NVME /mnt/nvme
#
# ZFS CONSIDERATIONS:
#   For ZFS filesystems, the ARC cache can significantly impact benchmark results.
#   For more realistic hardware testing, consider:
#   - Temporarily setting primarycache=metadata: sudo zfs set primarycache=metadata pool/dataset
#   - Using larger test sizes (4GB+) to exceed cache size
#   - Running longer tests (30+ seconds) to measure sustained performance
#   - Restore original settings after testing: sudo zfs set primarycache=all pool/dataset
#
# OUTPUTS:
#   The script creates a timestamped directory (benchmark_results_YYYYMMDD_HHMMSS)
#   containing:
#   - Individual JSON files with detailed test results
#   - CSV files with summary data
#   - PNG graph files comparing device performance
#   - benchmark_results_YYYYMMDD_HHMMSS/benchmark_report.txt) A comprehensive text report with test parameters and results
#
# NOTE:
#   For accurate results, ensure that the devices are not heavily used during testing.
#   Root privileges are needed for clearing system caches between tests.
#


# Global configuration parameters
# ===============================

# Test sizes
SEQ_TEST_SIZE="8g"       # Size for sequential tests
RAND_TEST_SIZE="8g"      # Size for random tests
LATENCY_TEST_SIZE="256m" # Size for latency test

# Block sizes
SEQ_BLOCK_SIZE="1m"      # Block size for sequential tests
RAND_BLOCK_SIZE="4k"     # Block size for random tests

# I/O configuration
SEQ_IODEPTH="4"          # I/O depth for sequential tests
RAND_IODEPTH="32"        # I/O depth for random tests
IOPS_IODEPTH="64"        # I/O depth for IOPS test
LATENCY_IODEPTH="1"      # I/O depth for latency test
USE_DIRECT_IO="1"        # Use direct I/O (1=yes, 0=no)
FIO_FSYNC="0"            # Use fsync for write tests (1=yes, 0=no)

# Job counts
SEQ_JOBS="1"             # Jobs for sequential tests
RAND_JOBS="4"            # Jobs for random tests
IOPS_JOBS="4"            # Jobs for IOPS test
LATENCY_JOBS="1"         # Jobs for latency test

# Runtime parameters
TEST_RUNTIME="10"        # Runtime in seconds for each test

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# New global variables for CLI options (v2.0.0)
DRY_RUN=0                # Dry-run mode flag
VERBOSE=0                # Verbosity level (0=normal, 1=verbose, 2=very verbose)
SELECTED_TESTS=""        # Comma-separated list of tests to run (empty = all)
DROP_CACHES=1            # Drop caches between tests (1=yes, 0=no)
OUTPUT_JSON=0            # Generate JSON report (0=no, 1=yes)
OUTPUT_MARKDOWN=0        # Generate Markdown report (0=no, 1=yes)
CAPTURE_EXTENDED_METRICS=1  # Capture percentiles and std dev (1=yes, 0=no)
TEMP_FILES=()            # Array to track temporary files for cleanup


# Get script version from the version line
get_version() {
    local version_line=$(grep -m 1 "# Version:" "$0")
    SCRIPT_VERSION=$(echo "$version_line" | awk '{print $3}')

    # Default version if not found
    if [ -z "$SCRIPT_VERSION" ]; then
        SCRIPT_VERSION="unknown"
    fi
}

# Cleanup function for temporary files
cleanup() {
    local exit_code=$?
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        [ "$VERBOSE" -ge 1 ] && echo -e "${BLUE}Cleaning up temporary files...${NC}"
        for temp_file in "${TEMP_FILES[@]}"; do
            if [ -f "$temp_file" ] || [ -d "$temp_file" ]; then
                rm -rf "$temp_file" 2>/dev/null
            fi
        done
    fi
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] DEVICE_NAME MOUNT_PATH [DEVICE_NAME2 MOUNT_PATH2 ...]

Comprehensive storage device benchmark tool for Linux.

OPTIONS:
    -h, --help                  Show this help message
    --dry-run                   Validate configuration without running tests
    -v, --verbose               Increase verbosity (can be used multiple times: -v, -vv)
    --tests=LIST                Run specific tests (comma-separated)
                               Available: seq_read,seq_write,rand_read,rand_write,iops_test,latency_test
                               Example: --tests=seq_read,seq_write
    --test-size=SIZE            Override sequential test size (e.g., 4g, 1g)
    --rand-size=SIZE            Override random test size
    --runtime=SECONDS           Override test runtime (default: 10)
    --direct-io=0|1             Use direct I/O (1) or cached (0)
    --fsync=0|1                 Use fsync for write tests (1) or not (0)
    --drop-caches=0|1           Drop caches between tests (default: 1)
    --no-drop-caches            Don't drop caches between tests
    --output-json               Generate JSON report
    --output-markdown           Generate Markdown report
    --no-extended-metrics       Don't capture percentiles and std dev

PARAMETERS:
    DEVICE_NAME                 Logical name for the device (e.g., EMMC_32GB, SSD_1TB)
    MOUNT_PATH                  Path to the mount point of the device to test

EXAMPLES:
    # Basic benchmark
    sudo $0 EMMC_32GB /mnt/emmc

    # Compare two devices
    sudo $0 EMMC_32GB /mnt/emmc SSD_NVME /mnt/nvme

    # Custom configuration
    sudo $0 --test-size=8g --runtime=30 --tests=seq_read,seq_write SSD /mnt/ssd

    # Dry-run to validate
    sudo $0 --dry-run EMMC_32GB /mnt/emmc

    # Verbose output with JSON report
    sudo $0 -vv --output-json SSD /mnt/ssd

EOF
    exit 0
}

# Sanitize device name (security: prevent command injection)
sanitize_device_name() {
    local name="$1"

    # Check if name contains only allowed characters: alphanumeric, underscore, dash
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Error: Invalid device name '$name'${NC}" >&2
        echo -e "${YELLOW}Device names can only contain: letters, numbers, underscore, and dash${NC}" >&2
        return 1
    fi

    # Check length (max 64 characters)
    if [ ${#name} -gt 64 ]; then
        echo -e "${RED}Error: Device name too long (max 64 characters): '$name'${NC}" >&2
        return 1
    fi

    echo "$name"
    return 0
}

# Validate available disk space
validate_disk_space() {
    local device_path="$1"
    local device_name="$2"

    # Convert test sizes to bytes for comparison
    local seq_bytes=$(numfmt --from=iec "${SEQ_TEST_SIZE}" 2>/dev/null || echo "0")
    local rand_bytes=$(numfmt --from=iec "${RAND_TEST_SIZE}" 2>/dev/null || echo "0")
    local latency_bytes=$(numfmt --from=iec "${LATENCY_TEST_SIZE}" 2>/dev/null || echo "0")

    # Calculate total required space (use largest test size + 20% margin)
    local max_test_size=$seq_bytes
    [ "$rand_bytes" -gt "$max_test_size" ] && max_test_size=$rand_bytes
    local required_bytes=$((max_test_size * 120 / 100))  # 20% margin

    # Get available space
    local available_bytes=$(df --output=avail "$device_path" 2>/dev/null | tail -1)
    available_bytes=$((available_bytes * 1024))  # df shows KB, convert to bytes

    if [ "$available_bytes" -lt "$required_bytes" ]; then
        local required_human=$(numfmt --to=iec-i --suffix=B "$required_bytes")
        local available_human=$(numfmt --to=iec-i --suffix=B "$available_bytes")
        echo -e "${RED}Error: Insufficient space on $device_path${NC}" >&2
        echo -e "${YELLOW}Required: ~$required_human, Available: $available_human${NC}" >&2
        return 1
    fi

    if [ "$VERBOSE" -ge 1 ]; then
        local available_human=$(numfmt --to=iec-i --suffix=B "$available_bytes")
        echo -e "${GREEN}Space validation passed: $available_human available on $device_path${NC}"
    fi

    return 0
}

# Drop system caches (requires root)
drop_caches() {
    if [ "$DROP_CACHES" -eq 1 ] && [ "$RUNNING_AS_ROOT" -eq 1 ]; then
        if [ "$VERBOSE" -ge 1 ]; then
            echo -e "${BLUE}Dropping system caches...${NC}"
        fi
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || \
            echo -e "${YELLOW}Warning: Could not drop caches${NC}"
    fi
}

# Check if a specific test should run
should_run_test() {
    local test_name="$1"

    # If no specific tests selected, run all
    if [ -z "$SELECTED_TESTS" ]; then
        return 0
    fi

    # Check if test is in the selected list
    if echo "$SELECTED_TESTS" | grep -q "\(^\|,\)${test_name}\(,\|$\)"; then
        return 0
    fi

    return 1
}


# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}This script must be run as root for accurate benchmarks!${NC}"
        echo -e "${YELLOW}Running without root privileges will cause some tests to fail.${NC}"
        echo -e "${YELLOW}Please run with: sudo $0 $*${NC}"
        echo ""
        RUNNING_AS_ROOT=0
    else
        RUNNING_AS_ROOT=1
    fi
}

# Check dependencies silently and set availability flags
check_dependencies() {
    # Check fio
    if ! command -v fio &> /dev/null; then
        echo -e "${RED}Error: fio is not installed. Install with: sudo apt install fio${NC}"
        exit 1
    fi

    # Check jq (required for JSON processing)
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is not installed. Install with: sudo apt install jq${NC}"
        exit 1
    fi

    # Check gnuplot (optional)
    if ! command -v gnuplot &> /dev/null; then
        GNUPLOT_AVAILABLE=0
    else
        GNUPLOT_AVAILABLE=1
    fi
}


# Display current benchmark configuration
show_configuration() {
    echo -e "${BLUE}Benchmark Configuration:${NC}"
    echo -e "Sequential tests: ${SEQ_BLOCK_SIZE} blocks, ${SEQ_TEST_SIZE} total, ${SEQ_IODEPTH} IO depth, ${SEQ_JOBS} jobs"
    echo -e "Random tests: ${RAND_BLOCK_SIZE} blocks, ${RAND_TEST_SIZE} total, ${RAND_IODEPTH} IO depth, ${RAND_JOBS} jobs"
    echo -e "IOPS test: ${RAND_BLOCK_SIZE} blocks, ${RAND_TEST_SIZE} total, ${IOPS_IODEPTH} IO depth, ${IOPS_JOBS} jobs"
    echo -e "Latency test: ${RAND_BLOCK_SIZE} blocks, ${LATENCY_TEST_SIZE} total, ${LATENCY_IODEPTH} IO depth, ${LATENCY_JOBS} jobs"
    echo -e "Direct I/O: $([ "$USE_DIRECT_IO" = "1" ] && echo "Enabled" || echo "Disabled")"
    echo -e "Fsync for writes: $([ "$FIO_FSYNC" = "1" ] && echo "Enabled" || echo "Disabled")"
    echo -e "Runtime per test: ${TEST_RUNTIME} seconds"
    echo
    
    # Now show the root warning if running without privileges (after the configuration)
    if [ "$RUNNING_AS_ROOT" -eq 0 ]; then
        echo -e "${RED}This script must be run as root for accurate benchmarks!${NC}"
        echo -e "${YELLOW}Running without root privileges will cause some tests to fail.${NC}"
        echo
    fi
}

# Function to run a benchmark with fio
run_fio_test() {
    local device_path=$1
    local test_name=$2
    local device_name=$3
    local test_file="${device_path}/benchmark_test_${test_name}.tmp"
    local result_file="$RESULTS_DIR/${device_name}_${test_name}.json"

    # Check if this test should run
    if ! should_run_test "$test_name"; then
        [ "$VERBOSE" -ge 1 ] && echo -e "${YELLOW}Skipping test: ${test_name}${NC}"
        return 0
    fi

    echo -e "${BLUE}Running test: ${test_name} on ${device_path}${NC}"

    # Drop caches before test
    drop_caches

    # Create secure temporary job file
    local job_file=$(mktemp /tmp/fio_job_XXXXXX.ini)
    TEMP_FILES+=("$job_file")

    # Create fio job file
    cat > "$job_file" << EOF
[global]
ioengine=libaio
direct=${USE_DIRECT_IO}
time_based=1
runtime=${TEST_RUNTIME}
group_reporting=1

[${test_name}]
name=${test_name}
filename=${test_file}
EOF

    # Add specific parameters based on test type
    case "$test_name" in
        "seq_read")
            echo "rw=read" >> "$job_file"
            echo "bs=${SEQ_BLOCK_SIZE}" >> "$job_file"
            echo "size=${SEQ_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${SEQ_IODEPTH}" >> "$job_file"
            echo "numjobs=${SEQ_JOBS}" >> "$job_file"
            ;;
        "seq_write")
            echo "rw=write" >> "$job_file"
            echo "bs=${SEQ_BLOCK_SIZE}" >> "$job_file"
            echo "size=${SEQ_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${SEQ_IODEPTH}" >> "$job_file"
            echo "numjobs=${SEQ_JOBS}" >> "$job_file"
            ;;
        "rand_read")
            echo "rw=randread" >> "$job_file"
            echo "bs=${RAND_BLOCK_SIZE}" >> "$job_file"
            echo "size=${RAND_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${RAND_IODEPTH}" >> "$job_file"
            echo "numjobs=${RAND_JOBS}" >> "$job_file"
            ;;
        "rand_write")
            echo "rw=randwrite" >> "$job_file"
            echo "bs=${RAND_BLOCK_SIZE}" >> "$job_file"
            echo "size=${RAND_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${RAND_IODEPTH}" >> "$job_file"
            echo "numjobs=${RAND_JOBS}" >> "$job_file"
            ;;
        "iops_test")
            echo "rw=randread" >> "$job_file"
            echo "bs=${RAND_BLOCK_SIZE}" >> "$job_file"
            echo "size=${RAND_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${IOPS_IODEPTH}" >> "$job_file"
            echo "numjobs=${IOPS_JOBS}" >> "$job_file"
            ;;
        "latency_test")
            echo "rw=randread" >> "$job_file"
            echo "bs=${RAND_BLOCK_SIZE}" >> "$job_file"
            echo "size=${LATENCY_TEST_SIZE}" >> "$job_file"
            echo "iodepth=${LATENCY_IODEPTH}" >> "$job_file"
            echo "numjobs=${LATENCY_JOBS}" >> "$job_file"
            ;;
    esac

    # Add fsync for write tests if enabled
    if [ "$FIO_FSYNC" = "1" ]; then
        case "$test_name" in
            "seq_write"|"rand_write")
                echo "fsync=1" >> "$job_file"
                ;;
        esac
    fi

    # Run fio and save results in JSON format with error checking
    if ! fio --output-format=json "$job_file" > "$result_file" 2>&1; then
        echo -e "${RED}Error: FIO test failed for ${test_name} on ${device_name}${NC}" >&2
        return 1
    fi

    # Validate JSON output
    if ! jq empty "$result_file" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON output from FIO for ${test_name}${NC}" >&2
        [ "$VERBOSE" -ge 2 ] && cat "$result_file"
        return 1
    fi

    # Verify we got actual results
    local job_count=$(jq '.jobs | length' "$result_file" 2>/dev/null || echo "0")
    if [ "$job_count" -eq 0 ]; then
        echo -e "${RED}Error: No job results in FIO output for ${test_name}${NC}" >&2
        return 1
    fi

    # Extract the main test value and save it to an easy-to-process CSV file
    case "$test_name" in
        "seq_read"|"rand_read")
            local bw=$(jq '.jobs[0].read.bw / 1024' "$result_file" || echo "0")
            echo "${device_name},${test_name},${bw}" >> "$RESULTS_DIR/bandwidth_results.csv"

            # Extended metrics if enabled
            if [ "$CAPTURE_EXTENDED_METRICS" -eq 1 ]; then
                local bw_min=$(jq '.jobs[0].read.bw_min / 1024' "$result_file" 2>/dev/null || echo "0")
                local bw_max=$(jq '.jobs[0].read.bw_max / 1024' "$result_file" 2>/dev/null || echo "0")
                local bw_dev=$(jq '.jobs[0].read.bw_dev / 1024' "$result_file" 2>/dev/null || echo "0")
                echo "${device_name},${test_name},${bw},${bw_min},${bw_max},${bw_dev}" >> "$RESULTS_DIR/bandwidth_extended.csv"
            fi
            ;;
        "seq_write"|"rand_write")
            local bw=$(jq '.jobs[0].write.bw / 1024' "$result_file" || echo "0")
            echo "${device_name},${test_name},${bw}" >> "$RESULTS_DIR/bandwidth_results.csv"

            # Extended metrics if enabled
            if [ "$CAPTURE_EXTENDED_METRICS" -eq 1 ]; then
                local bw_min=$(jq '.jobs[0].write.bw_min / 1024' "$result_file" 2>/dev/null || echo "0")
                local bw_max=$(jq '.jobs[0].write.bw_max / 1024' "$result_file" 2>/dev/null || echo "0")
                local bw_dev=$(jq '.jobs[0].write.bw_dev / 1024' "$result_file" 2>/dev/null || echo "0")
                echo "${device_name},${test_name},${bw},${bw_min},${bw_max},${bw_dev}" >> "$RESULTS_DIR/bandwidth_extended.csv"
            fi
            ;;
        "iops_test")
            local iops=$(jq '.jobs[0].read.iops' "$result_file" || echo "0")
            echo "${device_name},iops,${iops}" >> "$RESULTS_DIR/iops_results.csv"

            # Extended metrics if enabled
            if [ "$CAPTURE_EXTENDED_METRICS" -eq 1 ]; then
                local iops_min=$(jq '.jobs[0].read.iops_min' "$result_file" 2>/dev/null || echo "0")
                local iops_max=$(jq '.jobs[0].read.iops_max' "$result_file" 2>/dev/null || echo "0")
                local iops_stddev=$(jq '.jobs[0].read.iops_stddev' "$result_file" 2>/dev/null || echo "0")
                echo "${device_name},iops,${iops},${iops_min},${iops_max},${iops_stddev}" >> "$RESULTS_DIR/iops_extended.csv"
            fi
            ;;
        "latency_test")
            local latency=$(jq '.jobs[0].read.lat_ns.mean / 1000000' "$result_file" || echo "0")
            echo "${device_name},latency,${latency}" >> "$RESULTS_DIR/latency_results.csv"

            # Extended metrics if enabled (percentiles)
            if [ "$CAPTURE_EXTENDED_METRICS" -eq 1 ]; then
                local lat_p50=$(jq '.jobs[0].read.clat_ns.percentile."50.000000" / 1000000' "$result_file" 2>/dev/null || echo "0")
                local lat_p95=$(jq '.jobs[0].read.clat_ns.percentile."95.000000" / 1000000' "$result_file" 2>/dev/null || echo "0")
                local lat_p99=$(jq '.jobs[0].read.clat_ns.percentile."99.000000" / 1000000' "$result_file" 2>/dev/null || echo "0")
                local lat_stddev=$(jq '.jobs[0].read.lat_ns.stddev / 1000000' "$result_file" 2>/dev/null || echo "0")
                echo "${device_name},latency,${latency},${lat_p50},${lat_p95},${lat_p99},${lat_stddev}" >> "$RESULTS_DIR/latency_extended.csv"
            fi
            ;;
    esac

    # Clean up test file (job file is cleaned by trap)
    rm -f "$test_file"

    if [ "$VERBOSE" -ge 1 ]; then
        echo -e "${GREEN}✓ Test ${test_name} completed successfully${NC}"
    fi
}


# Run benchmarks for a device
run_benchmarks() {
    local device_path=$1
    local device_name=$2

    echo -e "\n${GREEN}===== Starting benchmarks for ${device_name} (${device_path}) =====${NC}"

    # Create test directory
    mkdir -p "${device_path}/benchmark_test"

    # Define all available tests
    local all_tests=("seq_read" "seq_write" "rand_read" "rand_write" "iops_test" "latency_test")
    local tests_to_run=()

    # Determine which tests to run
    for test in "${all_tests[@]}"; do
        if should_run_test "$test"; then
            tests_to_run+=("$test")
        fi
    done

    local total_tests=${#tests_to_run[@]}
    local current_test=0

    # Run FIO tests with progress indication
    for test in "${tests_to_run[@]}"; do
        ((current_test++))
        if [ "$VERBOSE" -ge 0 ]; then
            echo -e "${BLUE}[${current_test}/${total_tests}] ${device_name}: ${test}${NC}"
        fi
        run_fio_test "$device_path" "$test" "$device_name"
    done

    # Clean up
    rmdir "${device_path}/benchmark_test" 2>/dev/null

    echo -e "${GREEN}Benchmark complete for ${device_name}${NC}"
}


# Create plots with gnuplot - DYNAMIC VERSION WITH SINGLE LINE PLOT COMMAND
generate_plots() {
    if [ $GNUPLOT_AVAILABLE -eq 0 ]; then
        echo -e "${YELLOW}Cannot generate graphs, gnuplot is not installed.${NC}"
        return
    fi

    echo -e "${BLUE}Generating graphs...${NC}"

    # Check if we have valid data
    if [ $(wc -l < "$RESULTS_DIR/bandwidth_results.csv") -le 1 ]; then
        echo -e "${YELLOW}Warning: Not enough bandwidth data for plotting.${NC}"
        return
    fi

    # Get all unique device names in their ORIGINAL order (not sorted alphabetically)
    # This preserves the order specified in the command line
    DEVICES=$(awk -F, 'NR>1 {print $1}' "$RESULTS_DIR/bandwidth_results.csv" | awk '!seen[$0]++')
    NUM_DEVICES=$(echo "$DEVICES" | wc -l)

    # Print detected devices and their order for verification
    echo -e "${BLUE}Detected devices in order:${NC}"
    echo "$DEVICES" | cat -n

    # Create a special format file for bandwidth plotting that preserves device order
    # First pass: collect device order
    device_order_list=$(awk -F, 'NR>1 {print $1}' "$RESULTS_DIR/bandwidth_results.csv" | awk '!seen[$0]++' | tr '\n' '|')

    # Second pass: create plot data with correct order
    awk -F, -v dev_order="$device_order_list" '
        BEGIN {
            # Split device order into array
            split(dev_order, dev_arr, "|");
            for (i in dev_arr) {
                if (dev_arr[i] != "") {
                    device_list[++dev_count] = dev_arr[i];
                }
            }
        }
        NR==1 {next}  # Skip header
        {
            device=$1;
            test=$2;
            value=$3;
            if(test=="seq_read") seq_read[device]=value;
            if(test=="seq_write") seq_write[device]=value;
            if(test=="rand_read") rand_read[device]=value;
            if(test=="rand_write") rand_write[device]=value;
        }
        END {
            # Print header with device names in original order
            printf "TestType";
            for (i=1; i<=dev_count; i++) {
                printf " %s", device_list[i];
            }
            printf "\n";

            # Print values for each test type preserving device order
            printf "seq_read";
            for (i=1; i<=dev_count; i++) {
                dev = device_list[i];
                printf " %s", (dev in seq_read) ? seq_read[dev] : "0";
            }
            printf "\n";

            printf "seq_write";
            for (i=1; i<=dev_count; i++) {
                dev = device_list[i];
                printf " %s", (dev in seq_write) ? seq_write[dev] : "0";
            }
            printf "\n";

            printf "rand_read";
            for (i=1; i<=dev_count; i++) {
                dev = device_list[i];
                printf " %s", (dev in rand_read) ? rand_read[dev] : "0";
            }
            printf "\n";

            printf "rand_write";
            for (i=1; i<=dev_count; i++) {
                dev = device_list[i];
                printf " %s", (dev in rand_write) ? rand_write[dev] : "0";
            }
            printf "\n";
        }
    ' "$RESULTS_DIR/bandwidth_results.csv" > "$RESULTS_DIR/bandwidth_plot_data.txt"

    # First, extract the header row (which contains device names)
    BANDWIDTH_HEADER=$(head -1 "$RESULTS_DIR/bandwidth_plot_data.txt")
    
    # Create the bandwidth plot script with dynamic device plotting
    cat > "$RESULTS_DIR/bandwidth_plot.gnuplot" << EOF
set terminal pngcairo size 900,600 enhanced font 'Arial,12'
set output '$RESULTS_DIR/bandwidth_comparison.png'
set title 'Bandwidth Comparison (MB/s)\n {/*0.8 Higher is better}'
set style fill solid 0.7 border
set boxwidth 0.8
set xtics rotate by -45
set xlabel 'Test Type'
set ylabel 'MB/s'
set grid ytics
set key outside top right

# Create grouped histogram
set style data histograms
set style histogram clustered gap 1

EOF

    # Define colors manually - no array
    COLOR1="#4169E1"  # Royal Blue
    COLOR2="#DC143C"  # Crimson
    COLOR3="#228B22"  # Forest Green
    COLOR4="#FF8C00"  # Dark Orange
    COLOR5="#9932CC"  # Dark Orchid
    COLOR6="#20B2AA"  # Light Sea Green

    # Construir una sola línea de comando plot sin usar continuaciones de línea
    plot_command="plot "
    i=0
    
    # Iterate through devices in the order they appear in the bandwidth_plot_data.txt header
    for dev in $BANDWIDTH_HEADER; do
        if [ "$dev" != "TestType" ]; then
            # Use simple if/else for color selection instead of array
            if [ $i -eq 0 ]; then
                color="$COLOR1"
            elif [ $i -eq 1 ]; then
                color="$COLOR2"
            elif [ $i -eq 2 ]; then
                color="$COLOR3"
            elif [ $i -eq 3 ]; then
                color="$COLOR4"
            elif [ $i -eq 4 ]; then
                color="$COLOR5"
            else
                color="$COLOR6"
            fi

            column_num=$((i+2))  # AWK columns start at 1, and first data column is column 2
            
            if [ $i -eq 0 ]; then
                plot_command+="'$RESULTS_DIR/bandwidth_plot_data.txt' using $column_num:xtic(1) title '$dev' lc rgb '$color'"
            else
                plot_command+=", '$RESULTS_DIR/bandwidth_plot_data.txt' using $column_num title '$dev' lc rgb '$color'"
            fi
            ((i++))
        fi
    done

    # Escribir la línea completa del comando plot en el archivo gnuplot
    echo "$plot_command" >> "$RESULTS_DIR/bandwidth_plot.gnuplot"

    # IOPS Plot - Modified for dynamic devices
    cat > "$RESULTS_DIR/iops_plot.gnuplot" << EOF
set terminal pngcairo size 800,600 enhanced font 'Arial,12'
set output '$RESULTS_DIR/iops_comparison.png'
set title 'IOPS Comparison\n {/*0.8 Higher is better}'
set style fill solid 0.7 border
set boxwidth 0.8
set xtics rotate by -45
set xlabel 'Device'
set ylabel 'IOPS'
set grid ytics
set auto y
set datafile separator ','

# Create a better bar chart
set style data histogram
set style histogram cluster gap 1
plot '$RESULTS_DIR/iops_results.csv' every ::1 using 3:xtic(1) title 'IOPS' linecolor rgb '#4169E1'
EOF

    # Latency Plot - Modified for dynamic devices
    cat > "$RESULTS_DIR/latency_plot.gnuplot" << EOF
set terminal pngcairo size 800,600 enhanced font 'Arial,12'
set output '$RESULTS_DIR/latency_comparison.png'
set title 'Latency Comparison (ms)\n {/*0.8 Lower is better}'
set style fill solid 0.7 border
set boxwidth 0.8
set xtics rotate by -45
set xlabel 'Device'
set ylabel 'Latency (ms)'
set grid ytics
set auto y
set datafile separator ','

# Create a better bar chart
set style data histogram
set style histogram cluster gap 1
plot '$RESULTS_DIR/latency_results.csv' every ::1 using 3:xtic(1) title 'Latency' linecolor rgb '#DC143C'
EOF

    # Run gnuplot with error checking
    if gnuplot "$RESULTS_DIR/bandwidth_plot.gnuplot" 2>"$RESULTS_DIR/gnuplot_error.log"; then
        echo -e "${GREEN}Bandwidth graph generated successfully${NC}"
    else
        echo -e "${RED}Error generating bandwidth graph. See $RESULTS_DIR/gnuplot_error.log${NC}"
    fi

    gnuplot "$RESULTS_DIR/iops_plot.gnuplot" 2>/dev/null
    gnuplot "$RESULTS_DIR/latency_plot.gnuplot" 2>/dev/null

    # Check if graphs were created successfully
    if [ -s "$RESULTS_DIR/bandwidth_comparison.png" ] && \
       [ -s "$RESULTS_DIR/iops_comparison.png" ] && \
       [ -s "$RESULTS_DIR/latency_comparison.png" ]; then
        echo -e "${GREEN}All graphs generated in ${RESULTS_DIR}${NC}"
    else
        echo -e "${YELLOW}Warning: Some graphs could not be generated or are empty.${NC}"
    fi
}




# Generate JSON report
generate_json_report() {
    if [ "$OUTPUT_JSON" -ne 1 ]; then
        return
    fi

    local json_file="$RESULTS_DIR/benchmark_report.json"
    echo -e "${BLUE}Generating JSON report...${NC}"

    cat > "$json_file" << EOF
{
  "benchmark_info": {
    "version": "${SCRIPT_VERSION}",
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)"
  },
  "configuration": {
    "seq_test_size": "${SEQ_TEST_SIZE}",
    "rand_test_size": "${RAND_TEST_SIZE}",
    "latency_test_size": "${LATENCY_TEST_SIZE}",
    "seq_block_size": "${SEQ_BLOCK_SIZE}",
    "rand_block_size": "${RAND_BLOCK_SIZE}",
    "test_runtime": ${TEST_RUNTIME},
    "direct_io": ${USE_DIRECT_IO},
    "drop_caches": ${DROP_CACHES}
  },
  "results": {
    "bandwidth": [
EOF

    # Add bandwidth results
    local first=1
    while IFS=, read -r device test value; do
        [ "$device" = "Device" ] && continue  # Skip header
        [ $first -eq 0 ] && echo "," >> "$json_file"
        echo -n "      {\"device\": \"$device\", \"test\": \"$test\", \"value_mbps\": $value}" >> "$json_file"
        first=0
    done < "$RESULTS_DIR/bandwidth_results.csv"

    cat >> "$json_file" << EOF

    ],
    "iops": [
EOF

    # Add IOPS results
    first=1
    while IFS=, read -r device test value; do
        [ "$device" = "Device" ] && continue
        [ $first -eq 0 ] && echo "," >> "$json_file"
        echo -n "      {\"device\": \"$device\", \"value\": $value}" >> "$json_file"
        first=0
    done < "$RESULTS_DIR/iops_results.csv"

    cat >> "$json_file" << EOF

    ],
    "latency": [
EOF

    # Add latency results
    first=1
    while IFS=, read -r device test value; do
        [ "$device" = "Device" ] && continue
        [ $first -eq 0 ] && echo "," >> "$json_file"
        echo -n "      {\"device\": \"$device\", \"value_ms\": $value}" >> "$json_file"
        first=0
    done < "$RESULTS_DIR/latency_results.csv"

    cat >> "$json_file" << EOF

    ]
  }
}
EOF

    echo -e "${GREEN}JSON report generated: $json_file${NC}"
}

# Generate Markdown report
generate_markdown_report() {
    if [ "$OUTPUT_MARKDOWN" -ne 1 ]; then
        return
    fi

    local md_file="$RESULTS_DIR/benchmark_report.md"
    echo -e "${BLUE}Generating Markdown report...${NC}"

    cat > "$md_file" << EOF
# Storage Benchmark Report

**Generated:** $(date)
**Script Version:** ${SCRIPT_VERSION}
**Hostname:** $(hostname)

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Sequential Test Size | ${SEQ_TEST_SIZE} |
| Random Test Size | ${RAND_TEST_SIZE} |
| Latency Test Size | ${LATENCY_TEST_SIZE} |
| Sequential Block Size | ${SEQ_BLOCK_SIZE} |
| Random Block Size | ${RAND_BLOCK_SIZE} |
| Test Runtime | ${TEST_RUNTIME}s |
| Direct I/O | $([ "$USE_DIRECT_IO" = "1" ] && echo "Enabled" || echo "Disabled") |
| Drop Caches | $([ "$DROP_CACHES" = "1" ] && echo "Yes" || echo "No") |

## Bandwidth Results (MB/s)

| Device | Sequential Read | Sequential Write | Random Read | Random Write |
|--------|----------------|------------------|-------------|--------------|
EOF

    # Collect devices
    local devices=$(awk -F, 'NR>1 {print $1}' "$RESULTS_DIR/bandwidth_results.csv" | sort -u)

    # For each device, gather all bandwidth metrics
    for device in $devices; do
        local seq_read=$(awk -F, -v dev="$device" '$1==dev && $2=="seq_read" {print $3}' "$RESULTS_DIR/bandwidth_results.csv")
        local seq_write=$(awk -F, -v dev="$device" '$1==dev && $2=="seq_write" {print $3}' "$RESULTS_DIR/bandwidth_results.csv")
        local rand_read=$(awk -F, -v dev="$device" '$1==dev && $2=="rand_read" {print $3}' "$RESULTS_DIR/bandwidth_results.csv")
        local rand_write=$(awk -F, -v dev="$device" '$1==dev && $2=="rand_write" {print $3}' "$RESULTS_DIR/bandwidth_results.csv")

        echo "| $device | ${seq_read:-N/A} | ${seq_write:-N/A} | ${rand_read:-N/A} | ${rand_write:-N/A} |" >> "$md_file"
    done

    cat >> "$md_file" << EOF

## IOPS Results

| Device | IOPS |
|--------|------|
EOF

    while IFS=, read -r device test value; do
        [ "$device" = "Device" ] && continue
        echo "| $device | $value |" >> "$md_file"
    done < "$RESULTS_DIR/iops_results.csv"

    cat >> "$md_file" << EOF

## Latency Results (ms)

| Device | Latency |
|--------|---------|
EOF

    while IFS=, read -r device test value; do
        [ "$device" = "Device" ] && continue
        printf "| %s | %.2f |\n" "$device" "$value" >> "$md_file"
    done < "$RESULTS_DIR/latency_results.csv"

    cat >> "$md_file" << EOF

## Graphs

![Bandwidth Comparison](bandwidth_comparison.png)
![IOPS Comparison](iops_comparison.png)
![Latency Comparison](latency_comparison.png)

---
*Generated by Storage Benchmark Script v${SCRIPT_VERSION}*
EOF

    echo -e "${GREEN}Markdown report generated: $md_file${NC}"
}

# Generate final report
generate_report() {
    echo -e "${BLUE}Generating final report...${NC}"
    
    # Get error messages
    local error_messages=("$@")

    # Create report file
    REPORT_FILE="$RESULTS_DIR/benchmark_report.txt"

    {
        echo "==================================================="
        echo "  STORAGE BENCHMARK REPORT"
        echo "  Generated: $(date) (v${SCRIPT_VERSION})"
        echo "==================================================="
        echo ""
        
        # Add device status section
        if [ ${#error_messages[@]} -gt 0 ]; then
            echo "DEVICE STATUS:"
            echo "----------------------------------"
            
            # First, list successfully benchmarked devices
            for ((i=0; i<NUM_ARGS; i+=2)); do
                if [ $((i+1)) -lt $NUM_ARGS ]; then
                    device_name=${ALL_ARGS[i]}
                    device_path=${ALL_ARGS[i+1]}
                    
                    # Check if this device is in the error list
                    device_has_error=0
                    for err_device in "${DEVICES_WITH_ERRORS[@]}"; do
                        if [ "$err_device" = "$device_name" ]; then
                            device_has_error=1
                            break
                        fi
                    done
                    
                    if [ $device_has_error -eq 0 ]; then
                        echo "$device_name ($device_path): Successfully benchmarked"
                    fi
                fi
            done
            
            # Then list devices with errors
            for error_msg in "${error_messages[@]}"; do
                echo "$error_msg"
            done
            echo ""
        fi
        
        echo "TEST PARAMETERS:"
        echo "----------------------------------"
        echo "Direct I/O: $([ "$USE_DIRECT_IO" = "1" ] && echo "Enabled" || echo "Disabled")"
        echo "Fsync for writes: $([ "$FIO_FSYNC" = "1" ] && echo "Enabled" || echo "Disabled")"
        echo ""
        echo "Sequential Read:"
        echo "  - Block Size: ${SEQ_BLOCK_SIZE}"
        echo "  - Test Size: ${SEQ_TEST_SIZE}"
        echo "  - I/O Depth: ${SEQ_IODEPTH}"
        echo "  - Jobs: ${SEQ_JOBS}"
        echo "  Description: Measures continuous read performance with large blocks."
        echo ""
        echo "Sequential Write:"
        echo "  - Block Size: ${SEQ_BLOCK_SIZE}"
        echo "  - Test Size: ${SEQ_TEST_SIZE}"
        echo "  - I/O Depth: ${SEQ_IODEPTH}"
        echo "  - Jobs: ${SEQ_JOBS}"
        echo "  Description: Measures continuous write performance with large blocks."
        echo ""
        echo "Random Read:"
        echo "  - Block Size: ${RAND_BLOCK_SIZE}"
        echo "  - Test Size: ${RAND_TEST_SIZE}"
        echo "  - I/O Depth: ${RAND_IODEPTH}"
        echo "  - Jobs: ${RAND_JOBS}"
        echo "  Description: Measures non-sequential small block read performance."
        echo ""
        echo "Random Write:"
        echo "  - Block Size: ${RAND_BLOCK_SIZE}"
        echo "  - Test Size: ${RAND_TEST_SIZE}"
        echo "  - I/O Depth: ${RAND_IODEPTH}"
        echo "  - Jobs: ${RAND_JOBS}"
        echo "  Description: Measures non-sequential small block write performance."
        echo ""
        echo "IOPS Test:"
        echo "  - Block Size: ${RAND_BLOCK_SIZE}"
        echo "  - Test Size: ${RAND_TEST_SIZE}"
        echo "  - I/O Depth: ${IOPS_IODEPTH}"
        echo "  - Jobs: ${IOPS_JOBS}"
        echo "  Description: Measures maximum input/output operations per second."
        echo ""
        echo "Latency Test:"
        echo "  - Block Size: ${RAND_BLOCK_SIZE}"
        echo "  - Test Size: ${LATENCY_TEST_SIZE}"
        echo "  - I/O Depth: ${LATENCY_IODEPTH}"
        echo "  - Jobs: ${LATENCY_JOBS}"
        echo "  Description: Measures time delay between request and response."
        echo ""
        echo "BANDWIDTH RESULTS (MB/s):"
        echo "----------------------------------"
        echo "Device, Test, MB/s"
        cat "$RESULTS_DIR/bandwidth_results.csv"
        echo ""
        echo "IOPS RESULTS:"
        echo "-----------------"
        echo "Device, Test, IOPS"
        cat "$RESULTS_DIR/iops_results.csv"
        echo ""
        echo "LATENCY RESULTS (ms):"
        echo "-------------------------"
        echo "Device, Test, Latency (ms)"
        cat "$RESULTS_DIR/latency_results.csv"
        echo ""
        
        # Add recommendations if there were errors
        if [ ${#error_messages[@]} -gt 0 ]; then
            echo "RECOMMENDATIONS:"
            echo "---------------------------------------------------"
            echo "* For devices that could not be benchmarked, please verify:"
            echo "  - The device is properly mounted"
            echo "  - The specified path exists"
            echo "  - You have proper permissions to access the path"
            echo "  - The filesystem is properly formatted and accessible"
            echo ""
        fi
        
        echo "TERMINOLOGY:"
        echo "---------------------------------------------------"
        echo "Block Size: Size of data chunks read/written in each operation"
        echo "I/O Depth: Number of I/O requests kept in flight at once"
        echo "Jobs: Number of parallel processes performing I/O"
        echo "IOPS: Input/Output Operations Per Second"
        echo "Latency: Time between request submission and completion"
        echo "Sequential: Operations performed on consecutive blocks"
        echo "Random: Operations performed on scattered locations"
        echo "MB/s: Megabytes per second (1 MB = 1,048,576 bytes)"
        echo "ms: Milliseconds (1/1000th of a second)"
        echo "Direct I/O: Bypasses OS page cache (=1) or uses cache (=0)"
    } > "$REPORT_FILE"

    echo -e "${GREEN}Report generated: ${REPORT_FILE}${NC}"

    # Show summary on screen
    echo -e "\n${BLUE}RESULTS SUMMARY:${NC}"
    echo -e "${YELLOW}Bandwidth (MB/s):${NC}"
    cat "$RESULTS_DIR/bandwidth_results.csv"
    echo -e "\n${YELLOW}IOPS:${NC}"
    cat "$RESULTS_DIR/iops_results.csv"
    echo -e "\n${YELLOW}Latency (ms):${NC}"
    cat "$RESULTS_DIR/latency_results.csv"
}




# Parse command-line arguments
# Returns positional arguments through PARSED_ARGS global array
parse_arguments() {
    PARSED_ARGS=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                # Should not reach here, handled in main
                show_help
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -v|--verbose)
                ((VERBOSE++))
                shift
                ;;
            -vv)
                VERBOSE=2
                shift
                ;;
            --tests=*)
                SELECTED_TESTS="${1#*=}"
                shift
                ;;
            --test-size=*)
                SEQ_TEST_SIZE="${1#*=}"
                shift
                ;;
            --rand-size=*)
                RAND_TEST_SIZE="${1#*=}"
                shift
                ;;
            --runtime=*)
                TEST_RUNTIME="${1#*=}"
                shift
                ;;
            --direct-io=*)
                USE_DIRECT_IO="${1#*=}"
                shift
                ;;
            --fsync=*)
                FIO_FSYNC="${1#*=}"
                shift
                ;;
            --drop-caches=*)
                DROP_CACHES="${1#*=}"
                shift
                ;;
            --no-drop-caches)
                DROP_CACHES=0
                shift
                ;;
            --output-json)
                OUTPUT_JSON=1
                shift
                ;;
            --output-markdown)
                OUTPUT_MARKDOWN=1
                shift
                ;;
            --no-extended-metrics)
                CAPTURE_EXTENDED_METRICS=0
                shift
                ;;
            -*)
                echo -e "${RED}Error: Unknown option $1${NC}" >&2
                echo "Use --help for usage information" >&2
                exit 1
                ;;
            *)
                PARSED_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# Capture system information
capture_system_info() {
    local info_file="$RESULTS_DIR/system_info.txt"

    {
        echo "=== SYSTEM INFORMATION ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 2>/dev/null || echo "Unknown")"
        echo ""
        echo "CPU: $(lscpu | grep "Model name" | cut -d':' -f2 | xargs)"
        echo "CPU Cores: $(nproc)"
        echo "Total RAM: $(free -h --si | awk '/^Mem:/ {print $2}')"
        echo ""
    } > "$info_file"

    [ "$VERBOSE" -ge 1 ] && cat "$info_file"
}

# Capture device information
capture_device_info() {
    local device_path="$1"
    local device_name="$2"
    local info_file="$RESULTS_DIR/${device_name}_device_info.txt"

    {
        echo "=== DEVICE INFORMATION: $device_name ==="
        echo "Mount Path: $device_path"
        echo ""

        # Find the actual device
        local mount_device=$(df "$device_path" | tail -1 | awk '{print $1}')
        echo "Device: $mount_device"

        # Filesystem info
        echo "Filesystem: $(df -T "$device_path" | tail -1 | awk '{print $2}')"
        echo "Total Size: $(df -h "$device_path" | tail -1 | awk '{print $2}')"
        echo "Used: $(df -h "$device_path" | tail -1 | awk '{print $3}')"
        echo "Available: $(df -h "$device_path" | tail -1 | awk '{print $4}')"
        echo "Use%: $(df -h "$device_path" | tail -1 | awk '{print $5}')"

        # Try to get device model (works for physical devices)
        if [[ "$mount_device" =~ ^/dev/(sd|nvme|mmcblk) ]]; then
            local base_dev=$(echo "$mount_device" | sed 's/[0-9]*$//' | sed 's/p$//')
            local dev_name=$(basename "$base_dev")

            if [ -f "/sys/block/$dev_name/device/model" ]; then
                echo "Model: $(cat /sys/block/$dev_name/device/model 2>/dev/null | xargs)"
            fi

            if [ -f "/sys/block/$dev_name/size" ]; then
                local sectors=$(cat /sys/block/$dev_name/size 2>/dev/null)
                local bytes=$((sectors * 512))
                echo "Physical Size: $(numfmt --to=iec-i --suffix=B $bytes 2>/dev/null || echo "Unknown")"
            fi
        fi

        echo ""
    } > "$info_file"

    [ "$VERBOSE" -ge 2 ] && cat "$info_file"
}

# Main function
main() {
    # Get script version
    get_version

    # Check for help flag before anything else
    for arg in "$@"; do
        if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
            show_help
        fi
    done

    echo -e "${GREEN}=== STORAGE BENCHMARK SCRIPT v${SCRIPT_VERSION} ===${NC}"

    # Parse arguments
    parse_arguments "$@"
    set -- "${PARSED_ARGS[@]}"

    # Check if running as root
    check_root "$@"

    # Check correct arguments were provided
    if [ $# -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
        echo -e "${RED}Error: Need name:path pairs for each device${NC}"
        echo -e "Usage: $0 [OPTIONS] name1 path1 name2 path2 [name3 path3 ...]"
        echo -e "Example: $0 EMMC_32GB /mnt/emmc USB_256GB /mnt/usb"
        echo -e "Use --help for more information"
        exit 1
    fi

    # Check dependencies silently
    check_dependencies

    # Display configuration
    show_configuration

    # Create directory for results
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESULTS_DIR="benchmark_results_${TIMESTAMP}"
    mkdir -p "$RESULTS_DIR"

    # Initialize CSV files for results
    echo "Device,Test,Value" > "$RESULTS_DIR/bandwidth_results.csv"
    echo "Device,Test,Value" > "$RESULTS_DIR/iops_results.csv"
    echo "Device,Test,Value" > "$RESULTS_DIR/latency_results.csv"

    # Initialize extended CSV files if metrics are enabled
    if [ "$CAPTURE_EXTENDED_METRICS" -eq 1 ]; then
        echo "Device,Test,Mean,Min,Max,StdDev" > "$RESULTS_DIR/bandwidth_extended.csv"
        echo "Device,Test,Mean,Min,Max,StdDev" > "$RESULTS_DIR/iops_extended.csv"
        echo "Device,Test,Mean,P50,P95,P99,StdDev" > "$RESULTS_DIR/latency_extended.csv"
    fi

    # Capture system information
    capture_system_info

    # Save original arguments
    ALL_ARGS=("$@")
    NUM_ARGS=$#

    # Initialize variables for tracking errors
    DEVICES_WITH_ERRORS=()
    ERROR_MESSAGES=()
    TOTAL_DEVICES=0
    FAILED_DEVICES=0
    VALIDATED_DEVICES=()

    # First pass: validate all devices
    echo -e "\n${BLUE}Validating devices...${NC}"
    for ((i=0; i<NUM_ARGS; i+=2)); do
        if [ $((i+1)) -lt $NUM_ARGS ]; then
            device_name=${ALL_ARGS[i]}
            device_path=${ALL_ARGS[i+1]}
            ((TOTAL_DEVICES++))

            # Sanitize device name
            if ! sanitized_name=$(sanitize_device_name "$device_name"); then
                DEVICES_WITH_ERRORS+=("$device_name")
                ERROR_MESSAGES+=("$device_name ($device_path): ERROR - Invalid device name")
                ((FAILED_DEVICES++))
                continue
            fi

            # Check if path exists
            if [ ! -d "$device_path" ]; then
                echo -e "${RED}Error: Path $device_path does not exist or is not accessible${NC}"
                echo -e "${YELLOW}WARNING: Device $device_name will be excluded from benchmark results${NC}"
                DEVICES_WITH_ERRORS+=("$device_name")
                ERROR_MESSAGES+=("$device_name ($device_path): ERROR - Path does not exist or is not accessible")
                ((FAILED_DEVICES++))
                continue
            fi

            # Check write permissions
            if [ ! -w "$device_path" ]; then
                echo -e "${RED}Error: You don't have write permissions on $device_path${NC}"
                echo -e "${YELLOW}WARNING: Device $device_name will be excluded from benchmark results${NC}"
                DEVICES_WITH_ERRORS+=("$device_name")
                ERROR_MESSAGES+=("$device_name ($device_path): ERROR - No write permissions on path")
                ((FAILED_DEVICES++))
                continue
            fi

            # Validate disk space
            if ! validate_disk_space "$device_path" "$device_name"; then
                echo -e "${YELLOW}WARNING: Device $device_name will be excluded from benchmark results${NC}"
                DEVICES_WITH_ERRORS+=("$device_name")
                ERROR_MESSAGES+=("$device_name ($device_path): ERROR - Insufficient disk space")
                ((FAILED_DEVICES++))
                continue
            fi

            # Capture device information
            capture_device_info "$device_path" "$device_name"

            # Add to validated devices list
            VALIDATED_DEVICES+=("$device_name:$device_path")

            echo -e "${GREEN}✓ Device $device_name validated${NC}"
        fi
    done

    # Check if we have any valid devices
    if [ ${#VALIDATED_DEVICES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No valid devices to benchmark${NC}"
        exit 1
    fi

    # Dry-run mode: exit after validation
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "\n${GREEN}=== DRY-RUN MODE ===${NC}"
        echo -e "${BLUE}Validation complete. Would benchmark ${#VALIDATED_DEVICES[@]} device(s):${NC}"
        for dev_info in "${VALIDATED_DEVICES[@]}"; do
            echo "  - ${dev_info%%:*}"
        done
        echo -e "\n${BLUE}Test configuration:${NC}"
        show_configuration
        echo -e "${GREEN}Dry-run successful. Use without --dry-run to execute benchmarks.${NC}"
        exit 0
    fi

    # Run benchmarks on validated devices
    echo -e "\n${GREEN}Starting benchmark execution...${NC}"
    for dev_info in "${VALIDATED_DEVICES[@]}"; do
        device_name="${dev_info%%:*}"
        device_path="${dev_info#*:}"

        # Run benchmarks
        run_benchmarks "$device_path" "$device_name"
    done

    # Generate plots
    generate_plots

    # Generate reports
    generate_report "${ERROR_MESSAGES[@]}"
    generate_json_report
    generate_markdown_report

    echo -e "\n${GREEN}All benchmarks completed. Results in ${RESULTS_DIR}${NC}"

    # Show generated files
    echo -e "\n${BLUE}Generated files:${NC}"
    echo "  - Text report: $RESULTS_DIR/benchmark_report.txt"
    [ "$OUTPUT_JSON" -eq 1 ] && echo "  - JSON report: $RESULTS_DIR/benchmark_report.json"
    [ "$OUTPUT_MARKDOWN" -eq 1 ] && echo "  - Markdown report: $RESULTS_DIR/benchmark_report.md"
    if [ -f "$RESULTS_DIR/bandwidth_comparison.png" ]; then
        echo "  - Graphs: bandwidth_comparison.png, iops_comparison.png, latency_comparison.png"
    fi

    # Show summary of failed devices
    if [ $FAILED_DEVICES -gt 0 ]; then
        echo -e "\n${YELLOW}Note: $FAILED_DEVICES device(s) could not be benchmarked. Check the final report for details.${NC}"
    fi
}


# Run main function with all arguments
main "$@"
