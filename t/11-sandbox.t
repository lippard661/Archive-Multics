use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use File::Spec;

# Checks what the command would unveil and pledge on OpenBSD, using
# stand-in OpenBSD::Pledge and OpenBSD::Unveil modules that only record
# their arguments. (On OpenBSD the real ones are exercised by 10-command.t.)

my $ROOT = abs_path("$FindBin::Bin/..");

sub sandbox_for {
    my ($dir, @args) = @_;
    my $log = "$dir/.log";
    unlink $log;
    my $old = getcwd();
    chdir $dir or die;
    local $ENV{SANDBOX_LOG} = $log;
    # Only the sandbox calls matter here; the command's own messages (e.g.
    # "Entry not found" for t on an archive not yet created) are discarded.
    open my $saveout, '>&', \*STDOUT or die;
    open my $saveerr, '>&', \*STDERR or die;
    open STDOUT, '>', File::Spec->devnull or die;
    open STDERR, '>', File::Spec->devnull or die;
    system $^X, "-I$ROOT/t/lib", "-I$ROOT/lib", '-e',
        '$^O = "openbsd"; @ARGV = @ARGV; do $ENV{CMD}; die $@ if $@', @args;
    open STDOUT, '>&', $saveout or die;
    open STDERR, '>&', $saveerr or die;
    chdir $old;
    open my $f, '<', $log or return {};
    my (%u, $p);
    while (<$f>) {
        chomp;
        if (/^unveil (\S+) (\S+)$/) { $u{$1} = $2 }
        elsif (/^pledge ?(.*)$/)    { $p = $1 }
    }
    return { unveil => \%u, pledge => $p };
}

$ENV{CMD} = "$ROOT/bin/archive";
my $d   = abs_path(tempdir(CLEANUP => 1));
my $src = abs_path(tempdir(CLEANUP => 1));
my $out = abs_path(tempdir(CLEANUP => 1));
open my $fh, '>', "$src/f" or die; print $fh "f\n"; close $fh;

my $s = sandbox_for($d, 't', 'x');
is $s->{pledge}, 'rpath', 't: rpath only';
is $s->{unveil}{$d}, 'r', 't: archive directory read-only';

$s = sandbox_for($d, 'r', 'x', "$src/f");
is $s->{pledge}, 'rpath wpath cpath fattr flock', 'r: write promises and flock';
is $s->{unveil}{$d}, 'rwc', 'r: archive directory writable';
is $s->{unveil}{$src}, 'r', 'r: source directory read-only';

$s = sandbox_for($d, 'rd', 'x', "$src/f");
is $s->{unveil}{$src}, 'rc', 'rd: source directory allows deletion';

open $fh, '>', "$src/f" or die; print $fh "f\n"; close $fh;    # rd deleted it
$s = sandbox_for($d, 'x', 'x', "$out/f");
is $s->{pledge}, 'rpath wpath cpath fattr', 'x: no flock (archive unchanged)';
is $s->{unveil}{$out}, 'rwc', 'x: destination writable';

$s = sandbox_for($out, 'cr', "$d/x", "$src/f");
is $s->{unveil}{$d}, 'r', 'cr: original archive directory read-only';
is $s->{unveil}{$out}, 'rwc', 'cr: working directory writable for the copy';

symlink "$src/f", "$out/lnk" or die;
$s = sandbox_for($d, 'r', 'x', "$out/lnk");
is $s->{unveil}{$src}, 'r', 'symlinked source: target directory unveiled';

done_testing;
