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
| 44     | 16  | `timeup`       | first 16 chars of `date_time_ (clock_ ())` when archived; or `yyyymmddThhmmssZ` (experimental, see below) | chars in `0123456789 ./`; parsed by `convert_date_to_binary_` (info entries only) |
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
  `archive_`. Before MCR10177 (MR12.9), `archive_util_` accepted the
  obsolete `header_begin`, never checked `fence`, and did not validate
  the bit count; it now checks headers as `archive_` does. The Perl
  module follows `archive_`, and so does the Perl `archive` command.

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
  `Archive::Multics` defaults to cutoff 71 (years 1971-2070), the rule
  of MCR10207 (before 0.10, 50, as RFC 5322 section 4.3);
  `century_pivot => 30` reproduces MR12.8. Raw clock values from
  `convert_date_to_binary_` match `unix_seconds` conversion exactly. `Archive::Multics` writes
  tenths of a minute truncated (seconds / 6, rounded down), as Multics
  does: `date_time_$format` with `^99v.9MH` truncates (checked on
  MR12.9, 2026-11-24, with seconds 10, 23, 34 and 47).
- Experimental ISO dates (MCR10207, for MR12.10; not in any release): the
  experimental `archive_` and `archive` write both dates as
  `yyyymmddThhmmssZ`, in GMT, truncated to the second, in the same
  16-character fields; both pads stay blank, and nothing else in the
  header changes. Each date field is recognized by its own form, so an
  archive may mix the two. A new header takes the form of the archive's
  first component (`archive_$set_header_times` is given that header as a
  model), so an existing archive keeps its form and only a new or empty
  one gets ISO dates. Original-form dates are read in the reader's zone,
  as before, with the year taken to lie in 1971-2070. Released
  `archive_` rejects `T` and `Z` with `archive_fmt_err`, so `::`
  pathnames, the compilers, `print` and the library tools cannot use an
  ISO archive; the released `archive` command (`archive_util_`) lists it
  with the dates raw, and its `u` cannot parse them and so replaces
  every component it is given. `Archive::Multics` reads both forms, and
  writes ISO dates for a new archive with `date_form => 'iso'`
  (`archive --experimental`). Neither the experimental `archive` nor
  `Archive::Multics` converts an existing archive by itself:
  `convert_archive` on Multics converts the dates of whole archives in
  either direction, with a zone per archive or per component, and
  `convert_dates` (`archive --exl --convert utc|original`) does the
  same here for one archive in one zone. Only the two date fields
  change.
- The experimental `u`: a header date is truncated (to the second, or
  to the tenth of a minute), so it may be up to 6 seconds early. A source
  dated before the component's "modified" date is not newer; 6 seconds
  or more after, it is. In between it is not newer if the component was
  archived ("updated") 6 seconds or more after its "modified" date, and
  otherwise it is newer if its bit count or contents differ.
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
- A requested name longer than 32 chars was silently truncated before
  comparison by `archive_` before MCR10177 (MR12.9), which returns
  `no_component` for it instead; the Perl module rejects such names
  (`entlong`).
- Duplicate names: the first match wins.

## Error codes (`archive_`)

| Code | When |
|---|---|
| `not_archive` | bit count not word-aligned; nonzero but < 25 words; first header lacks `ident` or `fence` |
| `archive_fmt_err` | any later header problem; component extends past end; trailing partial data; bad mode/date (info entries) |
| `no_component` | name not found |
| `bad_arg` | `next_component*` given a pointer outside the archive, before the first component, or not word-aligned; from MCR10177 (MR12.9), also one that does not follow a header (before, `archive_fmt_err`) |
| `unimplemented_version` | info structure version is not 1 |

## Component data

- Length in characters = `bit_count / 9`. A bit count not divisible by 9
  cannot be represented in text mode; the module refuses such
  components.
- Object segments and other binary data have bit counts that are
  multiples of 36, so they pass that check, but their 9th bits do not
  survive a text-mode transfer. Nothing in the archive records this.
- `comp_lth` (words) = ceil(bit_count / 36).

## Times

`archive_component_info` times are Multics clock values: `fixed bin
(71)` microseconds since 1901-01-01 00:00 GMT.

    unix_seconds = multics_clock / 1_000_000 - 2_177_452_800

## Access (`archive_component_info.access`)

`bit (36)`; bit 1 = r, bit 2 = e, bit 3 = w. Others zero.

## Archives from the MIT Multics source site

Downloads of `*.archive` segments from the MIT Multics source web site
are valid text-mode archives followed by Bull's copyright notice, added
as a pseudo-component that is not a valid component: the header has DOS
line endings (a carriage return before each line feed) and no
`archive_data_$ident` or `$fence`, the name is
`bull_copyright_notice.txt`, the bit count is zero-filled (`00020025`),
and the text has CRLF line endings. Multics itself would report a format
error after the last real component. `Archive::Multics` recognizes the
notice, ignores it with a warning, and does not write it back.

## Damaged transfers

Transfers that drop NUL bytes remove the padding after components whose
length is not a multiple of four characters, so later headers are no
longer where the bit counts say. With `salvage => 1` (`archive -S`),
such components are recognized and the padding restored.
