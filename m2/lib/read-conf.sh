#!/usr/bin/env bash
# read-conf.sh - the one parser for the key=value input files under m2/inputs/.
# It is sourced by the calculators. It reads the input files with awk and never sources them,
# because sourcing a file a learner has edited would run whatever is written in it.
# A line starting with # is a comment. A key is everything before the first = sign.

# conf_get FILE KEY -> prints the value, exits 2 with a message if the key is missing.
conf_get() {
  local file="$1" key="$2" out
  if [ ! -r "$file" ]; then
    echo "error: cannot read input file: $file" >&2
    exit 2
  fi
  out=$(LC_ALL=C awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      i = index($0, "=")
      if (i == 0) next
      if (substr($0, 1, i - 1) == k) { print substr($0, i + 1); found = 1; exit }
    }
    END { if (!found) exit 3 }
  ' "$file") || {
    echo "error: key '$key' not found in $file" >&2
    exit 2
  }
  printf '%s\n' "$out"
}

# conf_num FILE KEY -> like conf_get, but the value must look like a plain number.
conf_num() {
  local v
  v=$(conf_get "$1" "$2")
  case "$v" in
    ''|*[!0-9.]*|*.*.*)
      echo "error: key '$2' in $1 must be a plain number, found: $v" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$v"
}

# conf_dump FILE [REGEX] -> prints the key=value lines in file order, optionally only keys matching REGEX.
conf_dump() {
  local file="$1" re="${2:-.}"
  LC_ALL=C awk -v re="$re" '
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
