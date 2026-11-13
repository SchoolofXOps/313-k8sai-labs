#!/usr/bin/env bash
# read-conf.sh - the one parser for the key=value input files under m2/inputs/.
# It is sourced by the calculators. It reads the input files with awk and never sources them,
# because sourcing a file a learner has edited would run whatever is written in it.
# A line starting with # is a comment. A key is everything before the first = sign.

# conf_get FILE KEY -> prints the value, exits 2 with a message if the key is missing or repeated.
# A repeated key is an error rather than a silent first-or-last pick: the assumptions header prints
# every line, so either choice would print one value and compute with another.
# A line ending in a carriage return (a file saved on Windows) is read as if it ended in a newline.
conf_get() {
  local file="$1" key="$2" out rc=0
  if [ ! -r "$file" ]; then
    echo "error: cannot read input file: $file" >&2
    exit 2
  fi
  out=$(LC_ALL=C awk -v k="$key" '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      i = index($0, "=")
      if (i == 0) next
      if (substr($0, 1, i - 1) == k) { n++; v = substr($0, i + 1); lines = lines (n > 1 ? ", " : "") NR }
    }
    END {
      if (n == 0) exit 3
      if (n > 1) { print n " " lines; exit 4 }
      print v
    }
  ' "$file") || rc=$?
  case "$rc" in
    0) ;;
    3) echo "error: key '$key' not found in $file" >&2; exit 2 ;;
    4) echo "error: key '$key' appears ${out%% *} times in $file (lines ${out#* }); keep exactly one" >&2; exit 2 ;;
    *) echo "error: could not read key '$key' from $file" >&2; exit 2 ;;
  esac
  printf '%s\n' "$out"
}

# conf_num FILE KEY -> like conf_get, but the value must be a plain decimal: digits, optionally a
# dot and more digits (64, 0.10). "." alone, ".5", "5." and signs are refused.
# Every caller runs this inside $(...), where bash does not inherit set -e, so a failed lookup
# exits here explicitly rather than falling through to a second, misleading error.
conf_num() {
  local v
  v=$(conf_get "$1" "$2") || exit 2
  case "$v" in
    ''|*[!0-9.]*|.*|*.|*.*.*)
      echo "error: key '$2' in $1 must be a plain number, found: $v" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$v"
}

# conf_pos FILE KEY -> like conf_num, but the value must be greater than zero. For a value a
# formula divides by: zero would end in an awk "division by zero" halfway through the output.
conf_pos() {
  local v
  v=$(conf_num "$1" "$2") || exit 2
  case "$v" in
    *[1-9]*) ;;
    *)
      echo "error: key '$2' in $1 must be greater than zero (the calculation divides by it), found: $v" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$v"
}

# conf_dump FILE [REGEX] -> prints the key=value lines in file order, optionally only keys matching REGEX.
conf_dump() {
  local file="$1" re="${2:-.}"
  LC_ALL=C awk -v re="$re" '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      i = index($0, "=")
      if (i == 0) next
      if (substr($0, 1, i - 1) ~ re) print "  " $0
    }
  ' "$file"
}

# assumptions_header -> the fixed first line every calculator prints.
assumptions_header() {
  echo "ASSUMPTIONS (an estimate from stated inputs, not a measurement):"
  echo "  units: GB = 10^9 bytes; vendor capacities are used exactly as the vendor prints them"
}
