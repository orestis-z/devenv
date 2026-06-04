#!/bin/bash
# Deduplicate HuggingFace cache directories
# Usage: ./dedup_hf_cache.sh <main_dir> <other_dir1> [other_dir2] ...
#
# - Moves unique HF model/dataset folders into main_dir, leaves symlink behind
# - Replaces duplicate folders (verified file-by-file same size) with symlinks
# - Only touches folders matching HF cache patterns (models--, datasets--)
# - Dry-run by default, pass --apply to actually make changes

set -uo pipefail

APPLY=false
DIRS=()

for arg in "$@"; do
    if [ "$arg" == "--apply" ]; then
        APPLY=true
    else
        DIRS+=("$arg")
    fi
done

if [ ${#DIRS[@]} -lt 2 ]; then
    echo "Usage: $0 [--apply] <main_dir> <other_dir1> [other_dir2] ..."
    echo ""
    echo "  --apply    Actually move/delete/symlink (default is dry-run)"
    exit 1
fi

MAIN_DIR="${DIRS[0]}"

if [ ! -d "$MAIN_DIR" ]; then
    echo "ERROR: main dir does not exist: $MAIN_DIR"
    exit 1
fi

is_hf_folder() {
    local name="$1"
    # Match HF cache folder patterns: models--org--name, datasets--org--name
    # Also match old-format: org___name (datasets)
    if [[ "$name" =~ ^models-- ]] || [[ "$name" =~ ^datasets-- ]]; then
        return 0
    fi
    return 1
}

folders_match() {
    local dir_a="$1"
    local dir_b="$2"

    # Step 1: compare file tree - same relative paths and sizes
    local list_a list_b
    list_a=$(cd "$dir_a" && find . -type f -printf '%P %s\n' | sort)
    list_b=$(cd "$dir_b" && find . -type f -printf '%P %s\n' | sort)

    if [ "$list_a" != "$list_b" ]; then
        return 1
    fi

    # Step 2: spot-check file contents at exponential offsets
    # For each file, read 512 bytes at offsets 0, 1K, 10K, 100K, 1M, 10M, 100M, 1G
    # This catches finetuned models with identical sizes but different weights
    local offsets=(0 1024 10240 102400 1048576 10485760 104857600 1073741824)
    local chunk=512

    while IFS=' ' read -r relpath filesize; do
        [ -z "$relpath" ] && continue

        local fa="$dir_a/$relpath"
        local fb="$dir_b/$relpath"

        for off in "${offsets[@]}"; do
            # Skip offsets beyond file size
            if [ "$off" -ge "$filesize" ]; then
                break
            fi

            local bytes_a bytes_b
            bytes_a=$(dd if="$fa" bs=1 skip="$off" count="$chunk" 2>/dev/null | md5sum)
            bytes_b=$(dd if="$fb" bs=1 skip="$off" count="$chunk" 2>/dev/null | md5sum)

            if [ "$bytes_a" != "$bytes_b" ]; then
                return 1
            fi
        done
    done <<< "$list_a"

    return 0
}

blobs_mergeable() {
    local dir_a="$1"
    local dir_b="$2"

    # Both must have a blobs/ directory
    if [ ! -d "$dir_a/blobs" ] || [ ! -d "$dir_b/blobs" ]; then
        return 1
    fi

    # Must have at least some blobs in common
    local common
    common=$(comm -12 <(ls "$dir_a/blobs/" | sort) <(ls "$dir_b/blobs/" | sort) | wc -l)
    if [ "$common" -eq 0 ]; then
        return 1
    fi

    # All shared blobs must have identical sizes
    local b
    for b in $(comm -12 <(ls "$dir_a/blobs/" | sort) <(ls "$dir_b/blobs/" | sort)); do
        local sz_a sz_b
        sz_a=$(stat -c%s "$dir_a/blobs/$b" 2>/dev/null)
        sz_b=$(stat -c%s "$dir_b/blobs/$b" 2>/dev/null)
        if [ "$sz_a" != "$sz_b" ]; then
            return 1
        fi
    done

    # Spot-check shared blobs at exponential offsets
    local offsets=(0 1024 10240 102400 1048576 10485760 104857600 1073741824)
    local chunk=512

    for b in $(comm -12 <(ls "$dir_a/blobs/" | sort) <(ls "$dir_b/blobs/" | sort)); do
        local filesize
        filesize=$(stat -c%s "$dir_a/blobs/$b" 2>/dev/null)

        for off in "${offsets[@]}"; do
            if [ "$off" -ge "$filesize" ]; then
                break
            fi

            local hash_a hash_b
            hash_a=$(dd if="$dir_a/blobs/$b" bs=1 skip="$off" count="$chunk" 2>/dev/null | md5sum)
            hash_b=$(dd if="$dir_b/blobs/$b" bs=1 skip="$off" count="$chunk" 2>/dev/null | md5sum)

            if [ "$hash_a" != "$hash_b" ]; then
                return 1
            fi
        done
    done

    return 0
}

check_writable() {
    local dir="$1"
    local label="$2"  # "source" or "main"
    while IFS= read -r d; do
        if [ ! -w "$d" ]; then
            local owner group
            owner=$(stat -c%U "$d" 2>/dev/null)
            group=$(stat -c%G "$d" 2>/dev/null)
            echo "    SKIP: no write access to $label dir: $d (owned by $owner:$group)"
            return 1
        fi
    done < <(find "$dir" -type d 2>/dev/null)
    return 0
}

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)K"
    else
        echo "${bytes}B"
    fi
}

