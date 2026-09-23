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

my $ROOT = abs_path("$FindBin::Bin/..");
my $CMD  = "$ROOT/bin/archive";
my $DATA = "$ROOT/t/data";

# Run the command in $dir with optional standard input.
sub run {
    my ($dir, $stdin, @args) = @_;
    my $old = getcwd();
    chdir $dir or die "$dir: $!";
    local $ENV{TZ} = 'America/Phoenix';
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $^X, "-I$ROOT/lib", $CMD, @args);
    print $in $stdin if defined $stdin;
    close $in;
    my $o = do { local $/; <$out> } // '';
    my $e = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    chdir $old;
    return ($o, $e, $? >> 8);
}

sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; <$fh> }
sub spew  { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }

sub newdir {
    my $d = tempdir(CLEANUP => 1);
    return abs_path($d);
}

# ---------------------------------------------------------------------------
# Table output matches Multics character for character (ac t / ac tl on
# Multics MR12.8, 2026-09-22), apart from the pathname.

{
    my $d = newdir();
    copy("$DATA/tests.archive", "$d/tests.archive") or die;
    my $mpath = '>user_dir_dir>Multics>Lippard>actest>tests.archive';
    for my $key (qw(t tl)) {
        my ($o, $e, $rc) = run($d, undef, $key, 'tests');
        $o =~ s/^( {10})\Q$d\E\/tests\.archive$/$1$mpath/m;
        is $o, slurp("$DATA/tests.ac_$key.txt"), "$key output matches Multics";
        is $e, '', "$key: no errors";
        is $rc, 0, "$key: exit 0";
    }
    my ($o) = run($d, undef, 'tb', 'tests', 'seed.txt', 'double.ec');
    is $o, "09/22/26  1639.0    double.ec\n09/22/26  1639.0    seed.txt\n\n",
        'tb: no title, archive order';
    my ($o2, $e2, $rc2) = run($d, undef, 't', 'tests', 'seed.txt', 'nonesuch');
    like $e2, qr/^archive: nonesuch not found in \Q$d\E\/tests\.archive$/m, 'not found message';
    is $rc2, 1, 'exit 1 on error';
}

# The crafted archives, as the command (archive_util_) sees them.
{
    my $d = newdir();
    my $outer = Archive::Multics->new(file => "$DATA/tests.archive");
    for (qw(t_ok t_badmode t_baddate t_leftbc t_obsolete t_nofence)) {
        spew("$d/$_.archive", $outer->get_component("$_.archive")->data);
    }
    my ($o) = run($d, undef, 'tlb', 't_badmode');
    like $o, qr/^beta {28}09\/22\/26  1639\.0 wer  09\/22\/26  1630\.0     414$/m,
        'bad mode listed, as ac tl does';
    ($o) = run($d, undef, 'tlb', 't_baddate');
    like $o, qr/99\/99\/99  9999\.9     414$/m, 'bad date listed, as ac tl does';
    ($o) = run($d, undef, 'tlb', 't_leftbc');
    like $o, qr/1630\.0     225$/m, 'left-justified bit count printed right-justified';
    for (qw(t_obsolete t_nofence)) {
        my ($o, $e, $rc) = run($d, undef, 't', $_);
        like $e, qr/^archive: Format error in \Q$d\E\/$_\.archive/, "$_ rejected";
    }
}

# ---------------------------------------------------------------------------
# Append, replace, update.

my $d = newdir();
spew("$d/one", "one\n");
spew("$d/two", "two\n");
utime 1790000000, 1790000000, "$d/one", "$d/two";

{
    my ($o, $e, $rc) = run($d, undef, 'a', 'x', 'one', 'two');
    is $o, "archive: Creating $d/x.archive\n", 'a creates, no appended messages';
    is $e, '', 'a: no errors';
    is_deeply [ Archive::Multics->new(file => "$d/x.archive")->component_names ], [qw(one two)],
        'a: components in argument order';

    ($o, $e) = run($d, undef, 'a', 'x', 'one');
    is $e, "archive: Did not append one because copy found in $d/x.archive\n", 'a: duplicate';

    ($o, $e, $rc) = run($d, undef, 'a', 'x');
    is $e, "archive: Some component names must be specified with this key - a\n", 'a: names required';

    ($o, $e) = run($d, undef, 'a', 'x', 'one', 'one');
    like $e, qr/Duplicated request for this component\. one/, 'duplicate argument';
}

