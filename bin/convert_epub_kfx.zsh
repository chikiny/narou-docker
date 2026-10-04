#!/bin/zsh

# Convert selected EPUBs directly under convert_output, then archive them.
#
# Ported from convert_output/07_scripts/convert_epub_kfx.zsh on the Mac.
# The only change is that the output directory comes from CONVERT_OUTPUT_DIR
# (default: /convert_output) instead of the parent of the script directory.

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly PROGRAM_NAME=${0:t}
readonly OUTPUT_DIR=${${CONVERT_OUTPUT_DIR:-/convert_output}:A}
readonly EPUB_ARCHIVE_DIR="$OUTPUT_DIR/04_epub"

usage() {
  cat <<EOF
Usage:
  $PROGRAM_NAME FILE.epub [FILE.epub ...]

Example:
  $PROGRAM_NAME $OUTPUT_DIR/*.epub

Only EPUBs directly inside this directory are accepted:
  $OUTPUT_DIR

Each KFX is written to that directory. After every conversion succeeds,
the EPUB is moved into:
  $EPUB_ARCHIVE_DIR
EOF
}

die() {
  print -u2 -- "ERROR: $*"
  exit 1
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

command -v boko >/dev/null 2>&1 || die "boko was not found in PATH"

typeset -a epub_files
typeset -A seen_paths

for argument in "$@"; do
  [[ -f "$argument" ]] || die "Input file does not exist: $argument"
  [[ -r "$argument" ]] || die "Input file is not readable: $argument"
  [[ "${argument:l}" == *.epub ]] || die "Input is not an .epub file: $argument"

  input_file=${argument:A}
  [[ "${input_file:h}" == "$OUTPUT_DIR" ]] ||
    die "Input must be directly inside $OUTPUT_DIR: $argument"
  [[ -z "${seen_paths[$input_file]-}" ]] ||
    die "Input was specified more than once: $argument"

  seen_paths[$input_file]=1
  epub_files+=("$input_file")
done

# Complete every conversion before moving any source EPUB. If one conversion
# fails, the source files remain in place for investigation and retry.
for input_file in "${epub_files[@]}"; do
  output_file="${input_file:r}.kfx"
  print -- "Converting: ${input_file:t} -> ${output_file:t}"
  boko convert -O "$input_file" "$output_file"
done

mkdir -p -- "$EPUB_ARCHIVE_DIR"
for input_file in "${epub_files[@]}"; do
  archive_file="$EPUB_ARCHIVE_DIR/${input_file:t}"
  if [[ -e "$archive_file" ]]; then
    print -- "Replacing archived EPUB: $archive_file"
  else
    print -- "Archiving: ${input_file:t} -> $EPUB_ARCHIVE_DIR/"
  fi
  mv -f -- "$input_file" "$archive_file"
done

print -- "Completed ${#epub_files[@]} EPUB file(s)."
