# ai-dev-baseline — THE skill frontmatter rule (#436, #572), one home for its two readers.
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
#     block-scalar header: `|` or `>`, an optional 1-9 indentation indicator and `+`/`-` in either
#     order, and an optional comment), which opens a block. Indentation is spaces: YAML forbids a
#     tab there, so a line whose leading whitespace holds one — a comment, a blank, or content — is
#     refused, and so is a control byte on any line (a vertical tab or form feed would otherwise pass
#     for whitespace). Before any key an indented line is a mapping of its own; after `key: value` it
#     continues that value, across blank lines — either way YAML reads a value this line-by-line
#     reading would not. An indented comment is dropped by YAML, so it is allowed anywhere outside a
#     block scalar;
#   - every block is one of two shapes, each checked whole — the rule admits only what it can judge,
#     because a loader that cannot parse a header drops the whole skill (#572). Under a
#     block-scalar header, every content line sits at or past the scalar's indentation (the header's
#     indicator, or else the first content line's), no blank line before the first content line has
#     more spaces than it, and a `#` line less indented ends the scalar rather than being skipped.
#     Under a bare `key:`, the one shape admitted is a list of values, `- item` per line, all at one
#     indentation, each item judged as an inline value is; a nested mapping, a nested list or a
#     multi-line item is refused, not parsed;
#   - every other key's inline value is one scalar. Quoted, it closes where it ends, past an
#     optional comment, and a double-quoted one holds no backslash (no escape to get wrong).
#     Unquoted, it does not start with a YAML indicator — `[ ] { } , & * ! | > % @ :` or a backtick,
#     or `-`, `?` followed by a space or nothing — and holds no `: ` and no trailing `:` before its
#     comment. A `|`/`>` that is a valid block-scalar header opens a block instead, and is not a value;
#   - no frontmatter line, block content included, carries invalid UTF-8 (a lone or truncated
#     sequence, an overlong form, a surrogate, past U+10FFFF), a C1 control or U+FFFE/U+FFFF. YAML
#     forbids all of them but NEL (U+0085), which YAML 1.2 allows and YAML 1.1 reads as a line
#     break, so the rule refuses it too.
# The tab rule holds inside a block scalar too: a tab right after the indentation is content to
# PyYAML and an error to libyaml, and where loaders disagree the rule refuses. The description itself:
#   - one `description:` key in a frontmatter that opens on line 1 and closes with `---`, and a
#     space after the key;
#   - printable ASCII only (no control byte, CR, tab or non-ASCII), starting with a letter;
#   - no `: ` or trailing `:` (a mapping), no ` #` (a comment that cuts it short), and not a bare
#     null or boolean keyword.
# A trailing CR per line is tolerated, as a CRLF file's line ending; an embedded one is not.

