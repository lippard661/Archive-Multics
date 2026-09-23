# Archive::Multics

Archive::Multics is a Perl module for reading and writing Multics archive
segments, the format of the Multics `archive` command, together with
`archive`, a Unix version of that command. It works on archives moved
between Multics and Unix in text mode (one byte per 9-bit Multics
character), for example with `encode_base64` and `decode_base64`.

Archives read and written without changes come out byte for byte
identical, and the command's keys, messages and table layout follow
`archive` on Multics MR12.8, so `archive tl` on Unix prints what `ac tl`
prints on Multics.

## OpenBSD installation

The OpenBSD package is `p5-Archive-Multics-0.02.tgz`:

    pkg_add ./p5-Archive-Multics-0.02.tgz

It installs the module, `/usr/local/bin/archive`, and the manual pages
archive(1) and Archive::Multics(3p). The package is architecture
independent; on other platforms it can be installed with `install.pl`
from the distribute repository.

## Standard installation

    perl Makefile.PL
    make
    make test
    make install

## Usage

The command takes a Multics key, an archive path (`.archive` is added if
missing) and component paths:

    archive t  bound_foo_.s        # table of contents
    archive tl bound_foo_.s        # long form
    archive x  bound_foo_.s foo.pl1
    archive u  bound_foo_.s        # replace components with newer files
    archive a  new foo.pl1 bar.pl1 # create an archive

All the Multics keys are supported: `t tl tb tlb`, `a ad adf ca cad cadf`,
`r rd rdf cr crd crdf`, `u ud udf cu cud cudf`, `d cd`, `x xd xdf xf`.
Quoted star names (`archive t '*'`) follow Multics star rules. See
`archive(1)` for details, options and the differences from Multics.

From Perl:

    use Archive::Multics;

    my $ar = Archive::Multics->new(tz => 'America/Phoenix');
    $ar->read('bound_foo_.s.archive') or die $ar->error;
    for my $c ($ar->list_components) {
        printf "%-32s %8d\n", $c->name, $c->bit_count;
    }
    print $ar->get_component('foo.pl1')->data;
    $ar->add_file('bar.pl1', action => 'update');
    $ar->write or die $ar->error;

## Notes

- Header dates carry no time zone. They are read and written in the local
  zone unless another is given (`-z`, `tz`); use the zone of the Multics
  site that wrote the archive.
- Two-digit years: 00-49 are 20yy and 50-99 are 19yy (RFC 5322). Multics
  MR12.8 uses 30 as the cutoff, and so misreads dates from 2030 on;
  `-P 30` reproduces it.
- Only text-mode archives are supported. Components whose bit count is
  not a multiple of 9 (such as object segments) are preserved but cannot
  be extracted.
- Archives downloaded from the MIT Multics source site end with Bull's
  copyright notice, appended as a malformed extra component. It is
  recognized, ignored with a warning, and left out of anything written.
- `-S` (`--salvage`) reads damaged archives as far as possible, for
  example ones whose padding NUL bytes were lost in transfer.
- There is no `ac` short name, since `ac` is the login accounting
  command, ac(8), on OpenBSD.
- On OpenBSD, `archive` runs under pledge(2) and unveil(2).

The archive format is described in `docs/FORMAT.md`.

## Requirements

Perl 5.10 or later; core modules only.

## License

BSD 3-Clause; see the LICENSE file.

## Author

Jim Lippard directing Claude Opus 5.5.
