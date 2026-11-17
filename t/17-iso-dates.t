use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Cwd qw(getcwd abs_path);
use IPC::Open3;
use Symbol qw(gensym);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# Header dates in the ISO form, yyyymmddThhmmssZ (GMT), as the experimental
# Multics archive for MCR10207 writes them, and its update test.

my $upd = 1794866760;    # 2026-11-16 22:06:00 GMT
my $mod = 1794866298;    # 2026-11-16 21:58:18 GMT

# ---------------------------------------------------------------------------
# Writing and reading.

my $ar = Archive::Multics->new(tz => 'America/Phoenix');
is $ar->date_form, 'original', 'a new archive is original by default';
my $iso = Archive::Multics->new(tz => 'America/Phoenix', date_form => 'iso');
is $iso->date_form, 'iso', 'date_form => iso';
$iso->replace_component(alpha => "alpha\n", time_updated => $upd + 0.9, time_modified => $mod)
    or die $iso->error;
my $c = $iso->get_component('alpha');
is $c->time_updated_string,  '20261116T220600Z', 'updated: ISO form, seconds truncated';
is $c->time_modified_string, '20261116T215818Z', 'modified: ISO form';
is $c->date_form, 'iso', 'component date_form';
is $c->time_updated,  $upd, 'time_updated';
is $c->time_modified, $mod, 'time_modified';
like $c->header, qr/^\f\n\n\n\x0F\n\t\t {4}alpha {27}20261116T220600Zr w 20261116T215818Z {4} {6}54\x0F{4}\n{4}$/,
    'header: same layout, pads blank';

my $s = $iso->as_string;
for my $tz (qw(UTC Asia/Tokyo America/Phoenix)) {
    my $r = Archive::Multics->new(tz => $tz);
    $r->read_string($s) or die $Archive::Multics::error;
    is $r->get_component('alpha')->time_modified, $mod, "read in $tz: GMT, the zone does not apply";
}
my $r = Archive::Multics->new(tz => 'UTC');
$r->read_string($s) or die $Archive::Multics::error;
is $r->date_form, 'iso', 'an ISO archive keeps its form, without date_form';
$r->replace_component(beta => "beta\n", time_updated => $upd, time_modified => $mod);
is $r->get_component('beta')->time_updated_string, '20261116T220600Z', '... for a new component';

# An original-form archive stays original, even with date_form => iso.
my $o = Archive::Multics->new(tz => 'UTC', date_form => 'iso',
    file => "$FindBin::Bin/data/tests.archive") or die $Archive::Multics::error;
is $o->date_form, 'original', 'original archive keeps its form';
$o->replace_component(gamma => "g\n", time_updated => $upd, time_modified => $mod);
is $o->get_component('gamma')->time_updated_string, '11/16/26  2206.0', '... for a new component';

# Mixed archives read: each date by its own form.
my $mixed = Archive::Multics->new(tz => 'UTC');
$mixed->replace_component(old => "o\n", time_updated => $upd, time_modified => $mod);
my $m2 = Archive::Multics->new(tz => 'UTC', date_form => 'iso');
$m2->replace_component(new => "n\n", time_updated => $upd, time_modified => $mod);
my $mx = Archive::Multics->new(tz => 'UTC');
$mx->read_string($mixed->as_string . $m2->as_string) or die $Archive::Multics::error;
is_deeply [ map { $_->date_form } $mx->list_components ], [qw(original iso)], 'mixed archive reads';
is $mx->get_component('new')->time_modified, $mod, '... ISO date';
is $mx->get_component('old')->time_modified, $mod, '... original date';

# Full validation rejects an impossible ISO date; basic accepts the characters.
(my $bad = $s) =~ s/20261116T215818Z/20261132T215818Z/;
ok !Archive::Multics->new->read_string($bad), 'impossible ISO date rejected';
is $Archive::Multics::error_code, 'archive_fmt_err', '... archive_fmt_err';
ok(Archive::Multics->new(validate => 'basic')->read_string($bad), '... basic validation reads it');
(my $badc = $s) =~ s/20261116T215818Z/20261116X215818Z/;
ok !Archive::Multics->new(validate => 'basic')->read_string($badc), 'other letters rejected';

is $ar->format_date($upd, 'iso'), '20261116T220600Z', 'format_date iso';
is $ar->format_date($upd), '11/16/26  1506.0', 'format_date original, local zone';
is $ar->display_date($upd, '%Y-%m-%d %H:%M'), '2026-11-16 15:06', 'display_date';

# ---------------------------------------------------------------------------
# The update test.

