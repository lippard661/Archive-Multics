use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# The crafted archives are components of tests.archive. Expected results
# follow the Multics archive_ subroutine (MR12.8); "full" and "basic" differ
# only where archive_'s info entries and pointer entries differ.
my $outer = Archive::Multics->new(tz => 'UTC', file => "$FindBin::Bin/data/tests.archive")
    or die $Archive::Multics::error;
sub crafted { $outer->get_component("$_[0].archive")->data }

my @cases = (
    # name          full               basic              components (if ok)
    [ t_ok        => undef,            undef,             2 ],
    [ t_leftbc    => undef,            undef,             2 ],
    [ t_badmode   => 'archive_fmt_err', undef,            2 ],
    [ t_baddate   => 'archive_fmt_err', undef,            2 ],
    [ t_bigbc     => 'archive_fmt_err', 'archive_fmt_err' ],
    [ t_trailing  => 'archive_fmt_err', 'archive_fmt_err' ],
    [ t_unaligned => 'not_archive',     'not_archive'     ],
    [ t_obsolete  => 'not_archive',     'not_archive'     ],
    [ t_nofence   => 'archive_fmt_err', 'archive_fmt_err' ],
    [ t_longname  => undef,            undef,             2 ],
);

for my $case (@cases) {
    my ($name, $full, $basic, $n) = @$case;
    for ([full => $full], [basic => $basic]) {
        my ($level, $want) = @$_;
        my $ar = Archive::Multics->new(tz => 'UTC', validate => $level);
        my $ok = $ar->read_string(crafted($name));
        if (defined $want) {
            ok !$ok, "$name ($level) rejected";
            is $ar->error_code, $want, "$name ($level) $want";
        }
        else {
            ok $ok, "$name ($level) accepted" or diag $ar->error;
            is scalar($ar->list_components), $n, "$name ($level) $n components";
        }
    }
}

# t_leftbc: left-justified bit count parses to the same value.
my $l = Archive::Multics->new(tz => 'UTC');
$l->read_string(crafted('t_leftbc'));
is $l->get_component('alpha')->bit_count, 225, 'left-justified bit count';
is $l->as_string, crafted('t_leftbc'), '... and its header is preserved verbatim';

# t_longname: the 32-character name is found by its full name only.
my $n = Archive::Multics->new(tz => 'UTC');
$n->read_string(crafted('t_longname'));
ok $n->get_component('abcdefghijklmnopqrstuvwxyz012345'), '32-char name found';
ok !$n->get_component('abcdefghijklmnopqrstuvwxyz0123456789'), '36-char name not truncated to 32';
ok !$n->delete_component('abcdefghijklmnopqrstuvwxyz0123456789'), '... nor deleted';
is scalar($n->list_components), 2, '... both components remain';

# Error messages say where.
my $b = Archive::Multics->new;
$b->read_string(crafted('t_badmode'));
like $b->error, qr/Component 2 .*\(beta\) Mode field "wer "/, 'error names the component';

done_testing;
