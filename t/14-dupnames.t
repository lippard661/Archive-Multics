use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# Duplicate component names. The archive command never makes them, but two
# archives joined end to end are still a valid archive. Here: alpha
# ("first"), beta, alpha ("second"), alpha ("third").

my $ROOT = abs_path("$FindBin::Bin/..");
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; <$fh> }
sub spew  { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }

my $t = 1_790_000_000;
my %attr = (time_modified => $t, time_updated => $t);
my @parts;
for my $set ([ [ alpha => "first\n" ], [ beta => "beta\n" ] ],
             [ [ alpha => "second\n" ] ], [ [ alpha => "third\n" ] ]) {
    my $a = Archive::Multics->new;
    $a->append_component(@$_, %attr) or die $a->error for @$set;
    push @parts, $a->as_string;
}
my $dup = join '', @parts;

# --- Module.
{
    my $a = Archive::Multics->new;
    ok $a->read_string($dup), 'joined archives read' or diag $a->error;
    is_deeply [ $a->component_names ], [qw(alpha beta alpha alpha)], '... all four components';
    like join(' ', $a->warnings), qr/component name "alpha" occurs 3 times/, '... with a warning';
    is $a->get_component('alpha')->data, "first\n", 'get_component finds the first';
    ok !$a->replace_component('alpha', "new\n", %attr), 'replace_component refused';
    is $a->error_code, 'dupname', '... dupname';
    ok !$a->update_component('alpha', "new\n", %attr, time_modified => $t + 3600),
        'update_component refused';
    ok $a->replace_component('beta', "new beta\n", %attr), 'a unique name is still replaced';

    my $d = abs_path(tempdir(CLEANUP => 1));
    my ($second) = grep { $_->data eq "second\n" } $a->list_components;
    ok $a->extract_component($second, "$d/x"), 'extract_component with a component object';
    is slurp("$d/x"), "second\n", '... writes that component, not the first';
}

# --- Command.
my $old = getcwd();
my $d = abs_path(tempdir(CLEANUP => 1));
chdir $d or die;
my $CMD = qq{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive"};
sub run { my ($in, $args) = @_; spew('.in', $in // ''); return scalar qx{$CMD $args < .in 2>&1} }
sub fresh { unlink 'alpha', 'beta'; spew('d.archive', $dup) }

fresh();
my $out = run(undef, 'tb d');
like $out, qr/Warning: .*component name "alpha" occurs 3 times/, 't warns about the duplicate name';
is(() = $out =~ /\balpha\b/g, 4, '... and lists every copy');

# x, answering yes each time: the last copy, as on Multics.
fresh();
run("yes\nyes\n", 'x d alpha');
is slurp('alpha'), "third\n", 'x, yes to each query: the last copy';
fresh();
run("no\nyes\n", 'x d alpha');
is slurp('alpha'), "third\n", 'x, no then yes: the third copy';
fresh();
run("yes\nno\n", 'x d alpha');
is slurp('alpha'), "second\n", 'x, yes then no: the second copy';

# xdf: only the component whose file survives is deleted; repeated, it
# takes the copies out one at a time, last first.
fresh();
my @got;
for (1 .. 3) {
    run(undef, 'xdf d alpha');
    push @got, slurp('alpha');
    unlink 'alpha';
}
is_deeply \@got, ["third\n", "second\n", "first\n"], 'xdf three times: each copy, last first';
is_deeply [ Archive::Multics->new(file => 'd.archive')->component_names ], ['beta'],
    '... none lost; beta left';

# xd, answering no: takes out the first copy only.
fresh();
run("no\nno\n", 'xd d alpha');
is slurp('alpha'), "first\n", 'xd, no to each query: the first copy';
my @left = map { $_->data } grep { $_->name eq 'alpha' } Archive::Multics->new(file => 'd.archive')->list_components;
is_deeply \@left, ["second\n", "third\n"], '... the others stay in the archive';

# xd, yes then yes: the third copy extracted and deleted; the first two,
# whose files were overwritten, stay (Multics loses them).
fresh();
run("yes\nyes\n", 'xd d alpha');
is slurp('alpha'), "third\n", 'xd, yes to each: the file holds the last copy';
@left = map { $_->data } grep { $_->name eq 'alpha' } Archive::Multics->new(file => 'd.archive')->list_components;
is_deeply \@left, ["first\n", "second\n"], '... and the overwritten copies stay in the archive';

# r and u are refused; d deletes every copy.
fresh();
spew('alpha', "new\n");
$out = run(undef, 'r d alpha');
like $out, qr/alpha occurs 3 times in the archive .*Could not replace/, 'r refused, with a message';
is slurp('d.archive'), $dup, '... archive unchanged';
$out = run(undef, 'r d');
like $out, qr/alpha occurs 3 times in the archive/, 'global r: refused for the duplicate';
$out = run(undef, 'u d alpha');
unlike $out, qr/contains the latest versions/, 'u: refused, not "latest versions"';
unlink 'alpha';
run(undef, 'd d alpha');
is_deeply [ Archive::Multics->new(file => 'd.archive')->component_names ], ['beta'], 'd deletes every copy';

chdir $old;
done_testing;
