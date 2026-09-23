use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

my $ROOT  = abs_path("$FindBin::Bin/..");
my $outer = Archive::Multics->new(tz => 'UTC', file => "$FindBin::Bin/data/tests.archive")
    or die $Archive::Multics::error;
my $ok = $outer->get_component('t_ok.archive')->data;

# The MIT Multics source site appends Bull's copyright notice to each
# download as a pseudo-component with a mangled header and DOS line endings.
my $notice = "\n\n\r\f\r\n\r\n\r\n\r\n\t\t    bull_copyright_notice.txt       08/30/05  1008.4r   "
           . "08/30/05  1007.3    00020025\r\n\r\nHistorical Background\r\n\r\nNotice text.\r\n";

sub rd {
    my ($bytes, %o) = @_;
    my $ar = Archive::Multics->new(tz => 'UTC', %o);
    my $r = $ar->read_string($bytes);
    return ($r, $ar);
}

# MIT trailer, with and without a word-aligned total length.
for my $extra ('', 'x') {
    my ($r, $ar) = rd($ok . $notice . $extra);
    ok $r, 'MIT download reads' . ($extra ? ' (unaligned length)' : '') or diag $ar->error;
    is scalar($ar->list_components), 2, '... both real components';
    is $ar->trailer, $notice . $extra, '... notice kept aside';
    like(($ar->warnings)[0], qr/copyright notice appended by the MIT Multics source site/, '... with a warning');
    is $ar->as_string, $ok, '... and is not written back';
}

# Other trailing data is still an error, as on Multics; salvage ignores it.
my ($r, $ar) = rd($ok . ("\0" x 8));
ok !$r, 'trailing words: format error';
($r, $ar) = rd($ok . ("\0" x 8), salvage => 1);
ok $r, 'salvage: trailing words ignored';
like(($ar->warnings)[0], qr/ignored 8 bytes/, '... with a warning');
is $ar->as_string, $ok, '... clean archive written';

# NULs lost in transfer: components without word padding.
(my $stripped = $ok) =~ tr/\0//d;
($r, $ar) = rd($stripped);
ok !$r, 'unpadded: format error';
($r, $ar) = rd($stripped, salvage => 1);
ok $r, 'salvage: unpadded components recovered';
is $ar->as_string, $ok, '... padding restored exactly';
like(join(' ', $ar->warnings), qr/2 components were not padded/, '... with a warning');

# Junk between components is skipped.
my $first_len = 100 + 4 * int((225 + 35) / 36);
my $junked = substr($ok, 0, $first_len) . "garbage!" . substr($ok, $first_len);
($r, $ar) = rd($junked, salvage => 1);
ok $r, 'salvage: junk between components';
is_deeply [ $ar->component_names ], [qw(alpha beta)], '... both components kept';
like(join(' ', $ar->warnings), qr/skipped 8 bytes/, '... with a warning');

# A truncated last component is dropped.
($r, $ar) = rd(substr($ok, 0, length($ok) - 20), salvage => 1);
ok $r, 'salvage: truncated archive';
is_deeply [ $ar->component_names ], [qw(alpha)], '... truncated component dropped';
like(join(' ', $ar->warnings), qr/dropped component 2 \(beta\)/, '... with a warning');

# Leading junk.
($r, $ar) = rd("junk" . $ok, salvage => 1);
ok $r && $ar->list_components == 2, 'salvage: leading junk skipped';

# The command: MIT downloads work without options; damage needs -S.
my $d = abs_path(tempdir(CLEANUP => 1));
sub spew { my ($f, $s) = @_; open my $fh, '>:raw', $f or die; print $fh $s; close $fh }
spew("$d/mit.archive", $ok . $notice);
spew("$d/bad.archive", $stripped);
my $run = sub { my $out = `cd $d && $^X -I$ROOT/lib $ROOT/bin/archive @_ 2>&1`; $out };
like $run->('tb mit'), qr/Warning: \Q$d\E\/mit\.archive: ignored .* MIT.*\n.*alpha\n.*beta\n/s,
    'command: MIT download listed with a warning';
like $run->('t bad'), qr/Format error .* --salvage may recover it/, 'command: damage suggests --salvage';
like $run->('-S tb bad'), qr/not padded.*alpha.*beta/s, 'command: -S recovers';
$run->('d mit alpha');
is do { open my $fh, '<:raw', "$d/mit.archive" or die; local $/; <$fh> },
    substr($ok, $first_len), 'command: update writes a clean archive without the notice';

done_testing;