{
    my $a = Archive::Multics->new(tz => 'UTC', date_form => 'iso');
    $a->replace_component(x => "same\n", time_updated => $mod, time_modified => $mod);
    my $x = $a->get_component('x');
    is $a->date_compare($mod - 1, $x), -1, 'earlier source: not newer';
    is $a->date_compare($mod + 6, $x),  1, '6 seconds later: newer';
    is $a->date_compare($mod + 5, $x),  0, 'within 6 seconds, archived then: cannot tell';
    ok !$a->is_newer($mod + 5, $x, "same\n"), '... same contents: not newer';
    ok  $a->is_newer($mod + 5, $x, "diff\n"), '... different contents: newer';
    ok  $a->is_newer($mod + 5, $x, "same\nmore\n"), '... different length: newer';
    ok  $a->is_newer($mod + 5, $x), '... no contents given: newer';
    is $a->update_component(x => "same\n", time_modified => $mod + 5), 0, 'update_component: same';
    ok $a->update_component(x => "diff\n", time_modified => $mod + 5), 'update_component: different';

    $a->replace_component(y => "y\n", time_updated => $mod + 6, time_modified => $mod);
    is $a->date_compare($mod + 5, $a->get_component('y')), -1,
        'archived 6 seconds or more after its date: not newer';
}
{
    # Original form: the date is truncated to the tenth of a minute.
    my $a = Archive::Multics->new(tz => 'UTC');
    $a->replace_component(z => "z\n", time_updated => $mod + 3, time_modified => $mod + 3);
    my $z = $a->get_component('z');
    is $a->date_compare($mod + 3, $z), 0, 'original form: same tenth, archived then: cannot tell';
    ok !$a->is_newer($mod + 3, $z, "z\n"), '... same contents: not newer';
}

# ---------------------------------------------------------------------------
# The command.

my $ROOT = abs_path("$FindBin::Bin/..");
my $CMD  = "$ROOT/bin/archive";

sub run {
    my ($dir, @args) = @_;
    my $old = getcwd();
    chdir $dir or die "$dir: $!";
    local $ENV{TZ} = 'America/Phoenix';
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $^X, "-I$ROOT/lib", $CMD, @args);
    close $in;
    my $so = do { local $/; <$out> } // '';
    my $se = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    chdir $old;
    return ($so, $se, $? >> 8);
}
sub spew { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }

my $d = abs_path(tempdir(CLEANUP => 1));
my $t = time + 1000;    # a source date after the archiving
spew("$d/one", "one\n");
utime $t, $t, "$d/one";
my ($so, $se) = run($d, '--exl', 'r', 'x', 'one');
is $se, '', '--exl r: no errors';
my $x = Archive::Multics->new(file => "$d/x.archive") or die $Archive::Multics::error;
is $x->date_form, 'iso', '--exl: new archive in the ISO form';
like $x->get_component('one')->time_modified_string, qr/^\d{8}T\d{6}Z$/, '... modified date';

($so) = run($d, 'tlb', 'x');
like $so, qr/^one {29}\d{8}T\d{6}Z r w  \d{8}T\d{6}Z {6}36$/m, 'tl without --exl: dates as stored';
($so) = run($d, '--exl', 'tl', 'x');
like $so, qr/^ name {32}updated {7}mode {4}modified {7}length\n\n/m, '--exl tl: heading';
{
    local $ENV{TZ} = 'America/Phoenix';
    POSIX::tzset();
    my $mt = POSIX::strftime('%Y-%m-%d %H%M', localtime $t) . '.' . int(($t % 60) / 6);
    like $so, qr/^one {29} \d{4}-\d\d-\d\d \d{4}\.\d r w \Q$mt\E      36$/m, '--exl tl: local dates, 80 columns';
}
my ($line) = $so =~ /^(one .*)$/m;
is length $line, 80, '... 80 columns';
($so) = run($d, '--exl', 'tb', 'x');
like $so, qr/^\d{4}-\d\d-\d\d \d{4}\.\d   one$/m, '--exl t: local date';

# Without --exl, the ISO archive keeps its form when changed.
spew("$d/two", "two\n");
run($d, 'r', 'x', 'two');
$x = Archive::Multics->new(file => "$d/x.archive");
like $x->get_component('two')->time_updated_string, qr/^\d{8}T\d{6}Z$/, 'without --exl: keeps the ISO form';

# u: unchanged, then changed within the 6 seconds (archived before them).
($so, $se) = run($d, 'u', 'x', 'one');
like $se, qr/contains the latest versions/, 'u: same date, same contents: not updated';
spew("$d/one", "ONE\n");
utime $t + 2, $t + 2, "$d/one";
($so, $se) = run($d, 'u', 'x', 'one');
is $se, '', 'u: within 6 seconds, different contents: no errors';
is(Archive::Multics->new(file => "$d/x.archive")->get_component('one')->data, "ONE\n",
    '... updated');

# --exl on an original archive: still original, dates shown converted.
copy("$FindBin::Bin/data/tests.archive", "$d/tests.archive") or die;
($so) = run($d, '--exl', 'tb', 'tests', 'seed.txt');
is $so, "2026-09-22 1639.0   seed.txt\n\n", '--exl t: original date, read as local, shown converted';

done_testing;
