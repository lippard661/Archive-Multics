# Design note: 9-bit transfers and dense9 archives

Status: implemented in Archive::Multics 0.05 (2026-09-24), following the
transfer format in the next sections; where this note and the code
differ, the code and the man page are authoritative. From discussions on
2026-09-23 with the author of the Multics `sha256 -byte8`/`-dense9` code,
plus notes added here.

As implemented (0.05): archives are kept as raw dense9 on Unix, so their
SHA-256 matches `sha256 -dense9` on Multics. `archive --import` converts
a transfer file to a raw archive (the user names the archive), and
`archive --export` converts an archive to a transfer file; the keys that
change an archive refuse a transfer file. Binary components extract as
raw dense9 (SHA-256 matches `sha256 -dense9`), or with `-T` as transfer
files (`-dense9 N` and base64, no name or digest). A raw file records
no bit count, so `x` prints it ("bit count 70200 (to put it back: --bits
70200)"), and `r`/`a`/`u --bits N` puts a raw file back, requiring
exactly `9 × ceil(N / 72)` octets; a transfer file goes back without it.
A component with 9-bit data is never replaced from a file of unknown
bit count: `r`/`u` refuse, and global ones skip it with a message. Text
components extract as octets
(SHA-256 matches `sha256 -byte8`). `-9`/`-8` choose the form *written*;
reading always detects, unless the module's `encoding` option is
given.

## Encodings

- **byte8** (current): one octet per 9-bit Multics character; the 9th bit
  is lost. Exact for text; binary components are silently corrupted (see
  FORMAT.md). Length-preserving: octets × 9 is the bit count, so no
  metadata is needed.
- **dense9**: the segment's bit string, big-endian: every 8 nine-bit
  characters (72 bits, two 36-bit words) become 9 octets, and the last
  group is padded to 72 bits. Lossless, but the octet count only bounds
  the bit count (18 octets is anything from 73 to 144 bits), so the bit
  count has to travel with the data.

Checked example: `abcdefg\n` (bit count 72) is the 9 octets
`30 98 8c 66 43 29 98 ce 0a`, base64 `MJiMZkMpmM4K`, sha256
`b983bc28d71d360ec06584c8e600a28c67834a724265abdbfcf8ebc60cfa43fd`, which
matches `sha256 -dense9` of the segment on Multics.

A binary archive is transferred entirely as dense9, even if most of its
components are text; text components still extract as ordinary text
files.

## Transfer format (implemented on Multics, 2026-09-24)

`encode_base64 -dense9` writes, and `decode_base64` reads, a one-line
header followed by base64:

```
-dense9 72
MJiMZkMpmM4K
```

- The header is the first thing in the file: exactly `-dense9`, one
  space, the decimal bit count, LF. Nothing else on the line (the count is
  parsed with `cv_dec_check_` from character 9; a second space, trailing
  text, or a CR before the LF makes it fail).
- Bit count at most 9,400,320 (one 255K-word segment); for an archive it
  is `36 × words`.
- Body: standard base64 (`A-Za-z0-9+/`), any line width, whitespace
  ignored. No `=` ever appears, because the octet count is a multiple of 9.
- The octet count must be exactly `9 × ceil(bits / 72)`; `$unpack`
  rejects a stream a group short or long, so a truncated transfer is
  caught.
- Pad bits after the bit count: Archive::Multics writes zeros and warns
  (does not fail) if it reads nonzero pad bits. (To confirm what `$unpack`
  requires.)
