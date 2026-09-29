# ai-dev-baseline — THE skill-description rule (#436), one home for its two readers.
#
# Usage: LC_ALL=C awk -f scripts/skill-description.awk <file>
#   scripts/build.sh runs it on each base/workflows/<name>.md before rendering; scripts/render-size.sh
#   runs it on each rendered agents/<agent>/skills/<name>/SKILL.md before counting. LC_ALL=C is the
#   caller's duty: the printable-ASCII test below is a byte range only in the C locale.
#
# Output, one line: `ok<TAB><value>` or `bad<TAB><reason>`. Exit status is 0 either way; a caller
# that gets neither line could not run the rule.
#
# The admitted value is deliberately narrower than YAML, so that its text IS what every loader reads
# (a value Claude cannot parse loads the skill with no fields; Codex skips the skill):
#   - one `description:` key in a frontmatter that opens on line 1 and closes with `---`, a space
#     after the key, and no continuation — an indented line after it, across blank lines, unless
#     it is a comment, which YAML drops;
#   - printable ASCII only (no control byte, CR, tab or non-ASCII), starting with a letter;
#   - no `: ` or trailing `:` (a mapping), no ` #` (a comment that cuts it short), and not a bare
#     null or boolean keyword.
# A trailing CR per line is tolerated, as a CRLF file's line ending; an embedded one is not.

{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") { r = "no frontmatter"; exit }; next }
$0 == "---" { closed = 1; exit }
cont && /^[[:space:]]*$/ { next }
cont && /^[[:space:]]*#/ { next }
cont && /^[[:space:]]/ { r = "a multi-line continuation"; exit }
{ cont = 0 }
/^description:/ {
  if (seen) { r = "a second description line"; exit }
  if ($0 ~ /^description:[[:space:]]*$/) { r = "an empty description"; exit }
  if ($0 !~ /^description:[ ]/) { r = "no space after the description key"; exit }
  v = $0; sub(/^description:[ ]+/, "", v); sub(/[ ]+$/, "", v)
  if (v ~ /^[>|][+-]?$/) { r = "a folded/block scalar"; exit }
  if (v ~ /[^ -~]/) { r = "a byte outside printable ASCII"; exit }
  if (v !~ /^[A-Za-z]/) { r = "a value that does not start with a letter"; exit }
  if (v ~ /:( |$)/) { r = "a colon YAML reads as a mapping"; exit }
  if (v ~ / #/) { r = "a space-hash YAML reads as a comment"; exit }
  if (tolower(v) ~ /^(null|true|false|yes|no|on|off|y|n)$/) { r = "a bare YAML keyword"; exit }
  seen = 1; cont = 1
}
END {
  if (r == "" && NR == 0) r = "no frontmatter"
  if (r == "" && !closed) r = "an unclosed frontmatter"
  if (r == "" && !seen) r = "no description line"
  if (r != "") print "bad\t" r
  else print "ok\t" v
}
