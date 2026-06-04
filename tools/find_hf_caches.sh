#!/bin/bash
# Find all HF cache directories under a root and list duplicated models/datasets
# Usage: ./find_hf_caches.sh <root_dir>

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <root_dir>"
    exit 1
fi

ROOT="$1"

if [ ! -d "$ROOT" ]; then
    echo "ERROR: directory does not exist: $ROOT"
    exit 1
fi

echo "Scanning $ROOT for HF model/dataset folders..."
echo ""

# Find all models--* and datasets--* directories (real dirs, not symlinks)
# that contain a refs/ or snapshots/ subdir (confirms it's an HF cache entry)
declare -A LOCATIONS  # name -> list of "size|path" entries

while IFS= read -r dir; do
    # Skip symlinks
    [ -L "$dir" ] && continue

    # Confirm it looks like an HF cache entry (has snapshots/ or refs/ or blobs/)
    if [ -d "$dir/snapshots" ] || [ -d "$dir/refs" ] || [ -d "$dir/blobs" ]; then
        name=$(basename "$dir")
        sz=$(du -sb "$dir" 2>/dev/null | cut -f1)
        LOCATIONS["$name"]+="${sz}|${dir}"$'\n'
    fi
done < <(find "$ROOT" -maxdepth 5 -type d \( -name 'models--*' -o -name 'datasets--*' \) 2>/dev/null)

# Separate into duplicates and unique, collect parent dirs
declare -A PARENT_DIRS
declare -a DUP_NAMES
declare -a UNIQUE_NAMES

for name in "${!LOCATIONS[@]}"; do
    count=$(echo -n "${LOCATIONS[$name]}" | grep -c '|')
    if [ "$count" -gt 1 ]; then
        DUP_NAMES+=("$name")
    else
        UNIQUE_NAMES+=("$name")
    fi

    # Track parent dirs
    while IFS='|' read -r sz path; do
        [ -z "$path" ] && continue
        parent=$(dirname "$path")
        PARENT_DIRS["$parent"]=1
    done <<< "${LOCATIONS[$name]}"
done

# Print parent directories found, sorted by total size
echo "HF cache directories found:"
echo "────────────────────────────────────────────────────────────────"
for parent in $(
    for p in "${!PARENT_DIRS[@]}"; do
        sz=$(du -sb "$p" 2>/dev/null | cut -f1)
        echo "$sz $p"
    done | sort -rn | awk '{print $2}'
); do
    sz_h=$(du -sh "$parent" 2>/dev/null | cut -f1)
    count=0
    dup_count=0
    dup_bytes=0
    for name in "${!LOCATIONS[@]}"; do
        in_this_parent=false
        while IFS='|' read -r _ path; do
            [ -z "$path" ] && continue
            if [ "$(dirname "$path")" == "$parent" ]; then
                count=$((count + 1))
                in_this_parent=true
            fi
        done <<< "${LOCATIONS[$name]}"

        # Check if this name is a duplicate AND lives in this parent
        if $in_this_parent; then
            copy_count=$(echo -n "${LOCATIONS[$name]}" | grep -c '|')
            if [ "$copy_count" -gt 1 ]; then
                dup_count=$((dup_count + 1))
                while IFS='|' read -r sz path; do
                    [ -z "$path" ] && continue
                    if [ "$(dirname "$path")" == "$parent" ]; then
                        dup_bytes=$((dup_bytes + sz))
                    fi
                done <<< "${LOCATIONS[$name]}"
            fi
        fi
    done

    if [ "$dup_bytes" -ge 1073741824 ]; then
        dup_h="$(echo "scale=1; $dup_bytes / 1073741824" | bc)G"
    elif [ "$dup_bytes" -ge 1048576 ]; then
        dup_h="$(echo "scale=1; $dup_bytes / 1048576" | bc)M"
    else
        dup_h="${dup_bytes}B"
    fi

    if [ "$dup_count" -gt 0 ]; then
        echo "  $sz_h  ($count entries, $dup_count duplicated totaling $dup_h)  $parent"
    else
        echo "  $sz_h  ($count entries, no duplicates)  $parent"
    fi
done
echo ""

# Print duplicates
if [ ${#DUP_NAMES[@]} -eq 0 ]; then
    echo "No duplicates found."
    exit 0
fi

echo "Duplicated entries (${#DUP_NAMES[@]} names found in multiple locations):"
echo "────────────────────────────────────────────────────────────────"
echo ""

# Sort duplicates by total wasted bytes (sum of all copies except largest)
declare -A DUP_WASTE
for name in "${DUP_NAMES[@]}"; do
    sizes=()
    while IFS='|' read -r sz path; do
        [ -z "$path" ] && continue
        sizes+=("$sz")
    done <<< "${LOCATIONS[$name]}"

    # Sort sizes descending, sum all but the largest
    waste=0
    largest=0
    for s in "${sizes[@]}"; do
        if [ "$s" -gt "$largest" ]; then
            waste=$((waste + largest))
            largest=$s
        else
            waste=$((waste + s))
        fi
    done
    DUP_WASTE["$name"]=$waste
done

# Print sorted by waste descending
for name in $(
    for n in "${DUP_NAMES[@]}"; do
        echo "${DUP_WASTE[$n]} $n"
    done | sort -rn | awk '{print $2}'
); do
    waste=${DUP_WASTE[$name]}
    if [ "$waste" -ge 1073741824 ]; then
        waste_h="$(echo "scale=1; $waste / 1073741824" | bc)G"
    elif [ "$waste" -ge 1048576 ]; then
        waste_h="$(echo "scale=1; $waste / 1048576" | bc)M"
    else
        waste_h="${waste}B"
    fi

    echo "  $name  (${waste_h} reclaimable)"

    while IFS='|' read -r sz path; do
        [ -z "$path" ] && continue
        if [ "$sz" -ge 1073741824 ]; then
            sz_h="$(echo "scale=1; $sz / 1073741824" | bc)G"
        elif [ "$sz" -ge 1048576 ]; then
            sz_h="$(echo "scale=1; $sz / 1048576" | bc)M"
        else
            sz_h="${sz}B"
        fi
        echo "    $sz_h  $path"
    done <<< "${LOCATIONS[$name]}"
    echo ""
done

# Total
total_waste=0
for w in "${DUP_WASTE[@]}"; do
    total_waste=$((total_waste + w))
done
if [ "$total_waste" -ge 1073741824 ]; then
    total_h="$(echo "scale=1; $total_waste / 1073741824" | bc)G"
elif [ "$total_waste" -ge 1048576 ]; then
    total_h="$(echo "scale=1; $total_waste / 1048576" | bc)M"
else
    total_h="${total_waste}B"
fi

echo "────────────────────────────────────────────────────────────────"
echo "Total reclaimable: $total_h"
