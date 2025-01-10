#!/bin/bash

# Exit on any error
set -e

# Default configuration
OUTPUT_DIR="$HOME/flattened"
SEPARATOR="---"
TOKEN_LIMIT=100000
GROUP_BY="directory"  # directory, type, or size
VERBOSE=false

# Default exclude patterns for common non-source directories
DEFAULT_EXCLUDES=("*.git/*" "*.DS_Store" "*node_modules/*" "*.swiftpm/*")

# Help text
show_help() {
    cat << EOF
Flatty - Convert directories into LLM-friendly text files

Usage: flatty [options] [patterns...]

Options:
    -o, --output-dir DIR     Output directory (default: ~/flattened)
    -g, --group-by MODE      Grouping mode:
                            directory  - Group by directory structure (default)
                            type       - Group by file type
                            size       - Evenly split by token count
    -i, --include PATTERN    Include only files matching pattern
    -x, --exclude PATTERN    Exclude files matching pattern
    -t, --tokens LIMIT       Target token limit per file (default: 100000)
    -v, --verbose            Show detailed progress
    -h, --help               Show this help message

Examples:
    flatty                                    # Process current directory
    flatty -i "*.swift" -i "*.h" -i "*.m"    # Only Swift and Obj-C files
    flatty --group-by type                    # Group similar files together
    flatty --group-by size -t 50000          # Even chunks of 50k tokens
EOF
    exit 0
}

# Parse command line arguments
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -g|--group-by)
            GROUP_BY="$2"
            shift 2
            ;;
        -i|--include)
            INCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        -x|--exclude)
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        -t|--tokens)
            TOKEN_LIMIT="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            INCLUDE_PATTERNS+=("$1")
            shift
            ;;
    esac
done

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Define a run-specific timestamp (human-readable, avoiding colons).
RUN_TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')

# Helper function to estimate tokens
estimate_tokens() {
    local content="$1"
    local char_count
    char_count=$(echo "$content" | wc -c)
    echo $((char_count / 4))  # Rough estimate: ~4 chars per token
}

# Helper function to check if file matches patterns
matches_patterns() {
    local file="$1"
    local matched=false
    
    # Check default excludes first
    for pattern in "${DEFAULT_EXCLUDES[@]}"; do
        if [[ "$file" == $pattern ]]; then
            return 1  # Return false if file matches any default exclude
        fi
    done
    
    # If no include patterns, match everything
    if [ ${#INCLUDE_PATTERNS[@]} -eq 0 ]; then
        matched=true
    else
        for pattern in "${INCLUDE_PATTERNS[@]}"; do
            if [[ "$file" == $pattern ]]; then
                matched=true
                break
            fi
        done
    fi
    
    # Check exclude patterns
    if [ "$matched" = true ]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            if [[ "$file" == $pattern ]]; then
                matched=false
                break
            fi
        done
    fi
    
    [ "$matched" = true ]
}

# Helper function to get file type group
get_file_type_group() {
    local file="$1"
    case "$file" in
        *.py|*.pyc) echo "python";;
        *.js|*.jsx|*.ts|*.tsx) echo "javascript";;
        *.go) echo "golang";;
        *.rb) echo "ruby";;
        *.java|*.class) echo "java";;
        *.c|*.h) echo "c";;
        *.cpp|*.hpp|*.cc) echo "cpp";;
        *.swift) echo "swift";;
        *.m|*.mm) echo "objective-c";;
        *.html|*.htm) echo "html";;
        *.css|*.scss|*.sass) echo "css";;
        *.md|*.markdown) echo "docs";;
        *.json|*.yaml|*.yml|*.toml) echo "config";;
        *) echo "other";;
    esac
}

# Function to write file content
write_file_content() {
    local file="$1"
    local output_file="$2"
    
    echo "$SEPARATOR" >> "$output_file"
    echo "$file" >> "$output_file"
    echo "$SEPARATOR" >> "$output_file"
    cat "$file" >> "$output_file"
    echo "" >> "$output_file"
}