{
    spew("$d/one", "ONE\n");
    spew("$d/three", "three\n");
    my ($o, $e) = run($d, undef, 'r', 'x', 'one', 'three');
    is $o, "archive: $d/three appended to $d/x.archive\n", 'r: appended message for new only';
    my $ar = Archive::Multics->new(file => "$d/x.archive");
    is_deeply [ $ar->component_names ], [qw(one two three)], 'r: replaced in place, new at end';
    is $ar->get_component('one')->data, "ONE\n", 'r: new contents';

    ($o, $e) = run($d, undef, 'r', 'x', 'missing');
    like $e, qr/^archive: Entry not found\. Could not replace \Q$d\E\/missing in/, 'r: missing source';
}

{
    # u: nothing newer.
    utime 1790000000, 1790000000, "$d/one", "$d/two", "$d/three";
    run($d, undef, 'r', 'x', 'one', 'two', 'three');
    my ($o, $e) = run($d, undef, 'u', 'x');
    is $e, "archive: Archive $d/x.archive contains the latest versions; no components were updated from $d.\n",
        'u: nothing newer';
    # u: one newer, global.
    spew("$d/two", "TWO\n");
    utime 1790000600, 1790000600, "$d/two";
    ($o, $e) = run($d, undef, 'u', 'x');
    is $o, "archive: two updated in $d/x.archive\n", 'u: global update message';
    is $e, '', 'u: no errors';
    is(Archive::Multics->new(file => "$d/x.archive")->get_component('two')->data, "TWO\n", 'u: updated');
    # u with names: not in archive is "not found"; older gets "Did not update" only
    # when something else was updated.
    spew("$d/one", "one again\n");
    utime 1790001200, 1790001200, "$d/one";
    ($o, $e) = run($d, undef, 'u', 'x', 'one', 'two', 'four');
    like $e, qr/Did not update two because latest copy already in/, 'u: older named source';
    like $e, qr/four not found in/, 'u: does not add';
    # Within the same tenth of a minute is not newer.
    utime 1790001203, 1790001203, "$d/one";
    ($o, $e) = run($d, undef, 'u', 'x', 'one');
    like $e, qr/contains the latest versions/, 'u: 0.1-minute resolution';
}

# ---------------------------------------------------------------------------
# Copy keys.
{
    my $sub = "$d/sub";
    mkdir $sub;
    my ($o, $e) = run($d, undef, 'cr', 'x', 'one');
    is $e, "archive: Attempt to copy onto original.  $d/x.archive\n", 'cr in the archive directory';
    my $before = slurp("$d/x.archive");
    ($o, $e) = run($sub, undef, 'cd', '../x', 'three');
    is $o, "archive: Copying $d/x.archive\n", 'cd: copying message';
    is slurp("$d/x.archive"), $before, 'cd: original unchanged';
    is_deeply [ Archive::Multics->new(file => "$sub/x.archive")->component_names ], [qw(one two)],
        'cd: copy without the component';
}

# ---------------------------------------------------------------------------
# Delete.
{
    my ($o, $e) = run($d, undef, 'd', 'x', 'two', 'nine');
    is $o, '', 'd: silent';
    is $e, "archive: nine not found in $d/x.archive\n", 'd: not found';
    ($o, $e) = run($d, undef, 'd', 'x', 'one', 'three');
    is $o, "archive: All components of $d/x.archive have been deleted.\n", 'd: all deleted';
    is -s "$d/x.archive", 0, '... archive is empty, not removed';
    ($o, $e) = run($d, undef, 't', 'x');
    is $e, "archive: $d/x.archive is empty.\n", 't on an empty archive';
    run($d, undef, 'a', 'x', 'one');
    ($o, $e) = run($d, undef, 'd', 'x', 'abcdefghijklmnopqrstuvwxyz0123456789');
    like $e, qr/Entry name too long/, 'long component name is an error, not truncated';
}

