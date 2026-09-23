use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Archive::Multics;

my $outer = Archive::Multics->new(tz => 'UTC', file => "$FindBin::Bin/data/tests.archive")
    or die $Archive::Multics::error;
my $t_ok = $outer->get_component('t_ok.archive')->data;

# Rebuild t_ok from scratch with the same times: must match the verified bytes.
my $upd = 1790095140;         # 09/22/26 1639.0 UTC
my $mod = 1790094600;         # 09/22/26 1630.0 UTC
my $ar = Archive::Multics->new(tz => 'UTC');
$ar->replace_component(alpha => "This is component alpha.\n",
    time_updated => $upd, time_modified => $mod, access => 'rw') or die $ar->error;
$ar->replace_component(beta => "This is component beta.\nIt has a second line.\n",
    time_updated => $upd, time_modified => $mod) or die $ar->error;
is $ar->as_string, $t_ok, 'new archive matches the Multics-verified t_ok byte for byte';

# Replace keeps position; append refuses duplicates; delete.
$ar->replace_component(alpha => "new alpha\n", time_modified => $mod + 60);
is_deeply [$ar->component_names], [qw(alpha beta)], 'replace keeps position';
is $ar->get_component('alpha')->data, "new alpha\n", '... with new data';
ok !$ar->append_component(beta => 'x'), 'append refuses existing name';
is $ar->error_code, 'namedup', '... namedup';
ok $ar->append_component(gamma => "g\n"), 'append new name';
is_deeply [$ar->component_names], [qw(alpha beta gamma)], '... at the end';
ok $ar->delete_component('beta'), 'delete';
is_deeply [$ar->component_names], [qw(alpha gamma)], '... removed';

# Update compares at header resolution (tenths of a minute).
is $ar->update_component(alpha => 'same', time_modified => $mod + 60 + 5), 0,
    'update: within the same tenth of a minute is not newer';
ok $ar->update_component(alpha => 'newer', time_modified => $mod + 120), 'update: newer replaces';
ok !$ar->update_component(delta => 'x', time_modified => $mod), 'update: missing component';
is $ar->error_code, 'no_component', '... no_component';

# Mode field.
$ar->replace_component(ex => 'x', access => 'rew');
is $ar->get_component('ex')->mode_field, 'rew ', 'rew mode field';
$ar->replace_component(nul => 'x', access => 'null');
is $ar->get_component('nul')->mode_field, '    ', 'null mode field';

# Names.
ok !$ar->replace_component('x' x 33, 'x'), '33-char name rejected';
is $ar->error_code, 'entlong', '... entlong';
ok !$ar->replace_component('a>b', 'x'), 'name with > rejected';
ok $ar->replace_component('x' x 32, 'x'), '32-char name accepted';

# Padding is NUL, archive stays word aligned, and it reads back.
my $s = $ar->as_string;
is length($s) % 4, 0, 'word aligned';
ok(Archive::Multics->new(tz => 'UTC')->read_string($s), 'result reads back');

# Files: write atomically, add_file, extract_component.
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/x.archive";
ok $ar->write($path), 'write';
chmod 0444, $path;
ok $ar->write($path), 'rewrite (directory writable)';
is((stat $path)[2] & 07777, 0444, '... keeps permissions');

open my $fh, '>', "$dir/src.pl1" or die; print $fh "src\n"; close $fh;
chmod 0644, "$dir/src.pl1";
utime $mod, $mod, "$dir/src.pl1";
ok my $c = $ar->add_file("$dir/src.pl1"), 'add_file';
is $c->name, 'src.pl1', '... name from basename';
is $c->time_modified, $mod, '... time from mtime';
is $c->access, 'rw', '... access from permissions';

{
    my $old = umask 022;
    ok $ar->extract_component('src.pl1', "$dir/out.pl1"), 'extract';
    umask $old;
}
is do { local (@ARGV, $/) = "$dir/out.pl1"; <> }, "src\n", '... contents';
is((stat "$dir/out.pl1")[9], $mod, '... mtime from header');
is((stat "$dir/out.pl1")[2] & 07777, 0644, '... rw -> 0644 under umask 022');
ok !$ar->extract_component('src.pl1', "$dir/out.pl1"), 'extract refuses to overwrite';
ok $ar->extract_component('src.pl1', "$dir/out.pl1", force => 1), '... unless forced';

done_testing;
