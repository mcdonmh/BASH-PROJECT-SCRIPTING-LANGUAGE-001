#!/usr/bin/env bash
# concat.sh - a flexible text-file concatenator, useful for logs and reports
# Requirements: bash, egrep (grep -E), awk, mktemp, find (for -r)
# Usage: ./concat.sh -o out.txt [options] file1 file2 dir1 -  (use '-' for stdin) or more simply ./concat.sh -o <output-file> <input1> <input2> ...

set -o pipefail
shopt -s nullglob

usage() {
  cat <<USAGE
Usage: $0 [OPTIONS] <file|dir|-> [file|dir|-> ...]
Options:
  -h           Show this help and exit
  -o FILE      Output file (required)
  -a           Append to output (default: overwrite with safe backup)
  -n           Add global line numbers to final output
  -s           Skip empty lines
  -u           Remove duplicate lines (preserve first occurrence)
  -f REGEX     Include only lines that match this extended regex (egrep -E)
  -F REGEX     Include only files whose path (basename) matches this regex
  -r           Recursively search directories (with optional -F)
  -S STRING    Separator string to insert between files (default: a header with filename)
  -v           Verbose mode
Examples:
  $0 -r -F '.*\\.txt$' -f 'ERROR' -n -s -o out.txt ./logs
  cat a.txt b.txt | $0 -o combined.txt -
USAGE
}

err() { echo "ERROR: $*" >&2; }

# Default values
output=""
append_mode=0
add_numbers=0
skip_empty=0
unique_lines=0
line_regex=""
file_regex=""
recursive=0
separator=""
verbose=0

# parse options
while getopts "ho:nsuf:F:rS:av" opt; do
  case "$opt" in
    h) usage; exit 0;;
    o) output="$OPTARG";;
    n) add_numbers=1;;
    s) skip_empty=1;;
    u) unique_lines=1;;
    f) line_regex="$OPTARG";;
    F) file_regex="$OPTARG";;
    r) recursive=1;;
    S) separator="$OPTARG";;
    a) append_mode=1;;
    v) verbose=1;;
    *) usage; exit 2;;
  esac
done
shift $((OPTIND -1))

# Validate required options
if [[ -z "$output" ]]; then
  err "Output file is required (-o)."
  usage
  exit 2
fi

