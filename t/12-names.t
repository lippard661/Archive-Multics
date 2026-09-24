use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# Component names come from the archive and may be crafted: they must never
# make the command create, read or delete a file outside the directory it
# is working in.

my $ROOT = abs_path("$FindBin::Bin/..");

sub entry {
    my ($name, $data) = @_;
    my $h = "\f\n\n\n\x0F\n\t\t    " . sprintf('%-32s', $name)
          . '09/22/26  1639.0r w 09/22/26  1630.0    '
          . sprintf('%8d', 9 * length $data) . "\x0F\x0F\x0F\x0F\n\n\n\n";
    return $h . $data . ("\0" x ((4 - length($data) % 4) % 4));
}
sub spew { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }
sub run {
    my ($dir, @args) = @_;
    my $old = getcwd();
    chdir $dir or die;
    my $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" @args 2>&1};
    chdir $old;
    return $out;
}

ok !Archive::Multics::safe_file_name($_), "unsafe: '$_'" for ('', '.', '..', '../x', 'a/b', "a\0b");
ok Archive::Multics::safe_file_name($_), "safe: '$_'" for ('x', '.x', '..x', 'x..', 'bound_foo_.s');

my $top  = abs_path(tempdir(CLEANUP => 1));
my $work = "$top/work";
mkdir $work;
spew("$work/evil.archive", entry('../escaped', "pwned\n") . entry('sub/file', "x\n") . entry('ok', "fine\n"));

my $out = run($work, 'x', 'evil');
ok !-e "$top/escaped", 'x: nothing written outside the working directory';
like $out, qr/Component name "\.\.\/escaped" cannot be used as a file name/, 'x: ../ name refused';
like $out, qr/Component name "sub\/file" cannot be used as a file name/, 'x: name with / refused';
ok -f "$work/ok", 'x: ordinary component still extracted';

my $ar = Archive::Multics->new(file => "$work/evil.archive");
ok !$ar->extract_component('../escaped'), 'extract_component refuses the name as a default path';
like $ar->error, qr/cannot be used as a file name/, '... with a clear error';

spew("$top/secret", "secret\n");
spew("$work/evil2.archive", entry('../secret', "old\n"));
run($work, 'rd', 'evil2');
ok -e "$top/secret", 'global rd: file outside the working directory not deleted';
is(Archive::Multics->new(file => "$work/evil2.archive")->get_component('../secret')->data,
    "old\n", 'global rd: ... nor archived');

done_testing;
