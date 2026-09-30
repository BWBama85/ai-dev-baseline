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
# skill). It judges the description and the frontmatter structure that decides WHICH line is the
# description, and what a key's value is:
#   - every top-level line is blank, a comment, or a plain `key:` (letters, digits, `_`, `-`), and
#     no key is given twice. A quoted, escaped, tagged, anchored, `? ` or tab-separated key is
#     refused rather than parsed, since YAML may read it as a second spelling of `description` — or
#     of `name` — that Claude would see and the Codex/Gemini capture would not;
#   - an indented line belongs only under a key with no inline value (`key:`, `key: # note`, or a
#     block-scalar header `key: |`), which opens a block.
#     Before any key it is a mapping of its own; after `key: value` it continues that value, across
#     blank lines — either way YAML reads a value this line-by-line reading would not. An indented
#     comment is dropped by YAML, so it is allowed anywhere.
# Every other property of the other keys is their own reader's business. The description itself:
#   - one `description:` key in a frontmatter that opens on line 1 and closes with `---`, and a
#     space after the key;
#   - printable ASCII only (no control byte, CR, tab or non-ASCII), starting with a letter;
#   - no `: ` or trailing `:` (a mapping), no ` #` (a comment that cuts it short), and not a bare
#     null or boolean keyword.
# A trailing CR per line is tolerated, as a CRLF file's line ending; an embedded one is not.

{ sub(/\r$/, "") }
done { next }
NR == 1 { if ($0 != "---") { r = "no frontmatter"; done = 1 }; next }
$0 == "---" { closed = 1; done = 1; next }
/^[[:space:]]*$/ { next }
/^[[:space:]]*#/ { next }
/^[[:space:]]/ {
  if (!haskey) { r = "an indented line with no key above it"; done = 1; next }
  if (!block) { r = "a multi-line continuation"; done = 1; next }
  next
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
  seen = 1
}
{
  if ($0 !~ /^[A-Za-z][A-Za-z0-9_-]*:( |$)/) { r = "a top-level line that is not a plain key"; done = 1; next }
  key = $0; sub(/:.*/, "", key)
  if (key in keys) { r = "the key " key " given twice"; done = 1; next }
  keys[key] = 1; haskey = 1; block = ($0 ~ /^[A-Za-z][A-Za-z0-9_-]*:([ ]*|[ ]+#.*|[ ]+[|>][-+0-9]*[ ]*)$/)
}
END {
  if (r == "" && NR == 0) r = "no frontmatter"
  if (r == "" && !closed) r = "an unclosed frontmatter"
  if (r == "" && !seen) r = "no description line"
  if (r != "") print "bad\t" r
  else print "ok\t" v
}
