#!/bin/bash
#
# Copyright (c) 2025. All rights reserved.
#
# Script: compare_benchmarks_text.sh
# Description: Compare results from multiple benchmark directories and display them in text tables.
# Author: Mstaaravin
# Contributors: Developed with assistance from Gemini
# Version: 1.0.0
#
# =================================================================
# Multi-Benchmark Comparison Tool (Text Output)
# =================================================================
#
# DESCRIPTION:
#   This script provides a tool for comparing results from multiple storage
#   benchmark directories. It extracts data from benchmark result files
#   (JSON and CSV) and generates comparative tables in plain text, showing performance
#   differences between multiple storage devices.
#
#   Features include:
#   - Automatic detection of devices across multiple benchmark directories
#   - Support for complex device names including underscores
#   - Generation of comparative performance tables (bandwidth, IOPS, latency)
#   - Customizable device order and display names
#
# USAGE:
#   ./compare_benchmarks_text.sh [options] DIRECTORY1 DIRECTORY2 [DIRECTORY3 ...]
#
# OPTIONS:
#   -h, --help               Display usage information
#   -o, --output DIR         Set output directory for data files (default: ./comparison_results)
#   -d, --devices DEV1,DEV2  Specify device order (comma separated list)
#   -s, --sort [alpha|param] Sort devices alphabetically or by parameter order
#   -n, --names NAME1,NAME2  Custom display names for devices (comma separated list)
#
# EXAMPLES:
#   # Compare two benchmark result directories:
#   ./compare_benchmarks_text.sh benchmark_results_20250502_153056 benchmark_results_20250502_154553
#
#   # Compare with custom output directory:
#   ./compare_benchmarks_text.sh -o my_comparison benchmark_results_1 benchmark_results_2
#
#   # Compare with custom device order and names:
#   ./compare_benchmarks_text.sh -d "SSD,HDD,USB" -n "SSD Drive,HDD Drive,USB Stick" dir1 dir2 dir3
#
# NOTES:
#   - This tool is complementary to the storage_benchmark.sh script
#   - Each benchmark directory should contain standard benchmark result files
#     (bandwidth_results.csv, iops_results.csv, latency_results.csv)
#   - The script will identify devices by their naming patterns in JSON/CSV files
#


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# Function to show usage
show_usage() {
    echo "Usage: $0 [options] [directories...]"
    echo ""
    echo "Compare benchmark results across multiple directories."
    echo "Each directory should contain benchmark results for different devices."
    echo ""
    echo "Example:"
    echo "  $0 benchmark_results_20250502_144531 benchmark_results_20250502_145855"
    echo ""
    echo "Options:"
    echo "  -h, --help               Display this help message"
    echo "  -o, --output DIR         Set output directory (default: ./comparison_results)"
    echo "  -d, --devices DEV1,DEV2  Specify device order (comma separated list)"
    echo "  -s, --sort [alpha|param] Sort devices alphabetically or by parameter order (default: param)"
    echo "  -n, --names NAME1,NAME2  Custom display names for devices (comma separated list)"
    echo ""
}

# Default output directory and sorting
OUTPUT_DIR="./comparison_results"
SORT_METHOD="param"  # Can be 'alpha' or 'param'
CUSTOM_DEVICES=""
CUSTOM_NAMES=""

# Parse arguments
DIRS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;; 
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;; 
        -d|--devices)
            CUSTOM_DEVICES="$2"
            shift 2
            ;; 
        -n|--names)
            CUSTOM_NAMES="$2"
            shift 2
            ;; 
        -s|--sort)
            if [[ "$2" == "alpha" || "$2" == "param" ]]; then
                SORT_METHOD="$2"
                shift 2
            else
                echo -e "${RED}Error: Sort method must be 'alpha' or 'param'${NC}"
                show_usage
                exit 1
            fi
            ;; 
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}"
            show_usage
            exit 1
            ;; 
        *)
            # Add to directories array
            DIRS+=("$1")
            shift
            ;; 
    esac
done