# Validate at least one input (or allow '-' for stdin). If none provided, error.
if [[ $# -eq 0 ]]; then
  err "At least one input (file|dir|-) is required."
  usage
  exit 2
fi

# Validate regexes syntactically by passing them to grep -E with an empty input
if [[ -n "$line_regex" ]]; then
  if ! echo "" | egrep -E "$line_regex" >/dev/null 2>&1; then
    err "Invalid line regex (-f): $line_regex"
    exit 3
  fi
fi
if [[ -n "$file_regex" ]]; then
  if ! echo "" | egrep -E "$file_regex" >/dev/null 2>&1; then
    err "Invalid file regex (-F): $file_regex"
    exit 3
  fi
fi

# If no custom separator, build a default header per file
if [[ -z "$separator" ]]; then
  separator="--==FILE==--"  # followed by filename when inserted
fi

# Helper: verbose print
vprint() { if [[ "$verbose" -eq 1 ]]; then echo "$@"; fi }

# Build a list of input file paths (in order). '-' stands for stdin and is passed through.
declare -a inputs
for arg in "$@"; do
  if [[ "$arg" == "-" ]]; then
    inputs+=("-")
    continue
  fi

  if [[ -d "$arg" ]]; then
    if [[ "$recursive" -eq 1 ]]; then
      # find regular files under directory
      while IFS= read -r -d $'\0' f; do
        inputs+=("$f")
      done < <(find "$arg" -type f -print0)
    else
      # Non-recursive: add files directly in dir
      while IFS= read -r -d $'\0' f; do
        inputs+=("$f")
      done < <(find "$arg" -maxdepth 1 -type f -print0)
    fi
  else
    # treat as file path (may not exist yet)
    inputs+=("$arg")
  fi
done

# If file_regex provided, filter inputs (except '-' which represents stdin)
if [[ -n "$file_regex" ]]; then
  filtered=()
  for p in "${inputs[@]}"; do
    if [[ "$p" == "-" ]]; then
      filtered+=("$p"); continue
    fi
    # match basename or full path? use basename for convenience
    base=$(basename "$p")
    if echo "$base" | egrep -E "$file_regex" >/dev/null 2>&1; then
      filtered+=("$p")
    else
      vprint "Skipping (filename regex): $p"
    fi
  done
  inputs=("${filtered[@]}")
fi

if [[ ${#inputs[@]} -eq 0 ]]; then
  err "No input files matched after applying -F filter (or no files found)."
  exit 4
fi

# Prepare temp output file
tmp_out=$(mktemp --tmpdir concat.out.XXXXXX) || { err "Failed to create temp file"; exit 5; }
vprint "Using temp output: $tmp_out"

# Process inputs and stream into tmp_out
# We'll write raw (no numbering/uniq) into tmp_out, then post-process for -u and -n
> "$tmp_out" || { err "Cannot write to temp file"; exit 5; }

for p in "${inputs[@]}"; do
  if [[ "$p" == "-" ]]; then
    vprint "Reading from stdin..."
    # Insert header for stdin
    echo "$separator stdin" >> "$tmp_out"
    # read stdin and process
    if [[ -n "$line_regex" ]]; then
      # filter lines by regex
      egrep -E "$line_regex" || true >> "$tmp_out"
    else
      cat - >> "$tmp_out"
    fi
    continue
  fi

  # Check file existence and readability
  if [[ ! -e "$p" ]]; then
    err "Skipping missing file: $p"
    continue
  fi
  if [[ ! -f "$p" ]]; then
    err "Skipping non-regular file (not a plain file): $p"
    continue
  fi
  if [[ ! -r "$p" ]]; then
    err "Skipping unreadable file: $p"
    continue
  fi

  # Insert separator + filename header
  echo "${separator} ${p}" >> "$tmp_out"

  # Read file contents, apply line filter if provided, optionally remove empty lines here
  if [[ -n "$line_regex" ]]; then
    # only matching lines
    egrep -E "$line_regex" "$p" || true >> "$tmp_out"
  else
    cat "$p" >> "$tmp_out"
  fi

done

# Now post-process tmp_out into final form based on -s, -u, -n
final_tmp=$(mktemp --tmpdir concat.final.XXXXXX) || { err "Failed to create final temp file"; rm -f "$tmp_out"; exit 6; }
cp "$tmp_out" "$final_tmp"

# apply skip-empty: remove fully-empty lines
if [[ "$skip_empty" -eq 1 ]]; then
  vprint "Removing empty lines..."
  awk 'NF' "$final_tmp" > "${final_tmp}.tmp" && mv "${final_tmp}.tmp" "$final_tmp"
fi

# apply uniqueness
if [[ "$unique_lines" -eq 1 ]]; then
  vprint "Removing duplicate lines (preserve first occurrence)..."
  awk '!seen[$0]++' "$final_tmp" > "${final_tmp}.tmp" && mv "${final_tmp}.tmp" "$final_tmp"
fi

# apply numbering (global numbering)
if [[ "$add_numbers" -eq 1 ]]; then
  vprint "Adding global line numbers..."
  # Use awk to number so we don't change other formatting; numbers start at 1
  awk '{printf("%6d\t%s\n", NR, $0)}' "$final_tmp" > "${final_tmp}.tmp" && mv "${final_tmp}.tmp" "$final_tmp"
fi

# Write final output safely (atomic move), with optional append
if [[ -f "$output" && "$append_mode" -eq 0 ]]; then
  # backup existing
  ts=$(date --iso-8601=seconds 2>/dev/null || date +%s)
  bak="${output}.bak.${ts}"
  vprint "Backing up existing output to: $bak"
  cp -p "$output" "$bak" || { err "Failed to create backup of existing output"; rm -f "$tmp_out" "$final_tmp"; exit 7; }
fi

if [[ "$append_mode" -eq 1 ]]; then
  # append final_tmp to output
  vprint "Appending to output: $output"
  cat "$final_tmp" >> "$output" || { err "Failed to append to $output"; rm -f "$tmp_out" "$final_tmp"; exit 8; }
else
  # overwrite atomically via mv
  vprint "Writing output (atomic): $output"
  mkdir -p "$(dirname "$output")" 2>/dev/null || true
  mv "$final_tmp" "$output" || { err "Failed to move final output to $output"; rm -f "$tmp_out" "$final_tmp"; exit 9; }
fi

# Cleanup temp files (if final_tmp already moved, it's gone)
rm -f "$tmp_out" >/dev/null 2>&1 || true
vprint "Completed. Output at: $output"

exit 0