BEGIN {
  # Every C0 control byte but TAB, and DEL, built by value rather than spelled as octal escapes,
  # whose meaning inside a bracket expression is not the same in every awk.
  ctl = "["
  for (i = 1; i < 32; i++) if (i != 9) ctl = ctl sprintf("%c", i)
  ctl = ctl sprintf("%c", 127) "]"
  # YAML's c-indicator set, less `#` (after the space a value needs, it opens a comment) and the
  # two that may start a plain scalar when no space follows (`-`, `?`). YAML 1.2 lets `:` do so too;
  # libyaml refuses it, and where loaders disagree the rule refuses. Checked by index(), never a
  # bracket expression: awks disagree about `]`, `\` and a backtick inside one.
  indicators = "[]{},&*!|>%@:" sprintf("%c", 96)
  # The bytes the rule refuses on any frontmatter line (#572): what remains of a line once every
  # well-formed UTF-8 sequence is deleted must be ASCII, so a lone or truncated sequence, an overlong
  # form and an encoded surrogate are refused; and of what is well-formed, a C1 control and
  # U+FFFE/U+FFFF.
  # Classes are byte LISTS built by value, never ranges, whose meaning past 127 differs between awks.
  cont = bytes(128, 191)
  utf8 = bytes(194, 223) cont "|" sprintf("%c", 224) bytes(160, 191) cont "|" bytes(225, 236) cont cont \
    "|" sprintf("%c", 237) bytes(128, 159) cont "|" bytes(238, 239) cont cont "|" sprintf("%c", 240) bytes(144, 191) cont cont \
    "|" bytes(241, 243) cont cont cont "|" sprintf("%c", 244) bytes(128, 143) cont cont
  high = bytes(128, 255)
  forbidden = sprintf("%c", 194) bytes(128, 159) "|" sprintf("%c%c", 239, 191) bytes(190, 191)
}
function bytes(lo, hi,   s, i) { s = "["; for (i = lo; i <= hi; i++) s = s sprintf("%c", i); return s "]" }
function indent(line,   m) { m = line; sub(/[^ ].*$/, "", m); return length(m) }
# value_bad <value> <what> — why an inline or list-item value is not one scalar, or "" when it is.
function value_bad(iv, what,   c, c2, pv) {
  c = substr(iv, 1, 1); c2 = substr(iv, 2, 1)
  if (c == "\"") {
    if (iv !~ /^"[^"\\]*"([ \t]+#.*)?$/) return what " is a double-quoted string that does not close at its end, or holds a backslash"
    return ""
  }
  if (c == "'") {
    if (iv !~ /^'([^']|'')*'([ \t]+#.*)?$/) return what " is a single-quoted string that does not close at its end"
    return ""
  }
  if ((c != "" && index(indicators, c)) || (index("-?", c) && (c2 == "" || c2 == " " || c2 == "\t")))
    return what " starts with the YAML indicator " c " (quote the value)"
  pv = iv; sub(/[ \t]#.*/, "", pv)
  if (pv ~ /:([ \t]|$)/) return what " holds a colon YAML reads as a mapping (quote the value)"
  return ""
}
{ sub(/\r$/, "") }
done { next }
NR == 1 { if ($0 != "---") { r = "no frontmatter"; done = 1 }; next }
$0 == "---" { closed = 1; done = 1; next }
/^[ ]*\t/ { r = "a tab in indentation"; done = 1; next }
!/^description:/ && $0 ~ ctl { r = "a control byte"; done = 1; next }
!/^description:/ && $0 ~ high {
  u = $0; gsub(utf8, "", u)
  if (u ~ high || $0 ~ forbidden) { r = "a byte the rule refuses (invalid UTF-8, a C1 control, or U+FFFE/U+FFFF)"; done = 1; next }
}
# A blank line is nothing, save before a block scalar's first content line, which must not have
# more spaces than that line has (YAML refuses it).
/^[[:space:]]*$/ { if (bkind == "scalar" && !bind && length($0) > lead) lead = length($0); next }
# A comment is dropped by YAML — except inside a block scalar, where an indented `#` line at or past
# the scalar's indentation is content, and one less indented (or at column 0) ends the scalar.
/^[[:space:]]*#/ {
  if (bkind != "scalar") next
  n = indent($0)
  if (n > 0 && !bind) { if (lead > n) { r = "a block scalar whose leading blank line is indented past its first line"; done = 1; next }; bind = n; next }
  if (n < bind || n == 0) { block = 0; bkind = "" }
  next
}
/^[[:space:]]/ {
  if (!haskey) { r = "an indented line with no key above it"; done = 1; next }
  if (!block) { r = "a multi-line continuation"; done = 1; next }
  n = indent($0)
  if (bkind == "scalar") {
    if (!bind) { if (lead > n) { r = "a block scalar whose leading blank line is indented past its first line"; done = 1; next }; bind = n; next }
    if (n < bind) { r = "a block scalar line indented less than its block"; done = 1 }
    next
  }
  # Under a bare `key:` the one shape admitted is a list of scalars, one `- item` per line, all at
  # one indentation; each item is judged as an inline value is.
  if ($0 ~ /^ +-$/ || $0 ~ /^ +-[ \t]+(#.*)?$/) { r = "an empty " key " list item"; done = 1; next }
  if ($0 !~ /^ +- /) { r = "nested content under " key " that is not a list of values"; done = 1; next }
  if (!sind) sind = n
  else if (n != sind) { r = "the " key " list items at different indentation"; done = 1; next }
  iv = $0; sub(/^ +-[ \t]+/, "", iv); sub(/[ \t]+$/, "", iv)
  e = value_bad(iv, "a list item under " key)
  if (e != "") { r = e; done = 1 }
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
  keys[key] = 1; haskey = 1; block = ($0 ~ /^[A-Za-z][A-Za-z0-9_-]*:([ ]*|[ ]+#.*|[ ]+[|>]([1-9][-+]?|[-+][1-9]?)?([ ]+#.*)?[ ]*)$/)
  bkind = ""; bind = 0; lead = 0; sind = 0
  if (block) {
    h = $0; sub(/^[A-Za-z][A-Za-z0-9_-]*:[ ]*/, "", h); sub(/[ ]*#.*/, "", h)
    if (h ~ /^[|>]/) { bkind = "scalar"; if (match(h, /[1-9]/)) bind = substr(h, RSTART, 1) + 0 }
    else bkind = "bare"
    next
  }
  if (key == "description") next
  iv = $0; sub(/^[A-Za-z][A-Za-z0-9_-]*:[ \t]*/, "", iv); sub(/[ \t]+$/, "", iv)
  e = value_bad(iv, "the " key " value")
  if (e != "") { r = e; done = 1 }
}
END {
  if (r == "" && NR == 0) r = "no frontmatter"
  if (r == "" && !closed) r = "an unclosed frontmatter"
  if (r == "" && !seen) r = "no description line"
  if (r != "") print "bad\t" r
  else print "ok\t" v
}
