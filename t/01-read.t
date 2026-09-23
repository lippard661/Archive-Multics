use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

my $data = "$FindBin::Bin/data";
my $TZ   = 'America/Phoenix';

# tests.archive was written by tools/gen_test_archives.pl and verified on
# Multics MR12.8 (2026-09-22): ac t / ac tl listed it, and the
# byte8 SHA-256 matched.
my $ar = Archive::Multics->new(tz => $TZ);
ok $ar->read("$data/tests.archive"), 'read tests.archive' or diag $ar->error;

my @names = $ar->component_names;
is_deeply \@names, [qw(arctest.ec double.ec archive_test.pl1 seed.txt
    t_baddate.archive t_badmode.archive t_bigbc.archive t_leftbc.archive
    t_longname.archive t_nofence.archive t_obsolete.archive t_ok.archive
    t_trailing.archive t_unaligned.archive)], 'component names in order';

# Bit counts as shown by ac tl on Multics.
my %bc = map { $_->name => $_->bit_count } $ar->list_components;
is $bc{'arctest.ec'},          37413, 'arctest.ec bit count';
is $bc{'archive_test.pl1'},    62604, 'archive_test.pl1 bit count';
is $bc{'t_unaligned.archive'}, 2493,  't_unaligned bit count';

my $c = $ar->get_component('seed.txt');
ok $c, 'get_component';
is $c->size, 288, 'size in characters';
is $c->length, 72, 'length in words';
is $c->access, 'rw', 'access';
ok $c->readable && $c->writable && !$c->executable, 'access bits';
is $c->time_updated_string, '09/22/26  1639.0', 'raw updated field';

is $ar->as_string, do { local (@ARGV, $/) = "$data/tests.archive"; <> },
    'unchanged archive round-trips byte for byte';

ok !$ar->get_component('nonesuch'), 'missing component';
is $ar->error_code, 'no_component', '... no_component';

ok !$ar->get_component('x' x 33), 'name longer than 32';
is $ar->error_code, 'entlong', '... entlong (not truncated)';

# next_component iteration.
my @it;
for (my $p = $ar->next_component; $p; $p = $ar->next_component($p)) { push @it, $p->name }
is_deeply \@it, \@names, 'next_component walks the archive';

# Dates: 09/22/26 16:39.0 Phoenix = 23:39 UTC.
is $c->time_updated, 1790120340, 'time_updated in Phoenix';
is $c->time_modified, 1790119800, 'time_modified in Phoenix';
my $utc = Archive::Multics->new(tz => 'UTC', file => "$data/tests.archive");
is $utc->get_component('seed.txt')->time_updated, 1790095140, 'same field read as UTC';
is $c->multics_time_updated, (1790120340 + 2177452800) * 1_000_000, 'Multics clock';

# Century rule, checked against convert_date_to_binary_ on MR12.8
# (Phoenix time, 2026-09-22): raw clock values from cdtb_test.
my $p = Archive::Multics->new(tz => 'America/Phoenix', century_pivot => 30);
for (["01/01/25  0000.0", 3913167600000000], ["01/01/49  0000.0", 1514790000000000],
     ["01/01/50  0000.0", 1546326000000000], ["01/01/69  0000.0", 2145942000000000],
     ["01/01/70  0000.0", 2177478000000000], ["01/01/99  0000.0", 3092626800000000],
     ["01/01/20  0000.0", 3755314800000000], ["01/01/26  0000.0", 3944703600000000],
     ["01/01/27  0000.0", 3976239600000000], ["01/01/29  0000.0", 4039398000000000],
     ["01/01/30  0000.0",  915174000000000], ["01/01/40  0000.0", 1230706800000000]) {
    is Archive::Multics::unix_to_multics_clock($p->_parse_date($_->[0])), $_->[1], "$_->[0] as Multics reads it";
}

# Default: RFC 5322 section 4.3 (00-49 = 20yy, 50-99 = 19yy).
my $rfc = Archive::Multics->new(tz => 'UTC');
is $rfc->_year($_->[0]), $_->[1], "RFC 5322: $_->[0] -> $_->[1]"
    for [0, 2000], [29, 2029], [30, 2030], [49, 2049], [50, 1950], [69, 1969], [99, 1999];

# Optional window rule.
my $w26 = Archive::Multics->new(tz => 'UTC', century_pivot => 'window', now => 1790095140);   # 2026-09-22
my $w31 = Archive::Multics->new(tz => 'UTC', century_pivot => 'window', now => 1940716800);   # 2031-07-01
is $w26->_year($_->[0]), $_->[1], "2026 window: $_->[0] -> $_->[1]"
    for [25, 2025], [27, 2027], [28, 1928], [30, 1930], [69, 1969], [99, 1999];
is $w31->_year($_->[0]), $_->[1], "2031 window: $_->[0] -> $_->[1]"
    for [29, 2029], [30, 2030], [32, 2032], [33, 1933], [70, 1970];

# Empty archive.
my $e = Archive::Multics->new;
ok $e->read_string(''), 'empty archive is valid';
is scalar($e->list_components), 0, '... no components';

done_testing;
