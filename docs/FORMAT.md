# Multics Archive Format (text mode)

The format of Multics archive segments as used by `Archive::Multics`,
derived from the MR12.8 source of `bound_archive_` (`archive_header.incl.pl1`,
`archive_component_info.incl.pl1`, `archive_data_.alm`, `archive_.pl1`,
`archive_util_.pl1`, `archive.pl1`) and checked against Multics.

**Verified on Multics MR12.8 (2026-09-22):** an archive written
from this spec (`t/data/tests.archive`) was listed by `ac t` and `ac tl`
without error, and its byte8 SHA-256 matched after a base64 transfer.

## Representation

Multics characters are 9 bits. In text mode each Multics character maps
to one 8-bit byte; the 9th bit is discarded. Archive headers are pure
7-bit ASCII, so headers always survive text-mode transfer. Components
survive only if they contain no characters >= 0o400.

Recommended transfer: base64 (`encode_base64` / `decode_base64`).
Print-and-paste through a terminal will lose the SI (0x0F) characters in
every header.

## Overall structure

An archive is a sequence of zero or more entries, each:

    header (25 words = 100 chars) | component data | pad to word boundary

- The archive bit count must be a multiple of 36, i.e. the text-mode
  file length must be a multiple of 4 bytes. Otherwise: `not_archive`.
- A zero-length archive is valid and has no components.
- A nonzero archive shorter than one header: `not_archive`.
- Each component occupies `ceil(bit_count / 36)` words
  (`ceil(bit_count / 9 / 4) * 4` chars in text mode); the next header
  starts immediately after.
- The archive ends exactly at the end of the last component's padding.
  Any trailing words after that: `archive_fmt_err`.
- Padding after component data is zero bits (`mask.kill = ""b`), so in
  text mode the pad bytes are NUL (`\0`).

## Header (`archive_header.incl.pl1`)

| Offset | Len | Field          | Content | Read-side check |
|-------:|----:|----------------|---------|-----------------|
| 0      | 8   | `header_begin` | `ident` | must equal `ident` |
| 8      | 4   | `pad1`         | 4 blanks | none |
| 12     | 32  | `name`         | component name, blank-padded | none |
| 44     | 16  | `timeup`       | first 16 chars of `date_time_ (clock_ ())` when archived | chars in `0123456789 ./`; parsed by `convert_date_to_binary_` (info entries only) |
| 60     | 4   | `mode`         | positional: `r`/` `, `e`/` `, `w`/` `, ` `/`a` | chars in `rewa `; positions checked by info entries only |
| 64     | 16  | `time`         | first 16 chars of `date_time_$fstime` of the source's dtcm | as `timeup` |
| 80     | 4   | `pad`          | 4 blanks | none |
| 84     | 8   | `bit_count`    | `picture "zzzzzzz9"`: right-justified, blank-filled (Perl `%8d`); left-justified accepted on read | nonblank; after trimming, digits only |
| 92     | 8   | `header_end`   | `fence` | must equal `fence` |

Writer (`archive.pl1`, `rcmp`):
- `mode` is the writer's effective mode on the source segment: `r`, `e`,
  `w` in positions 1–3 (blank if absent), position 4 always blank.
- A blank `mode` field (legacy) is extracted as `rw`.
- Unmodified components are copied header and all, byte for byte
  (`ccmp`), so odd legacy headers survive updates. The Perl writer does
  the same: only new or replaced components get freshly generated
  headers.
- The `archive` command reads archives with `archive_util_`, not
  `archive_`, which accepts obsolete `header_begin` and never checks
  `fence`. The Perl module follows `archive_`, and so does the Perl
  `archive` command.

Notes:
- The `a` in position 4 is an obsolete append-mode flag; accepted, ignored.
- Dates contain no zone: the writer truncates `date_time_` output
  (`mm/dd/yy  hhmm.m zzz www`) to 16 chars, dropping zone and weekday.
  `convert_date_to_binary_` interprets them in the *reader's* default
  zone. Century rule for the 2-digit year, observed on MR12.8 in 2026:
  00-29 are 20yy, 30-99 are 19yy (tested 20, 25, 26, 27, 29, 30, 40, 49,
  50, 69, 70, 99). Confirmed from source: `convert_date_to_binary_`
  (`CONVERT_TO_4_DIGIT_YEAR`) uses a fixed cutoff, 00-29 = 2000-2029 and
  30-99 = 1930-1999, so from 2030 Multics misreads the dates it writes.
  `Archive::Multics` defaults to cutoff 50 (RFC 5322 section 4.3), the
  proposed Multics fix; `century_pivot => 30` reproduces MR12.8. Raw clock values from
  `convert_date_to_binary_` match `unix_seconds` conversion exactly. `Archive::Multics` writes
  tenths of a minute truncated (seconds / 6, rounded down); whether
  Multics `date_time_` truncates or rounds has not been checked, and would
  only affect the last digit.
- Validation is split: the pointer entries (`get_component`,
  `next_component`) check only character sets; the info entries
  (`*_info`, `list_components`) also check mode positions and parse
  dates.

## Constants (`archive_data_.alm`)

| Constant | Octal (9-bit) | Chars |
|---|---|---|
| `ident` | `014 012 012 012 017 012 011 011` | FF LF LF LF SI LF HT HT |
| `fence` (= `header_end`, same location) | `017 017 017 017 012 012 012 012` | SI SI SI SI LF LF LF LF |
| `header_begin` (obsolete, never written) | `013 012 012 012 017 012 011 011` | VT LF LF LF SI LF HT HT |

    IDENT        = "\f\n\n\n\x0F\n\t\t"
    FENCE        = "\x0F\x0F\x0F\x0F\n\n\n\n"
    HEADER_BEGIN = "\x0B\n\n\n\x0F\n\t\t"   # obsolete; not recognized

An obsolete-format archive gets no special diagnostic: `not_archive` if
the first header is affected, `archive_fmt_err` otherwise. The Perl
module mirrors this.

## Lookup semantics (`archive_`)

- Names compare as `char (32)`: exact, case-sensitive, trailing blanks
  insignificant.
- A requested name longer than 32 chars is silently truncated before
  comparison by `archive_`; the Perl module rejects such names instead.
- Duplicate names: the first match wins.

## Error codes (`archive_`)

| Code | When |
|---|---|
| `not_archive` | bit count not word-aligned; nonzero but < 25 words; first header lacks `ident` or `fence` |
| `archive_fmt_err` | any later header problem; component extends past end; trailing partial data; bad mode/date (info entries) |
| `no_component` | name not found |
| `bad_arg` | `next_component*` given a pointer outside the archive, before the first component, or not word-aligned |
| `unimplemented_version` | info structure version is not 1 |

## Component data

- Length in characters = `bit_count / 9`. A bit count not divisible by 9
  cannot be represented in text mode; the module refuses such
  components.
- `comp_lth` (words) = ceil(bit_count / 36).

## Times

`archive_component_info` times are Multics clock values: `fixed bin
(71)` microseconds since 1901-01-01 00:00 GMT.

    unix_seconds = multics_clock / 1_000_000 - 2_177_452_800

## Access (`archive_component_info.access`)

`bit (36)`; bit 1 = r, bit 2 = e, bit 3 = w. Others zero.