# ---------------------------------------
# Helper function to construct chunk filename
# ---------------------------------------
build_chunk_filename() {
    local chunk_number=$1
    shift
    local dirs=("$@")
    
    # If there's only one directory in this chunk, just use that dir’s name
    if [ ${#dirs[@]} -eq 1 ]; then
        local safe_dirname=$(echo "${dirs[0]}" | sed 's|/|-|g' | tr -d ' ')
        echo "${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${chunk_number}-${safe_dirname}.txt"
        return
    fi
    
    # If there are multiple directories, combine the first couple
    # and then indicate if there are more
    local first=$(echo "${dirs[0]}" | sed 's|/|-|g' | tr -d ' ')
    local second=""
    [ ${#dirs[@]} -ge 2 ] && second=$(echo "${dirs[1]}" | sed 's|/|-|g' | tr -d ' ')
    
    if [ ${#dirs[@]} -eq 2 ]; then
        # Exactly two directories
        echo "${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${chunk_number}-${first}+${second}.txt"
    else
        # More than two
        local remain=$(( ${#dirs[@]} - 2 ))
        echo "${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${chunk_number}-${first}+${second}+and${remain}more.txt"
    fi
}

# ---------------------------------------
# Smart directory-based processing
# ---------------------------------------
process_by_directory() {
    local current_file=""
    local current_tokens=0
    local file_counter=0
    local total_files=0
    local processed_files=0
    local created_files=()
    local total_tokens=0
    declare -A dir_tokens
    declare -A dir_files

    print_status "Analyzing repository size..."

    # Gather files, track tokens for each directory
    while IFS= read -r -d $'\n' file; do
        if file "$file" | grep -qE '.*:.*text' && matches_patterns "$file"; then
            ((total_files++))
            local dir
            dir="$(dirname "$file")"
            local tokens
            tokens=$(estimate_tokens "$(cat "$file")")
            total_tokens=$((total_tokens + tokens))
            # Accumulate tokens per directory
            dir_tokens["$dir"]=$(( dir_tokens["$dir"] + tokens ))
            # Remember the file in dir_files
            if [ -z "${dir_files["$dir"]}" ]; then
                dir_files["$dir"]="$file"
            else
                dir_files["$dir"]="${dir_files["$dir"]}"$'\n'"$file"
            fi
        fi
    done < <(find . -type f | sort)

    print_info "Found $total_files files totaling approximately $total_tokens tokens"

    # If entire repo fits in a single file
    if [ "$total_tokens" -le "$TOKEN_LIMIT" ]; then
        print_status "Repository fits within token limit. Creating single consolidated file..."
        current_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}.txt"

        # Write header
        echo "# Project: $(basename "$PWD")" > "$current_file"
        echo "# Generated: $(date)" >> "$current_file"
        echo "# Total Tokens: ~$total_tokens" >> "$current_file"
        echo "---" >> "$current_file"

        # Write all files
        for d in "${!dir_files[@]}"; do
            echo -e "\n## Directory: $d" >> "$current_file"
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                ((processed_files++))
                write_file_content "$f" "$current_file"
            done <<< "${dir_files["$d"]}"
        done

        print_success "Created: $(basename "$current_file")"
        print_info "Location: $current_file"
        return
    fi

    print_status "Repository exceeds token limit. Creating logically grouped files..."

    # 1) Sort directories by tokens used (descending)
    local dir_list=()
    for d in "${!dir_tokens[@]}"; do
        dir_list+=( "$d ${dir_tokens["$d"]}" )
    done
    IFS=$'\n' dir_list=( $(sort -rn -k2 <<< "${dir_list[*]}") )
    unset IFS

    current_tokens=0
    file_counter=1
    local current_dirs=()

    for entry in "${dir_list[@]}"; do
        local d="${entry% *}"
        local d_tokens="${entry##* }"

        # If we can add this entire directory to the current chunk
        if [ $((current_tokens + d_tokens)) -le $TOKEN_LIMIT ]; then
            current_tokens=$((current_tokens + d_tokens))
            current_dirs+=( "$d" )
        else
            # If we already have some directories in our current chunk, finalize that chunk
            if [ ${#current_dirs[@]} -gt 0 ]; then
                current_file=$(build_chunk_filename "$file_counter" "${current_dirs[@]}")
                created_files+=( "$current_file" )
                write_directories_to_file "$current_file" current_dirs current_tokens dir_tokens dir_files
                ((file_counter++))
                current_dirs=()
                current_tokens=0
            fi

            # Now handle a big directory that by itself might exceed the limit
            if [ "$d_tokens" -gt "$TOKEN_LIMIT" ]; then
                # We'll have to chunk the files in that directory individually
                file_counter=$((file_counter + 1))
                chunk_directory_by_file "$d" "$d_tokens" "$file_counter" dir_files
                ((file_counter++))
            else
                # If the directory alone fits in an empty chunk, start a new chunk with this dir
                current_tokens=$d_tokens
                current_dirs=( "$d" )
            fi
        fi
    done

    # If any directories remain unfinalized
    if [ ${#current_dirs[@]} -gt 0 ]; then
        current_file=$(build_chunk_filename "$file_counter" "${current_dirs[@]}")
        created_files+=( "$current_file" )
        write_directories_to_file "$current_file" current_dirs current_tokens dir_tokens dir_files
    fi

    # Print summary
    print_success "Created $file_counter files total"
    for output_file in "${created_files[@]}"; do
        echo "  📄 $(basename "$output_file")"
    done
}

# ---------------------------------------------------------
# Helper function to write multiple directories to one file
# ---------------------------------------------------------
write_directories_to_file() {
    local output_file="$1"
    local -n dirs_ref="$2"
    local tokens_in_chunk="$3"
    local -n dir_tokens_ref="$4"
    local -n dir_files_ref="$5"

    echo "# Project: $(basename "$PWD")" > "$output_file"
    echo "# Generated: $(date)" >> "$output_file"
    
    # Add the full directory structure
    write_full_directory_structure "$output_file" dir_tokens_ref
    
    # Now list the directories in this specific chunk
    echo "# Directories included in this chunk:" >> "$output_file"
    for cdir in "${dirs_ref[@]}"; do
        echo "#   $cdir (~${dir_tokens_ref["$cdir"]} tokens)" >> "$output_file"
    done
    echo "---" >> "$output_file"

    # Continue with the actual content...
    local processed_in_chunk=0
    for cdir in "${dirs_ref[@]}"; do
        echo -e "\n## Directory: $cdir" >> "$output_file"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            ((processed_in_chunk++))
            write_file_content "$f" "$output_file"
        done <<< "${dir_files_ref["$cdir"]}"
    done

    print_info "Created: $(basename "$output_file") (tokens in chunk: $tokens_in_chunk, dirs: ${#dirs_ref[@]}, files: $processed_in_chunk)"
}

# ---------------------------------------------------------
# Helper function for directories bigger than TOKEN_LIMIT
# Splits them by individual file
# ---------------------------------------------------------
chunk_directory_by_file() {
    local dir="$1"
    local dir_tokens="$2"
    local file_counter="$3"
    local -n dir_files_map="$4"

    # We'll chunk the files in that directory
    local dir_chunk_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${file_counter}-$(echo "$dir" | sed 's|/|-|g' | tr -d ' ')-sub.txt"
    local dir_sub_tokens=0
    local created_subfiles=0

    echo "# Project: $(basename "$PWD")" > "$dir_chunk_file"
    echo "# Generated: $(date)" >> "$dir_chunk_file"
    echo "# Directory: $dir (exceeds token limit, splitting files)" >> "$dir_chunk_file"
    echo "---" >> "$dir_chunk_file"

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local f_tokens
        f_tokens=$(estimate_tokens "$(cat "$f")")
        if [ $((dir_sub_tokens + f_tokens)) -gt "$TOKEN_LIMIT" ] && [ $dir_sub_tokens -gt 0 ]; then
            print_info "Exceeded token limit in directory $dir, closing sub-chunk"
            echo "# End of sub-chunk for $dir" >> "$dir_chunk_file"
            ((file_counter++))
            
            # Start new sub-chunk
            dir_chunk_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${file_counter}-$(echo "$dir" | sed 's|/|-|g' | tr -d ' ')-sub.txt"
            echo "# Project: $(basename "$PWD")" > "$dir_chunk_file"
            echo "# Generated: $(date)" >> "$dir_chunk_file"
            echo "# Directory: $dir (continuation)" >> "$dir_chunk_file"
            echo "---" >> "$dir_chunk_file"
            dir_sub_tokens=0
        fi
        write_file_content "$f" "$dir_chunk_file"
        dir_sub_tokens=$((dir_sub_tokens + f_tokens))
        ((created_subfiles++))
    done <<< "${dir_files_map["$dir"]}"

    print_info "Created: $(basename "$dir_chunk_file") (directory: $dir, files: $created_subfiles)"
}

# Function to process files by type
process_by_type() {
    local current_file=""
    local current_tokens=0
    local file_counter=1
    local current_type=""
    
    while IFS= read -r -d $'\n' file; do
        if file "$file" | grep -qE '.*:.*text' && matches_patterns "$file"; then
            type=$(get_file_type_group "$file")
            
            # Start new file if type changes or token limit reached
            if [ "$type" != "$current_type" ] || [ $current_tokens -gt $TOKEN_LIMIT ]; then
                current_type="$type"
                file_counter=$((file_counter + 1))
                current_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-${file_counter}-${type}.txt"
                current_tokens=0
                
                # Write header
                echo "# Project: $(basename "$PWD")" > "$current_file"
                echo "# Type: $type" >> "$current_file"
                echo "# Generated: $(date)" >> "$current_file"
                echo "---" >> "$current_file"
            fi
            
            write_file_content "$file" "$current_file"
            current_tokens=$((current_tokens + $(estimate_tokens "$(cat "$file")")))
            [ "$VERBOSE" = true ] && echo "Processing: $file ($current_tokens tokens)"
        fi
    done < <(find . -type f | sort)
}

# Add these helper functions near the top after the configuration
print_status() {
    echo "🔄 $1"
}

print_success() {
    echo "✅ $1"
}

print_info() {
    echo "ℹ️  $1"
}

# Add a function to calculate total tokens for initial assessment
calculate_total_tokens() {
    local total_tokens=0
    local file_count=0
    
    print_status "Analyzing repository size..."
    
    while IFS= read -r -d $'\n' file; do
        if file "$file" | grep -qE '.*:.*text' && matches_patterns "$file"; then
            ((file_count++))
            total_tokens=$((total_tokens + $(estimate_tokens "$(cat "$file")")))
            if [ "$VERBOSE" = true ]; then
                echo "  Scanning: $file"
            fi
        fi
    done < <(find . -type f | sort)
    
    print_info "Found $file_count files totaling approximately $total_tokens tokens"
    echo "$total_tokens"
}

# Modify the process_by_size function to handle single-file case
process_by_size() {
    local current_file=""
    local current_tokens=0
    local file_counter=1
    local total_tokens
    
    total_tokens=$(calculate_total_tokens)
    
    # For small repos, use a single file
    if [ "$total_tokens" -le "$TOKEN_LIMIT" ]; then
        print_status "Repository fits within token limit. Creating single consolidated file..."
        current_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}.txt"
        
        # Write header
        echo "# Project: $(basename "$PWD")" > "$current_file"
        echo "# Generated: $(date)" >> "$current_file"
        echo "# Total Tokens: ~$total_tokens" >> "$current_file"
        echo "---" >> "$current_file"
        
        local processed_files=0
        while IFS= read -r -d $'\n' file; do
            if file "$file" | grep -qE '.*:.*text' && matches_patterns "$file"; then
                ((processed_files++))
                write_file_content "$file" "$current_file"
                [ "$VERBOSE" = true ] && echo "Processing ($processed_files): $file"
            fi
        done < <(find . -type f | sort)
        
        print_success "Created: $(basename "$current_file")"
        print_info "Location: $current_file"
        return
    fi
    
    # For larger repos, split into multiple files
    print_status "Repository exceeds token limit. Splitting into multiple files..."
    
    while IFS= read -r -d $'\n' file; do
        if file "$file" | grep -qE '.*:.*text' && matches_patterns "$file"; then
            # Start new file if token limit reached
            if [ $current_tokens -gt $TOKEN_LIMIT ]; then
                print_info "Created: $(basename "$current_file") (tokens: $current_tokens)"
                file_counter=$((file_counter + 1))
                current_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${file_counter}.txt"
                current_tokens=0
                
                # Write header
                echo "# Project: $(basename "$PWD")" > "$current_file"
                echo "# Part: $file_counter" >> "$current_file"
                echo "# Generated: $(date)" >> "$current_file"
                echo "---" >> "$current_file"
            fi
            
            # If current_file is still empty (first file in the run), define it here
            if [ -z "$current_file" ]; then
                current_file="${OUTPUT_DIR}/$(basename "$PWD")-${RUN_TIMESTAMP}-part${file_counter}.txt"
                echo "# Project: $(basename "$PWD")" > "$current_file"
                echo "# Part: $file_counter" >> "$current_file"
                echo "# Generated: $(date)" >> "$current_file"
                echo "---" >> "$current_file"
            fi

            write_file_content "$file" "$current_file"
            current_tokens=$((current_tokens + $(estimate_tokens "$(cat "$file")")))
            [ "$VERBOSE" = true ] && echo "Processing: $file ($current_tokens tokens)"
        fi
    done < <(find . -type f | sort)
    
    print_success "Created $file_counter files:"
    for ((i=1; i<=$file_counter; i++)); do
        echo "  📄 $(basename "$PWD")-${RUN_TIMESTAMP}-part${i}.txt"
    done
}

# Add this new helper function
write_full_directory_structure() {
    local output_file="$1"
    local -n dir_tokens_ref="$2"
    
    echo -e "\n# Complete Repository Structure:" >> "$output_file"
    echo "# (showing all directories and their token counts)" >> "$output_file"
    
    # Create a sorted list of all directories
    local all_dirs=()
    for d in "${!dir_tokens_ref[@]}"; do
        all_dirs+=("$d")
    done
    IFS=$'\n' sorted_dirs=($(sort <<< "${all_dirs[*]}"))
    unset IFS
    
    # Write the tree structure
    local prev_depth=0
    local prev_parts=()
    
    for dir in "${sorted_dirs[@]}"; do
        # Skip the root directory
        [ "$dir" = "." ] && continue
        
        # Split the path into parts
        IFS='/' read -ra parts <<< "$dir"
        local depth=$((${#parts[@]} - 1))
        
        # Calculate the proper indentation
        local indent=""
        for ((i=0; i<depth; i++)); do
            indent="$indent  "
        done
        
        # Print the directory with its token count
        echo "# ${indent}${parts[-1]}/ (~${dir_tokens_ref[$dir]} tokens)" >> "$output_file"
    done
    echo -e "#\n# Current Chunk Contains:" >> "$output_file"
}

# Main execution
print_status "Starting Flatty..."
print_info "Output directory: $OUTPUT_DIR"
[ "$VERBOSE" = true ] && print_info "Verbose mode enabled"

case $GROUP_BY in
    "directory")
        print_status "Processing by directory structure..."
        process_by_directory
        ;;
    "type")
        print_status "Processing by file type..."
        process_by_type
        ;;
    "size")
        print_status "Processing by size..."
        process_by_size
        ;;
    *)
        echo "Error: Invalid grouping mode: $GROUP_BY"
        exit 1
        ;;
esac

print_success "Processing complete!"
print_info "Files saved in: $OUTPUT_DIR"