- `-sha256 <digest>` (64 lowercase hex digits): written by default by
  `encode_base64` since 2026-10, as a second header line after
  `-dense9 N` (readers accept either order), or as the only header line
  before base64 of byte8 data (an archive of text, or a gzip file). The
  digest is SHA-256 of the octets carried: for dense9, the packed octets,
  so it equals `sha256 -dense9` of the segment; for byte8, `sha256
  -byte8`. A `-byte8` line (no value) may also appear, alone or with
  `-sha256`, marking byte8 data; with `-dense9` it is an error.
  Archive::Multics checks it, rejects unknown or repeated header
  lines, and writes `-sha256` after `-dense9` on `--export` and `x -T`;
  `--export` of a byte8 archive writes `-byte8`, `-sha256` and base64 of
  its octets, as `encode_base64` does (the derivation line comes first;
  the digest is of the octets encoded, not of the base64 text).
  `--gzip --export` does the whole Multics pipeline (archive, gzip,
  `encode_base64`) in one step: on `bound_secure_hash_`, 21,465 octets
  against 35,128 for a plain dense9 `--export`. On Multics, `decode_base64`
  verifies byte8 with one `$sha256_octets` call over the output segment,
  and dense9 with `$sha256_add` on each buffer before it is unpacked; the
  digest is the same either way.
  (It catches damaged octets, not a wrong bit count; see "Bit count
  ambiguity".)
- byte8 transfers without `-sha256` have no header, as before.

Archive::Multics:

- Reads a file beginning with `-dense9 ` at character 1 as this format:
  base64-decodes and unpacks it, then checks the header's bit count
  against the count implied by the member headers (a free integrity
  check: a disagreement means something happened in transit).
- Also reads a raw dense9 file (no header, no base64) by detection, and
  byte8 archives as before.
- Writes a dense9 archive as a transfer file (header plus base64, 64
  columns, LF only), ready for `decode_base64` on Multics. The bit count is
  recomputed from the contents after any change.
- Extracts a binary component as a transfer file in the same format.

Possible later extension, not now: optional space-separated `key=value`
fields after the count, e.g. `sha256=`; a digest would be more useful than
a name, and a name would be untrusted input that must never be used as a
path. (The earlier RFC 822-style wrapper proposal is superseded by this
format.)

A `sha256=` field would catch corrupted octets, but not a wrong bit
count: see "Bit count ambiguity" below. The count needs its own check
(the archive's own structure, or the last-word test).

## Bit count ambiguity

Dense9 data without its bit count (a raw dense9 file, or a transfer body
whose header is lost) fixes only the octet count, `9 × ceil(B / 72)`: up
to 72 bit counts are consistent with the same octets.

**The digest cannot resolve it.** `sha256 -dense9` hashes the packed
octets, and SHA-256's padding encodes the message length in octets, which
is the same for every candidate. The whole hash input is identical, so
every candidate gives the same digest; there is nothing to search.
Checked: `abcdefgh` plus newline (81 bits, 18 octets) is consistent with
every count from 80 to 144 (65 counts), and all give `fabcb2c7…`. Even the
true count, 81, is not the lowest: bit 81 is the last bit of the newline,
which is zero. How wide the ambiguity is depends on the data.

**The octets narrow it.** If the final 72-bit group ends in k zero bits,
exactly k + 1 counts are possible, at most 72 (the count must reach the
last one bit);
if the group ends in a one bit, the count is exactly `72g`.

**Word-aligned data (an archive) nearly decides it.** B is `72g` or
`72g − 36`, and the second needs the last 36 bits to be zero. So if, of
the file's last nine octets, the low four bits of the fifth are nonzero,
or any of the sixth to ninth is, the word count is even and `B = 72g`.
Checked on 400 random word-aligned cases: every even-word case resolved,
and (correctly) no odd one. What is left is an even-word archive whose
last word is zero (the last component's word padding can make it so);
there the
member headers settle it, as Archive::Multics does when it reads a raw
dense9 archive: the archive's bit count is the sum of its members'.

For a raw dense9 *component* there is no such structure, which is why
`archive --bits N` requires the count (printed when the component is
extracted) and a transfer file records it. `--bits` checks the octet
count and warns about nonzero pad bits, but cannot tell a count that is
too low by some trailing zero bits.

(Where the hash input really does vary between candidates, SHA-256's
Merkle–Damgård structure helps: candidates sharing a prefix share the
chaining state, so hash the common prefix once and finish each candidate
from a copy of the state. With `secure_hash_` that is `$sha256_init` and
`$sha256_add` up to the point of divergence, a structure assignment to
copy `sha256_state`, then `$sha256_final` for each candidate. Not useful
here, since the inputs are identical.)

## Multics side: `convert_dense9_`

The dense9 packing is now a Multics subroutine, `convert_dense9_`, with
entry points `$pack` and `$unpack`. (Proposed earlier as
`multics_octets_`, with byte8 entries as well; byte8 needs no packer.)

- `encode_base64 -dense9` writes the transfer format above.
  `decode_base64` takes no new arguments: it recognizes the
  `-dense9 <bitcount>` header and decodes accordingly; without it, it
  decodes as before. Both use `convert_dense9_` for the packing.
- `secure_hash_` keeps its own dense9 packing and does not use
  `convert_dense9_`. Switching it (calling `convert_dense9_$pack` per
  block instead of calling out once per octet) was considered, but
  testing found no performance benefit, so it is not planned.
- `bit_to_hex` remains in `secure_hash_` (as would a `hex_to_bit` to go
  with it); a general-purpose home for them is still an open question.
- The rule shared by `convert_dense9_`, `secure_hash_` and
  Archive::Multics is the 72-bit padding. Test it: pack a segment with
  `convert_dense9_$pack`, hash it with `sha256 -dense9`, and compare; and
  compare both with Archive::Multics on the same segment.

## Detection (at open time)

- `archive_data_$ident` is `char (8) aligned`: 72 bits, exactly one dense9
  group. So the first header's ident is a fixed 8-octet string in byte8
  and a fixed 9-octet string in dense9. Compute the dense9 constant once;
  detection is two comparisons at offset 0, no heuristics.
- Check both, require exactly one to match; if neither, "not an archive"
  (unchanged, including for non-Multics files); if somehow both, fail
  rather than guess.
- A transfer file's `-dense9 N` header states the encoding; detection is
  then a consistency check (they must agree).
- Pre-filter for bare files: a dense9 file is a multiple of 9 octets; a
  byte8 archive (without the MIT trailer) a multiple of 4.
- Use `archive_data_$header_end` (the fence) for validation after the
  encoding is chosen, not for detection: at word offset 23 of the header
  it straddles two dense9 groups.
- Empty file: byte8 (an empty archive is the same either way).
- byte8 stays the default for anything that is not recognizably dense9.

## Processing

Unpack the whole file to a stream of 9-bit characters (in Perl, a string
of characters with ordinals 0-511). Header walking is then unchanged.
Additional validation in dense9: every header character must have its 9th
bit clear, and the fields must pass the existing checks.

Two separate properties of a component, both computed:

- **Safe as bytes**: bit count a multiple of 9 and every character below
  0o400. Extracting it as octets loses nothing. This is the gate for
  extracting as a plain file.
- **Text by intent**: decided by the name. `.pl1`, `.alm`, `.incl.pl1`,
  `.bind`, `.ec`, `.info`, `.list`, `.compout`, `.absin`, `.absout`, `.rd`
  and similar are text by construction. (Compiler listings in particular
  are for reading, not round-tripping.)

Report when they disagree: a `.pl1` component with a 9th bit set means
something is wrong; a component that is safe as bytes but has no text-like
name is extracted as bytes, but may not be text.

- A component that is not safe as bytes is extracted as a **wrapped dense9
  file** (name, bit count and digest in the header), with a message. It is
  then a complete, verifiable artifact that can go straight back to
  Multics with `decode_base64 -dense9`, rather than octets of ambiguous
  length. Never truncate 9-bit data silently.
- Writing: an archive read as dense9 is written back as dense9; unchanged
  components are copied bit for bit. Components added from Unix files are
  byte-to-character (9th bit zero), as today; a wrapped dense9 file added
  as a component goes in with its stated bit count.

## Crafted archives

- Bit counts: check against the remaining length before allocating or
  slicing (already done for byte8; apply the same to the unpacked stream).
- Trailing pad: after the last component, only the dense9 pad (fewer than
  72 bits, all zero) is allowed without `salvage`.
- Transfer header: one line, bounded length; the bit count must fit the
  payload exactly (`9 × ceil(bits / 72)` octets) and match the member
  headers.
- Component names: never use one as a file name without `safe_file_name`
  (0.04).
- Memory: unpacking enlarges the data in memory. Use a plausibility
  ceiling, not an exact rule. An archive is a single segment (the
  `archive` command and `archive_` both take one segment pointer and bit
  count), at most 255K words, about 1 million characters, and the
  transfer format's limit of 9,400,320 bits is exactly one segment.

## Footnote: multisegment files and dense9 digests

Archives are single segments, so this does not affect them, but it
bears on any future transfer of MSFs:

- A single `Bit-Count` cannot describe an MSF. If MSFs are ever wrapped
  as repeated blocks, one per component, the dense9 digest of the whole is
  **not** in general the digest of the concatenated parts: under dense9 each
  component is packed and padded to 72 bits on its own, so a component with
  an odd word count contributes 36 pad bits that the concatenated bit string
  does not have. Under byte8 the parts concatenate cleanly.
- The same issue exists on Multics today: `secure_hash_$sha256_file` hashes
  an MSF component by component with `absorb`, bypassing the rule that
  `$sha256_add` enforces (a call whose bit count is not a multiple of 72
  must be the last; a further call returns `error_table_$bad_arg`). So
  `sha256 -dense9` of an MSF with an odd-word-count component that is not
  the last one gives a digest that nothing else would compute. Planned fix
  (in the sha256 work): make `$sha256_file` apply the same rule and return
  `error_table_$bad_arg`, and correct `sha256.info`: `-byte8` digests of an
  MSF match the concatenation of its components; `-dense9` digests match
  only when every component but the last has an even word count.
- In practice MSF components other than the last are normally full
  (255K words, an even count), so the case needs a component that is not
  filled to its maximum length, but the digest must not depend on that.

## Command options (Archive::Multics)

- `--dense9` / `--byte8` (reading): force the encoding instead of detecting
  it; for testing, and to get a clear error when a file is not what it
  should be.
- `--dense9` when creating an archive: write it dense9. An existing archive
  keeps the encoding it was read in unless an option says otherwise.
- Write a dense9 archive as a transfer file by default; an option for a
  raw dense9 file.

## Testing

- Oracle: export the same text-only archive from Multics both ways. Both
  must decode to byte-identical components (the 9th bits are all zero).
- Digests: `sha256 -byte8` on Multics matches sha256 of the byte8 export;
  `sha256 -dense9` matches sha256 of the dense9 octets. Both must hold for
  the same archive.
- Binary: an archive containing an object segment, exported dense9,
  round-trips unchanged (read and write back, compare), and the object
  component extracts as a wrapped dense9 file whose digest matches
  `sha256 -dense9` of the segment on Multics.
- The checked example above as a fixed unit test.

## gzip on Multics (implemented 2026-09-27)

From the gzip/gunzip info segment:

- RFC 1952 gzip, one octet per 9-bit character (byte8-clean), so
  `encode_base64` carries it with no header, and sha256 of the .gz
  agrees on both systems.
- The octet derivation is chosen per file (`-byte8`/`-dense9` force it):
  BYTE8 if no 9th bit is set and the bit count is a multiple of 9 (so an
  archive of source is BYTE8); DENSE9 otherwise (a bound archive, an
  object segment). DENSE9 compresses about seven times worse on text.
- Bit count: under DENSE9 in FNAME, as `ENTRYNAME.BITCOUNT.dense9`;
  under BYTE8, FNAME is the entry name and the bit count is 9 × octets.
  No FEXTRA is written (Apple's gunzip mishandles FEXTRA with FNAME).
  gunzip looks for the bit count in an `MU` extra subfield, then in
  FNAME, and otherwise takes 9 × octets. It does not use FNAME to name
  its output.
- The `MU` subfield (read by gunzip, not written by gzip), an ordinary
  RFC 1952 subfield, all little-endian: `'M' 'U'`, data length (2 octets,
  6), version (1), derivation (0 = BYTE8, 1 = DENSE9), bit count (4
  octets). Readers accept a data length of 6 or more and use the first
  six octets, and walk the subfields (offset += 4 + length) rather than
  assuming MU is first. Example header, 81 bits, name `test.81.dense9`:
  `1f 8b 08 0c 00 00 00 00 00 ff 0a 00 4d 55 06 00 01 01 51 00 00 00`.
- MTIME: date-time contents modified (Unix seconds; 0 if unavailable).
  OS: 255.
- One member only; input and output must each fit in one segment; gzip
  input at most 900,000 octets. Do not recompress: a DENSE9 payload that
  loses its FNAME can only be recovered if it is self-delimiting, as an
  archive is.
- Transfer: `gzip X.archive` then `encode_base64 X.archive.gz F.b64`;
  on Unix, `base64 -d` and `gunzip -N` (which restores the name with the
  bit count).

Archive::Multics (0.06) reads and writes this format: every key reads
a gzipped archive (bit count from MU, else the stored name, checked
against the octet count and the member headers), and a change is written
back gzipped; `--gzip` makes `NAME.archive.gz`, or with `--export` a
gzip file; `--import` also takes a gzip file or base64 of one; a name
`NAME.archive.BITCOUNT.dense9` (from `gunzip -N`) is read as it is but
not changed. Writing follows the Multics rule and stored name, with no
extra field and OS code 3 (Unix: the system the file was made on;
Multics writes 255, as RFC 1952 has no code for it, and the two values
show which end made a file). Decompression stops at one segment; one
member only; a gzip inside a gzip is refused; the stored name is never
a path. `archive --name-bits` uses the same `NAME.BITCOUNT.dense9` name
for raw binary components: `x` writes them so, and `r`/`a`/`u` take
the bit count from it.

## Open questions

- Pad-bit requirement in `$unpack` (zero?).
- Which names count as text by intent (the list above is a start).