# ---------------------------------------------------------------------------
# Extract.
{
    my $e2 = newdir();
    spew("$e2/p1", "p one\n");
    spew("$e2/p2", "p two\n");
    utime 1790000000, 1790000000, "$e2/p1", "$e2/p2";
    run($e2, undef, 'a', 'y', 'p1', 'p2');
    unlink "$e2/p1", "$e2/p2";
    my $x = newdir();
    my ($o, $e, $rc) = run($x, undef, 'x', "$e2/y");
    is "$o$e", '', 'x: silent';
    is slurp("$x/p1"), "p one\n", 'x: contents';
    is((stat "$x/p1")[9], 1790000000 - 1790000000 % 6, 'x: mtime from header (0.1 minute)');

    ($o, $e) = run($x, "no\n", 'x', "$e2/y", 'p1');
    like $e, qr/Name duplication\. Do you want to delete the old file \Q$x\E\/p1\?/, 'x: asks before replacing';

    # xf onto a symbolic link replaces the link, not its target.
    spew("$x/target", "keep me\n");
    unlink "$x/p2";
    symlink "target", "$x/p2" or die;
    ($o, $e) = run($x, undef, 'xf', "$e2/y", 'p2');
    ok !-l "$x/p2", 'xf: link replaced by a file';
    is slurp("$x/target"), "keep me\n", 'xf: link target untouched';

    ($o, $e) = run($x, undef, 'xd', "$e2/y", "$x/sub/p1");
    like $e, qr/Entry not found/, 'xd: missing destination directory';
    is_deeply [ Archive::Multics->new(file => "$e2/y.archive")->component_names ], [qw(p1 p2)],
        'xd: component kept when extraction fails';
    ($o, $e) = run($x, undef, 'xdf', "$e2/y", 'p1');
    is_deeply [ Archive::Multics->new(file => "$e2/y.archive")->component_names ], [qw(p2)],
        'xdf: extracted component deleted';
}

# ---------------------------------------------------------------------------
# rd with a symbolic link source removes the link, not the target.
{
    my $s = newdir();
    spew("$s/real", "real\n");
    symlink "real", "$s/lnk" or die;
    run($s, undef, 'rd', 'z', 'lnk');
    ok !-e "$s/lnk" && !-l "$s/lnk", 'rd: link removed';
    ok -e "$s/real", 'rd: target kept';
    is(Archive::Multics->new(file => "$s/z.archive")->get_component('lnk')->data, "real\n",
        'rd: archived the target contents');
}

# ---------------------------------------------------------------------------
# Star names and argument errors.
{
    my $s = newdir();
    spew("$s/f", "f\n");
    run($s, undef, 'a', $_, 'f') for qw(b a c.x);
    my @titles;
    my ($o, $e) = run($s, undef, 't', '*');
    @titles = $o =~ /^ {10}\Q$s\E\/(\S+)$/mg;
    is_deeply \@titles, [qw(a.archive b.archive)], "'*' matches one-component names, in order";
    ($o) = run($s, undef, 't', '**');
    @titles = $o =~ /^ {10}\Q$s\E\/(\S+)$/mg;
    is_deeply \@titles, [qw(a.archive b.archive c.x.archive)], "'**' matches any number";
    ($o, $e) = run($s, undef, 'd', '*', 'f');
    is $e, "archive: Star convention cannot be used with this key.  d\n", 'no stars for d';
    ($o, $e) = run($s, undef, 't', 'a', 'b.archive');
    like $e, qr/Warning: b\.archive looks like an archive/, 'warning for a shell-expanded glob';
    ($o, $e) = run($s, undef, 'q', 'a');
    is $e, "archive: Unrecognized key - q\n", 'unrecognized key';
    ($o, $e) = run($s, undef, 't', 'nope');
    is $e, "archive: Entry not found. $s/nope.archive\n", 'missing archive';
}

# ---------------------------------------------------------------------------
# Access (not meaningful as root).
SKIP: {
    skip 'running as root', 4 if $> == 0;
    my $s = newdir();
    spew("$s/f", "f\n");
    run($s, undef, 'a', 'p', 'f');
    chmod 0444, "$s/p.archive";
    spew("$s/f", "g\n");
    my ($o, $e) = run($s, "no\n", 'r', 'p', 'f');
    like $e, qr/Do you want to update the protected file/, 'protected archive: query';
    is(Archive::Multics->new(file => "$s/p.archive")->get_component('f')->data, "f\n", '... no: unchanged');
    run($s, "yes\n", 'r', 'p', 'f');
    is((stat "$s/p.archive")[2] & 07777, 0444, '... yes: updated and still read-only');
    chmod 0200, "$s/p.archive";
    ($o, $e) = run($s, undef, 'r', 'p', 'f');
    is $e, "archive: Incorrect access on entry. $s/p.archive\n", 'unreadable archive is not treated as missing';
}

done_testing;