# Check if we have any directories
if [ ${#DIRS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No benchmark directories provided${NC}"
    show_usage
    exit 1
fi

# Check if gnuplot is installed


# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to collect device names from a directory
collect_devices() {
    local dir="$1"
    local device_list=()
    
    # Look for JSON files with test types
    find "$dir" -name "*.json" | while read -r file; do
        filename=$(basename "$file")
        for test_type in "_seq_read.json" "_seq_write.json" "_rand_read.json" "_rand_write.json" "_iops_test.json" "_latency_test.json"; do
            if [[ "$filename" == *"$test_type" ]]; then
                # Get device name by removing the test type suffix
                device="${filename%$test_type}"
                if ! [[ " ${device_list[*]} " =~ " ${device} " ]]; then
                    device_list+=("$device")
                    echo "$device"
                fi
                break
            fi
        done
    done
    
    # If no devices found from JSON files, try CSV files
    if [ ${#device_list[@]} -eq 0 ] && [ -f "$dir/bandwidth_results.csv" ]; then
        # Extract device names from first column (skip header)
        tail -n +2 "$dir/bandwidth_results.csv" | cut -d',' -f1 | sort -u
    fi
}

# Function to extract the file pattern for a device
get_file_pattern() {
    local dir="$1"
    local device="$2"
    
    # Try to find a JSON file for this device
    for file in "$dir"/*; do
        if [[ -f "$file" && "$file" == *"${device}_"*"*.json" ]]; then
            # Extract the pattern used in filenames
            pattern="${device}"
            echo "$pattern"
            return
        fi
    done
    
    # If not found, just return the device name
    echo "$device"
}

# Function to extract bandwidth data for a device from a directory
extract_bandwidth_data() {
    local dir="$1"
    local device="$2"
    local display_name="$3"
    local data_file="$4"
    local index="$5"  # Device index for ordering in the plot
    
    # Get the file pattern for this device
    pattern=$(get_file_pattern "$dir" "$device")
    
    if [ -f "$dir/bandwidth_results.csv" ]; then
        # Extract data for this device
        grep "^${pattern}," "$dir/bandwidth_results.csv" | \
            awk -v dev="$display_name" -v idx="$index" -F, '{print dev","$2","$3","idx}' >> "$data_file"
    else
        echo -e "${YELLOW}Warning: No bandwidth_results.csv found in $dir${NC}"
    fi
}

# Function to extract IOPS data for a device from a directory
extract_iops_data() {
    local dir="$1"
    local device="$2"
    local display_name="$3"
    local data_file="$4"
    local index="$5"  # Device index for ordering in the plot
    
    # Get the file pattern for this device
    pattern=$(get_file_pattern "$dir" "$device")
    
    if [ -f "$dir/iops_results.csv" ]; then
        grep "^${pattern}," "$dir/iops_results.csv" | \
            awk -v dev="$display_name" -v idx="$index" -F, '{print dev","$3","idx}' >> "$data_file"
    else
        echo -e "${YELLOW}Warning: No iops_results.csv found in $dir${NC}"
    fi
}

# Function to extract latency data for a device from a directory
extract_latency_data() {
    local dir="$1"
    local device="$2"
    local display_name="$3"
    local data_file="$4"
    local index="$5"  # Device index for ordering in the plot
    
    # Get the file pattern for this device
    pattern=$(get_file_pattern "$dir" "$device")
    
    if [ -f "$dir/latency_results.csv" ]; then
        # Extract data for this device
        grep "^${pattern}," "$dir/latency_results.csv" | \
            awk -v dev="$display_name" -v idx="$index" -F, '{print dev","$3","idx}' >> "$data_file"
    else
        echo -e "${YELLOW}Warning: No latency_results.csv found in $dir${NC}"
    fi
}

# Collect all unique devices from all directories
ALL_DEVICES=()
DEVICE_ORDER=()  # To maintain the order of directories as passed

for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Error: Directory $dir does not exist${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Scanning directory: $dir${NC}"
    mapfile -t devices < <(collect_devices "$dir")
    
    # Store the devices in the order they were found for this directory
    for device in "${devices[@]}"; do
        # Skip empty devices
        if [ -z "$device" ]; then
            continue
        fi
        
        # Add to the master list if not already there
        if ! [[ " ${ALL_DEVICES[*]} " =~ " ${device} " ]]; then
            ALL_DEVICES+=("$device")
            echo "  Found device: $device"
        fi
        
        # Add to ordered list with source directory (for parameter-order sorting)
        DEVICE_ORDER+=("$device:$dir")
    done
done

if [ ${#ALL_DEVICES[@]} -eq 0 ]; then
    echo -e "${RED}Error: No devices found in the provided directories${NC}"
    exit 1
fi

echo -e "${GREEN}Found ${#ALL_DEVICES[@]} unique devices across ${#DIRS[@]} directories${NC}"

# Sort devices based on the selected method
SORTED_DEVICES=()

if [ -n "$CUSTOM_DEVICES" ]; then
    # User provided a custom device order
    echo -e "${BLUE}Using custom device order${NC}"
    IFS=',' read -ra SORTED_DEVICES <<< "$CUSTOM_DEVICES"
    
    # Verify all devices exist
    for dev in "${SORTED_DEVICES[@]}"; do
        if ! [[ " ${ALL_DEVICES[*]} " =~ " ${dev} " ]]; then
            echo -e "${YELLOW}Warning: Custom device '$dev' not found in benchmark data${NC}"
        fi
    done
    
    # Add any devices that weren't in the custom list to the end
    for dev in "${ALL_DEVICES[@]}"; do
        if ! [[ " ${SORTED_DEVICES[*]} " =~ " ${dev} " ]]; then
            SORTED_DEVICES+=("$dev")
        fi
    done
    
elif [ "$SORT_METHOD" = "alpha" ]; then
    # Alphabetical sort
    echo -e "${BLUE}Sorting devices alphabetically${NC}"
    SORTED_DEVICES=($(printf '%s\n' "${ALL_DEVICES[@]}" | sort))
else
    # Parameter order (default) - maintain the order devices were discovered in directories
    echo -e "${BLUE}Sorting devices by parameter order${NC}"
    
    # Create a unique ordered list preserving the first occurrence order
    declare -A seen_devices
    for entry in "${DEVICE_ORDER[@]}"; do
        # Extract just the device name
        device=$(echo "$entry" | cut -d':' -f1)
        
        if [[ -z "${seen_devices[$device]}" ]]; then
            SORTED_DEVICES+=("$device")
            seen_devices[$device]=1
        fi
    done
fi

# Prepare display names
DISPLAY_NAMES=()

if [ -n "$CUSTOM_NAMES" ]; then
    # User provided custom display names
    IFS=',' read -ra DISPLAY_NAMES <<< "$CUSTOM_NAMES"
    
    # If we have fewer display names than devices, use device names for the rest
    if [ ${#DISPLAY_NAMES[@]} -lt ${#SORTED_DEVICES[@]} ]; then
        for ((i=${#DISPLAY_NAMES[@]}; i<${#SORTED_DEVICES[@]}; i++)); do
            DISPLAY_NAMES+=("${SORTED_DEVICES[i]}")
        done
    fi
else
    # Use the device names as display names (remove any directory prefixes)
    for device in "${SORTED_DEVICES[@]}"; do
        # Extract just the device name without any directory structure
        simple_name=$(basename "$device")
        DISPLAY_NAMES+=("$simple_name")
    done
fi

# Find the maximum display name length
MAX_DEV_LEN=15 # Default
for name in "${DISPLAY_NAMES[@]}"; do
    if [ ${#name} -gt $MAX_DEV_LEN ]; then
        MAX_DEV_LEN=${#name}
    fi
done
((MAX_DEV_LEN++)) # Add one for space

# Display the final order
echo -e "${BLUE}Device order for plots:${NC}"
for i in "${!SORTED_DEVICES[@]}"; do
    echo "  $((i+1)). ${SORTED_DEVICES[i]} (Display: ${DISPLAY_NAMES[i]})
"
done

# Create data files for each metric
BANDWIDTH_DATA="$OUTPUT_DIR/bandwidth_data.csv"
IOPS_DATA="$OUTPUT_DIR/iops_data.csv"
LATENCY_DATA="$OUTPUT_DIR/latency_data.csv"

# Initialize with headers
echo "Device,Test,Value,Index" > "$BANDWIDTH_DATA"
echo "Device,Value,Index" > "$IOPS_DATA"
echo "Device,Value,Index" > "$LATENCY_DATA"

# Extract data for each device from each directory
# We'll use the sorted device list to ensure consistent order
for index in "${!SORTED_DEVICES[@]}"; do
    device="${SORTED_DEVICES[$index]}"
    display_name="${DISPLAY_NAMES[$index]}"
    device_index=$((index+1))
    
    for dir in "${DIRS[@]}"; do
        # Check if the device exists in this directory
        if [ -f "$dir/bandwidth_results.csv" ] && grep -q "^${device}," "$dir/bandwidth_results.csv" || \
           find "$dir" -name "${device}_*.json" -print -quit | grep -q .; then
            echo -e "${BLUE}Extracting data for $device from $(basename "$dir")${NC}"
            extract_bandwidth_data "$dir" "$device" "$display_name" "$BANDWIDTH_DATA" "$device_index"
            extract_iops_data "$dir" "$device" "$display_name" "$IOPS_DATA" "$device_index"
            extract_latency_data "$dir" "$device" "$display_name" "$LATENCY_DATA" "$device_index"
        fi
    done
done

# Function to generate the content of the text tables
_generate_tables_content() {
    local use_colors=$1

    local green=$GREEN
    local yellow=$YELLOW
    local nc=$NC

    if [ "$use_colors" = "false" ]; then
        green=""
        yellow=""
        nc=""
    fi

    echo -e "\n${green}===== Benchmark Comparison =====${nc}\n"

    local dashes=$(printf "%*s" "$MAX_DEV_LEN" | tr ' ' '-')

    # --- Bandwidth Table ---
    echo -e "${yellow}Bandwidth Comparison (MB/s) - Higher is better${nc}"
    
    # Header
    printf "+-%s-+-----------------+------------------+-------------+--------------+\n" "$dashes"
    printf "| %-${MAX_DEV_LEN}s | Sequential Read | Sequential Write | Random Read | Random Write |\n" "Device"
    printf "+-%s-+-----------------+------------------+-------------+--------------+\n" "$dashes"

    # Body
    for device in "${DISPLAY_NAMES[@]}"; do
        seq_read=$(awk -F, -v dev="$device" '$1==dev && $2=="seq_read" {print $3}' "$BANDWIDTH_DATA" | head -n1)
        seq_write=$(awk -F, -v dev="$device" '$1==dev && $2=="seq_write" {print $3}' "$BANDWIDTH_DATA" | head -n1)
        rand_read=$(awk -F, -v dev="$device" '$1==dev && $2=="rand_read" {print $3}' "$BANDWIDTH_DATA" | head -n1)
        rand_write=$(awk -F, -v dev="$device" '$1==dev && $2=="rand_write" {print $3}' "$BANDWIDTH_DATA" | head -n1)

        printf "| %-${MAX_DEV_LEN}s | %-15.2f | %-16.2f | %-11.2f | %-12.2f |\n" \
            "$device" "${seq_read:-0}" "${seq_write:-0}" "${rand_read:-0}" "${rand_write:-0}"
    done
    printf "+-%s-+-----------------+------------------+-------------+--------------+\n\n" "$dashes"

    # --- IOPS Table ---
    echo -e "${yellow}IOPS Comparison - Higher is better${nc}"
    printf "+-%s-+----------+\n" "$dashes"
    printf "| %-${MAX_DEV_LEN}s | IOPS     |\n" "Device"
    printf "+-%s-+----------+\n" "$dashes"

    # Body
    awk -F, -v width="$MAX_DEV_LEN" 'NR > 1 && !seen[$1]++ {
        printf "| %-" width "s | %-8.0f |\n", $1, $2
    }' "$IOPS_DATA"
    printf "+-%s-+----------+\n\n" "$dashes"

    # --- Latency Table ---
    echo -e "${yellow}Latency Comparison (ms) - Lower is better${nc}"
    printf "+-%s-+-------------+\n" "$dashes"
    printf "| %-${MAX_DEV_LEN}s | Latency (ms)|\n" "Device"
    printf "+-%s-+-------------+\n" "$dashes"

    # Body
    awk -F, -v width="$MAX_DEV_LEN" 'NR > 1 && !seen[$1]++ {
        printf "| %-" width "s | %-11.4f |\n", $1, $2
    }' "$LATENCY_DATA"
    printf "+-%s-+-------------+\n" "$dashes"
}

# Function to generate and display text tables
generate_text_tables() {
    _generate_tables_content true
}

# Function to generate text report file
generate_text_report() {
    local output_file="$OUTPUT_DIR/comparison_report.txt"
    _generate_tables_content false > "$output_file"
    echo -e "\n${GREEN}Text report saved to ${output_file}${NC}"
    echo -e "${GREEN}CSV data files are in ${OUTPUT_DIR}${NC}"
}

# Generate and display the text tables
generate_text_tables

# Generate the text report file
generate_text_report
