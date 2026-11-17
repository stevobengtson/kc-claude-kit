#!/usr/bin/env bash
# Readers for intake.md, the file the intake agent writes (agents/intake.md):
# three header lines (DECISION:, RISK:, SURFACES:) and "## <heading>" sections.
# Sourced by plan.sh, route.sh and ticket.sh, so each reads the file one way.

# get_intake_section <intake.md> <heading>: the lines under "## <heading>" up to
# the next "## " heading, carriage returns dropped, blank lines trimmed from both
# ends. The heading matches with surrounding blanks ignored.
get_intake_section() {
  awk -v want="$2" '
    /^## / { name = $0; sub(/^##[ \t]+/, "", name); sub(/[ \t\r]+$/, "", name); in_section = (name == want); next }
    in_section { sub(/\r$/, ""); lines[++count] = $0 }
    END {
      first = 1; while (first <= count && lines[first] ~ /^[ \t]*$/) first++
      last = count; while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }' "$1"
}

# get_intake_header_value <intake.md> <NAME>: the trimmed text after "NAME:" on
# its line among the first three, or nothing.
get_intake_header_value() {
  sed -n '1,3p' "$1" | awk -v name="$2" '
    index($0, name ":") == 1 { value = substr($0, length(name) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", value); print value; exit }'
}
