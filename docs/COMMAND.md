# archive command specification

Specification for the Perl `archive` command (`bin/archive`), derived
from the MR12.8 source of `bound_archive_` and checked against Multics
output. The user manual is the command's POD (`perldoc bin/archive`,
installed as archive(1)).

## Key table (`archive_key_.alm`)

28 keys, matched exactly; longer than 4 characters is "Unrecognized key".

Each entry is two words: `aci` key (4 chars), then an 18-bit field
`type (2)` + 16 flag bits, left-justified in word 2.

| Flag | Octal | Meaning |
|---|---|---|
| update | 100000 | replace only if the source's dtcm is later than the component's (compared at 0.1-minute resolution via the header text) |
| append | 40000 | add; a component already present is kept and reported |
| copy | 20000 | write the updated archive to the working directory, leaving the original untouched; error if the archive is already in the working directory |
| del | 10000 | replace keys: delete sources afterwards; extract: delete extracted components from the archive |
| force | 4000 | no query: `dl_handler_$noquestion` when deleting sources; for extract, delete an existing entry at the destination without asking |
| long | 2000 | long table listing |
| zarg | 1000 | no component names given means "all" |
| star | 400 | star names allowed in component names |
| empty | 200 | archive may be empty |
| norig | 100 | archive need not exist (created) |
| brief | 40 | brief table listing |

| Key | Type | update | append | copy | del | force | long | zarg | star | empty | norig | brief |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `r` | replace | | | | | | | ✓ | | ✓ | ✓ | |
| `rd` | replace | | | | ✓ | | | ✓ | | ✓ | ✓ | |
| `rdf` | replace | | | | ✓ | ✓ | | ✓ | | ✓ | ✓ | |
| `cr` | replace | | | ✓ | | | | ✓ | | ✓ | ✓ | |
| `crd` | replace | | | ✓ | ✓ | | | ✓ | | ✓ | ✓ | |
| `crdf` | replace | | | ✓ | ✓ | ✓ | | ✓ | | ✓ | ✓ | |
| `u` | replace | ✓ | | | | | | ✓ | | | | |
| `ud` | replace | ✓ | | | ✓ | | | ✓ | | | | |
| `udf` | replace | ✓ | | | ✓ | ✓ | | ✓ | | | | |
| `cu` | replace | ✓ | | ✓ | | | | ✓ | | | | |
| `cud` | replace | ✓ | | ✓ | ✓ | | | ✓ | | | | |
| `cudf` | replace | ✓ | | ✓ | ✓ | ✓ | | ✓ | | | | |
| `a` | replace | | ✓ | | | | | | | ✓ | ✓ | |
| `ad` | replace | | ✓ | | ✓ | | | | | ✓ | ✓ | |
| `adf` | replace | | ✓ | | ✓ | ✓ | | | | ✓ | ✓ | |
| `ca` | replace | | ✓ | ✓ | | | | | | ✓ | ✓ | |
| `cad` | replace | | ✓ | ✓ | ✓ | | | | | ✓ | ✓ | |
| `cadf` | replace | | ✓ | ✓ | ✓ | ✓ | | | | ✓ | ✓ | |
| `d` | delete | | | | | | | | | | | |
| `cd` | delete | | | ✓ | | | | | | | | |
| `x` | extract | | | | | | | ✓ | ✓ | | | |
| `xd` | extract | | | | ✓ | | | ✓ | ✓ | | | |
| `xdf` | extract | | | | ✓ | ✓ | | ✓ | ✓ | | | |
| `xf` | extract | | | | | ✓ | | ✓ | ✓ | | | |
| `t` | table | | | | | | | ✓ | ✓ | | | |
| `tl` | table | | | | | | ✓ | ✓ | ✓ | | | |
| `tb` | table | | | | | | | ✓ | ✓ | | | ✓ |
| `tlb` | table | | | | | | ✓ | ✓ | ✓ | | | ✓ |

Observations:
- `d`/`cd` require component names (no `zarg`) and don't allow star
  names; `a` keys require names.