echo "Main directory: $MAIN_DIR"
echo "Other directories: ${DIRS[@]:1}"
if $APPLY; then
    echo "Mode: APPLY (changes will be made)"
else
    echo "Mode: DRY-RUN (no changes, pass --apply to execute)"
fi
echo ""

total_moved=0
total_deduped=0
total_merged=0
total_skipped=0
total_permission_denied=0
total_bytes_saved=0
total_bytes_permission_denied=0

for other_dir in "${DIRS[@]:1}"; do
    if [ ! -d "$other_dir" ]; then
        echo "WARNING: skipping non-existent directory: $other_dir"
        continue
    fi

    echo "================================================================"
    echo "Processing: $other_dir"
    echo "================================================================"
    echo ""

    for entry in "$other_dir"/*/; do
        [ -d "$entry" ] || continue

        name=$(basename "$entry")

        # Skip symlinks
        if [ -L "${entry%/}" ]; then
            continue
        fi

        # Only process HF cache folders
        if ! is_hf_folder "$name"; then
            continue
        fi

        main_path="$MAIN_DIR/$name"
        other_path="${entry%/}"

        if [ ! -e "$main_path" ]; then
            # Case: exists in other but not main -> move to main, symlink
            sz=$(du -sb "$other_path" 2>/dev/null | cut -f1)
            echo "  MOVE: $name ($(human_size "$sz"))"
            echo "    $other_path -> $main_path"

            if $APPLY; then
                if ! check_writable "$other_path" "source"; then
                    total_permission_denied=$((total_permission_denied + 1))
                    total_bytes_permission_denied=$((total_bytes_permission_denied + sz))
                    continue
                fi
                mv "$other_path" "$main_path"
                ln -s "$main_path" "$other_path"
                echo "    Done."
            fi

            total_moved=$((total_moved + 1))

        elif [ -L "$main_path" ]; then
            # Main is already a symlink, skip
            continue

        elif [ -d "$main_path" ]; then
            # Case: exists in both -> compare
            echo "  CHECK: $name"

            if folders_match "$main_path" "$other_path"; then
                sz=$(du -sb "$other_path" 2>/dev/null | cut -f1)
                echo "    DEDUP: identical ($(human_size "$sz")) - remove from other, symlink"

                if $APPLY; then
                    if ! check_writable "$other_path" "source"; then
                        total_permission_denied=$((total_permission_denied + 1))
                        total_bytes_permission_denied=$((total_bytes_permission_denied + sz))
                        continue
                    fi
                    rm -rf "$other_path"
                    ln -s "$main_path" "$other_path"
                    echo "    Done."
                fi

                total_deduped=$((total_deduped + 1))
                total_bytes_saved=$((total_bytes_saved + sz))
            elif blobs_mergeable "$main_path" "$other_path"; then
                sz=$(du -sb "$other_path" 2>/dev/null | cut -f1)
                echo "    MERGE: compatible blobs ($(human_size "$sz")) - consolidate into main, symlink"

                if $APPLY; then
                    if ! check_writable "$other_path" "source" || ! check_writable "$main_path" "main"; then
                        total_permission_denied=$((total_permission_denied + 1))
                        total_bytes_permission_denied=$((total_bytes_permission_denied + sz))
                        continue
                    fi

                    # Copy unique blobs from other into main
                    for b in "$other_path"/blobs/*; do
                        [ -f "$b" ] || continue
                        bname=$(basename "$b")
                        if [ ! -e "$main_path/blobs/$bname" ]; then
                            cp -a "$b" "$main_path/blobs/$bname"
                        fi
                    done

                    # Copy unique snapshot dirs from other into main
                    if [ -d "$other_path/snapshots" ]; then
                        for snap in "$other_path"/snapshots/*/; do
                            [ -d "$snap" ] || continue
                            snap_name=$(basename "$snap")
                            if [ ! -d "$main_path/snapshots/$snap_name" ]; then
                                cp -a "${snap%/}" "$main_path/snapshots/$snap_name"
                            fi
                        done
                    fi

                    # Copy unique refs from other into main
                    if [ -d "$other_path/refs" ]; then
                        for ref in "$other_path"/refs/*; do
                            [ -f "$ref" ] || continue
                            ref_name=$(basename "$ref")
                            if [ ! -e "$main_path/refs/$ref_name" ]; then
                                cp -a "$ref" "$main_path/refs/$ref_name"
                            fi
                        done
                    fi

                    rm -rf "$other_path"
                    ln -s "$main_path" "$other_path"
                    echo "    Done."
                fi

                total_merged=$((total_merged + 1))
                total_bytes_saved=$((total_bytes_saved + sz))
            else
                echo "    SKIP: contents differ, leaving both"
                total_skipped=$((total_skipped + 1))
            fi
        fi
    done

    echo ""
done

echo "================================================================"
echo "Summary"
echo "================================================================"
echo "  Moved to main (unique):    $total_moved"
echo "  Deduplicated (identical):  $total_deduped"
echo "  Merged (compatible blobs): $total_merged"
echo "  Skipped (contents differ): $total_skipped"
echo "  Permission denied:         $total_permission_denied ($(human_size $total_bytes_permission_denied))"
echo "  Space saved:               $(human_size $total_bytes_saved)"
if ! $APPLY; then
    echo ""
    echo "  This was a dry run. Pass --apply to execute."
fi
