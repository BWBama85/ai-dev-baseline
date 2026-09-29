# ai-dev-baseline — THE skill-description rule (#436), one home for its two readers.
#
# Usage: LC_ALL=C tr '\000' '\001' < <file> | LC_ALL=C awk -f scripts/skill-description.awk
#   scripts/build.sh runs it on each base/workflows/<name>.md before rendering; scripts/render-size.sh
#   runs it on each rendered agents/<agent>/skills/<name>/SKILL.md before counting. Both halves of
#   the pipeline are the caller's duty: the printable-ASCII test is a byte range only in the C
#   locale, and some awks (macOS) end a line at a NUL, which would hide it — mapped to \001 first,
#   the test refuses it.
#
# Output, one line: `ok<TAB><value>` or `bad<TAB><reason>`. Exit status is 0 either way; a caller
# that gets neither line could not run the rule. It reads its WHOLE input even once decided — an
# early exit lets the writer upstream die of SIGPIPE, which a `pipefail` caller reads as failure.
#
# The admitted value is deliberately narrower than YAML, so that its text IS what every loader reads
# as the description (a value Claude cannot parse loads the skill with no fields; Codex skips the
# skill). It judges the description only — every other key is its own reader's business:
#   - one `description:` key in a frontmatter that opens on line 1 and closes with `---`, spelled
#     exactly so (no quoted, tagged, `? ` or `description :` form, which YAML reads as the same key),
#     a space after the key, and no continuation — an indented line after it, across blank lines,
#     unless it is a comment, which YAML drops;
#   - printable ASCII only (no control byte, CR, tab or non-ASCII), starting with a letter;
#   - no `: ` or trailing `:` (a mapping), no ` #` (a comment that cuts it short), and not a bare
#     null or boolean keyword.
# A trailing CR per line is tolerated, as a CRLF file's line ending; an embedded one is not.

{ sub(/\r$/, "") }
done { next }
NR == 1 { if ($0 != "---") { r = "no frontmatter"; done = 1 }; next }
$0 == "---" { closed = 1; done = 1; next }
cont && /^[[:space:]]*$/ { next }
cont && /^[[:space:]]*#/ { next }
cont && /^[[:space:]]/ { r = "a multi-line continuation"; done = 1; next }
{ cont = 0 }
{
  k = $0; sub(/^\?[ ]+/, "", k); sub(/^![^ ]*[ ]+/, "", k)
  if (k ~ /^["']/) { q = substr(k, 1, 1); k = substr(k, 2); sub(q, "", k) }
  if (k ~ /^description[ ]*(:|$)/ && $0 !~ /^description:/) { r = "a description key spelled another way"; done = 1; next }
}
/^description:/ {
  if (seen) { r = "a second description line"; done = 1; next }
  if ($0 ~ /^description:[[:space:]]*$/) { r = "an empty description"; done = 1; next }
  if ($0 !~ /^description:[ ]/) { r = "no space after the description key"; done = 1; next }
  v = $0; sub(/^description:[ ]+/, "", v); sub(/[ ]+$/, "", v)
  if (v ~ /^[>|][+-]?$/) { r = "a folded/block scalar"; done = 1; next }
  if (v ~ /[^ -~]/) { r = "a byte outside printable ASCII"; done = 1; next }
  if (v !~ /^[A-Za-z]/) { r = "a value that does not start with a letter"; done = 1; next }
  if (v ~ /:( |$)/) { r = "a colon YAML reads as a mapping"; done = 1; next }
  if (v ~ / #/) { r = "a space-hash YAML reads as a comment"; done = 1; next }
  if (tolower(v) ~ /^(null|true|false|yes|no|on|off|y|n)$/) { r = "a bare YAML keyword"; done = 1; next }
  seen = 1; cont = 1
}
END {
  if (r == "" && NR == 0) r = "no frontmatter"
  if (r == "" && !closed) r = "an unclosed frontmatter"
  if (r == "" && !seen) r = "no description line"
  if (r != "") print "bad\t" r
  else print "ok\t" v
}