- `u` keys require an existing, nonempty archive; `r` and `a` keys will
  create one.
- Only `tlb` is accepted, not `tbl`: keys are matched exactly; longer
  than 4 chars is "Unrecognized key".
- Star names are allowed only in the archive pathname, only for `t` and
  `x` keys; component names never take star or equal names.

## Behavior (from archive.pl1)

**Argument handling**
- `archive key archive_path {paths}`; `.archive` added if missing.
- For `t`/`d`, paths are component names; otherwise pathnames (dir part
  = source or destination directory).
- Duplicate component names in the arguments: "Duplicated request for
  this component." and the duplicate is skipped.
- If arguments were given but all were invalid, nothing is done (no
  fallback to "all").

**Ordering**
- Replaced components keep their position; new ones are appended at
  the end, in argument order.

**Global replace/update (no paths)**
- Candidates are the archive's components; a component is replaced if
  an entry of the same name exists in the working directory (links
  chased). Working-directory entries not already in the archive are
  not added.

**Sources**
- Must be readable; links chased; header `time` from the source's dtcm,
  `mode` from the user's effective mode.
- A source whose records exceed its bit count is refused ("Bit count is
  inconsistent with current length").
- The archive itself can't be a source.

**Extract**
- Destination is the path's directory, or the working directory if no
  paths. Mode from header; blank mode means `rw`.
- Existing destination: query (`nd_handler_`) unless `f`.
- `xd`: components extracted successfully are removed; failures kept.

**Updating in place**
- The new archive is built in a temp, then copied over the original, so
  the original's names and ACL are preserved. If the user lacks `w`,
  asks "Do you want to update the protected segment …?"
- Growth is tested for quota first; on overflow the original is left
  intact and the updated copy kept in the process directory.

**Table output** (via `ioa_`)
- Title: blank line, tab, archive pathname, blank line.
- Headings, long: ` name^3-      updated      mode^-modified^-   length`
  then blank line; short: `  updated^2-   name` then blank line.
- Rows, long: `^32a^17a^5a^16a^a` (name, timeup, mode, time, bit count
  text); short: `^20a^a` (timeup, name).
- `b` suppresses title and headings. A blank line always ends the table.
- Fields are printed raw from the header.

**Messages** (prefix `archive: ` via `com_err_`)
- `<name> not found in <archive>`
- `Could not append <path> to <archive>` / `Could not replace <path> in <archive>`
- `Did not append <name> because copy found in <archive>`
- `Did not update <name> because latest copy already in <archive>`
- `archive: <path> appended to <archive>` (continuation lines indented 9)
- `archive: <name> updated in <archive>` (global update)
- `archive: Creating <archive>` / `archive: Copying <archive>`
- `archive: All components of <archive> have been deleted.`
- `<archive> is empty.`, `Format error in <archive>`
- `Some component names must be specified with this key - <key>`
- `Star convention cannot be used with this key.  <key>`
- `Attempt to copy onto original.  <archive>`
- `Archive segment overflow. Could not <act> <path> in <archive>`
- `No matching segments…; no components were updated…` /
  `Archive <archive> contains the latest versions; …`

## Differences from Multics (deliberate)

| Area | Multics | Perl `archive` | Consequence |
|---|---|---|---|
| Updating an archive | New contents copied over the original segment in place | New archive written to a temp file in the same directory, then `rename`d over the original; mode and owner preserved | A failure never damages the original. Hard links to the archive are broken (the name points to a new file; other links keep the old contents). |
| Protected archive | Query, temporary ACL entry, restored afterwards | Same query; the new file replaces the old by rename and keeps its read-only mode, so no permission change is needed | Needs write permission on the directory, as any rename does. |
| Extract onto a symbolic link | Deletes the link's target and writes through the link (F45) | Replaces the link itself | Target left alone. |
| Extract: mtime | Set to time of extraction (dtcm can't be set) | Set from the component's `time` field, like tar | `u` behaves as expected after an extract/edit/update round trip. |
| Extract: permissions | ACL for Person.Project.* from the stored `r`/`e`/`w` | `r`/`w`/`e` → read/write/execute bits, filtered by umask; blank mode → `rw` | |
| Add/replace: mode | The user's effective mode on the source (`hcs_$fs_get_mode`) | The file's owner permission bits | Same answer for an ordinary owner; for root, effective access would always include `w`. An extract/replace round trip keeps the mode (under any umask that leaves owner bits alone). |
| `rd`/`ud` with a symlinked source | Deletes the link's target | Removes the symlink itself (Unix convention) | Target file is left alone. |
| Concurrent use | Per-process `archive_data_$active` query | Exclusive `flock` on the archive while updating | Two processes can't interleave updates. |
| Table layout | `ioa_` tabs, Multics tab stops every 10 columns | Tabs expanded to spaces at Multics 10-column stops, so output matches `ac t` / `ac tl` character for character on any terminal (test fixtures: `t/data/tests.ac_t*.txt`) | |
| Bit count column in `tl` | Header field printed raw (left-justified counts run into the date, F52) | Printed right-justified, as Multics writes it | Identical for every archive Multics writes. |
| Dates across 2030 (F53) | Two-digit years read with cutoff 30 (30-99 = 19yy), so `u` breaks across 2029/2030 | Cutoff 50, as RFC 5322 section 4.3 and the proposed Multics fix (`-P 30` for MR12.8 behavior, `-P window` for a rolling window) | Identical to Multics for every date before 2030; correct until 2050. |
| Star names in archive path | Expanded by the command | Shell expands unquoted globs; a quoted Multics star name is expanded by the command in Multics order; warning if a component argument names an existing `*.archive` file | |

## Perl implementation

The key table is carried over as data, one entry per key with the same
flags, so the command's dispatch is driven by the same table as on
Multics.

Status (2026-09-22): implemented in `bin/archive`, all 28 keys. Tests in
`t/10-command.t`: `t` and `tl` output is identical to `ac t` / `ac tl`
on Multics apart from the pathname; messages follow `archive.pl1`.

Reading: the command reads with `validate => 'basic'`, like
`archive_util_`, so archives with bad mode or date fields list as they do
on Multics, but it requires `archive_data_$ident` and `$fence` in every
header (F47 not reproduced).

Messages that differ from Multics:
- "No matching segments in DIR" / "... no components were updated from
  DIR" name the working directory, where the sources are; Multics names
  the archive's directory (FINDINGS F54).
- With copy keys, "appended to" names the new copy; Multics names the
  unchanged original (F55).
- Errors for unreadable or unwritable files use Multics wording for the
  common cases ("Entry not found.", "Incorrect access on entry.",
  "Name duplication.") and the system's message otherwise.
- Queries say "file" where Multics says "segment".

## Packaging and OpenBSD sandboxing (2026-09-22)

- One package, `p5-Archive-Multics` (port `archivers/p5-Archive-Multics`):
  the module in `${P5SITE}` (`/usr/local/libdata/perl5/site_perl`) and
  `archive` in `/usr/local/bin`, with archive(1) and
  Archive::Multics(3p). Standard MakeMaker layout, so other installers
  (macOS, Linux) use the same `Makefile.PL`.
- On OpenBSD (`$^O eq 'openbsd'`) the command calls `unveil` and `pledge`
  after parsing arguments; the module does not, but documents what a
  caller must allow (POD section "OPENBSD PLEDGE AND UNVEIL").
  - Unveiled: `@INC` and time zone files (r); the archive directory (r,
    or rwc when the archive is rewritten in place); the working
    directory (r, plus wc for copies, extraction with no paths and global
    `rd`/`ud`); named source directories (r, rc for `d` keys, plus the
    target directory of a symlinked source); extraction destinations (rwc).
  - Pledged: `stdio rpath`; `wpath cpath fattr` for keys that write
    files; `flock` for keys that rewrite the archive.
  - `t/11-sandbox.t` checks the unveil/pledge sets with stand-in modules;
    the real calls run only on OpenBSD (`t/10-command.t` there).
