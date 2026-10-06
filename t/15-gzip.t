use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use Compress::Raw::Zlib ();
use IO::Compress::Gzip qw(gzip $GzipError);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# gzip as the Multics gzip and gunzip commands write and read it: one
# member; BYTE8 or DENSE9 payload; bit count from an "MU" extra subfield,
# else a stored name ending ".BITCOUNT.dense9", else nine bits an octet.

my $ROOT = abs_path("$FindBin::Bin/..");
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; <$fh> }
sub spew  { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }
sub gz    { my ($data, %o) = @_; my $out; gzip(\$data => \$out, %o) or die $GzipError; $out }

my $raw = slurp("$ROOT/t/data/bound_secure_hash_.dense9");   # 207000 bits, 9-bit data
my $SHA = '7304884dc07cd06097420f2b5204d39b34b7545e09eea6765e89587a1d1c3252';

my $t = 1_790_000_000;
my $src = Archive::Multics->new;
$src->append_component(alpha => "hello\n", time_modified => $t, time_updated => $t) or die;
$src->append_component(beta  => "world\n", time_modified => $t, time_updated => $t) or die;
my $b8 = $src->as_string;                                   # a byte8 source archive

# --- Writing: the Multics derivation rule and stored name.
{
    my $a = Archive::Multics->new;
    ok $a->read_string($raw), 'dense9 archive read';
    $a->set_gzip(1, name => 'bound_secure_hash_.archive');
    my $g = $a->as_string;
    is substr($g, 0, 2), "\x1f\x8b", 'gzip written';
    my ($flg, $os) = unpack 'x3 C x4 x C', $g;
    is $os, 3, 'OS byte 3 (Unix)';
    ok !($flg & 4), 'no extra field written';
    my $b = Archive::Multics->new;
    ok $b->read_string($g), '... read back' or diag $b->error;
    is $b->gzip_info->{stored_name}, 'bound_secure_hash_.archive.207000.dense9',
        'DENSE9: stored name ENTRY.BITCOUNT.dense9';
    is $b->gzip_info->{derivation}, 'dense9', '... derivation dense9';
    is $b->bit_count, 207000, '... bit count';
    $b->set_gzip(0);
    $b->set_encoding('dense9', transfer => 0);
    is sha256_hex($b->as_string), $SHA, '... contents bit for bit';

    my $c = Archive::Multics->new;
    ok $c->read_string($b8), 'byte8 source archive read';
    $c->set_gzip(1, name => 'src.archive');
    my $d = Archive::Multics->new;
    ok $d->read_string($c->as_string), '... gzipped and read back';
    is $d->gzip_info->{stored_name}, 'src.archive', 'BYTE8: stored name is the entry name';
    is $d->gzip_info->{derivation}, 'byte8', '... derivation byte8';

    $c->set_gzip(1, derivation => 'dense9');
    ok $d->read_string($c->as_string), 'DENSE9 forced on a text archive';
    is $d->gzip_info->{stored_name}, 'src.archive.' . $d->bit_count . '.dense9', '... name carries the bit count';
    $a->set_gzip(1, derivation => 'byte8');
    ok !defined $a->as_string, 'BYTE8 forced on 9-bit data refused';
    is $a->error_code, 'ninth_bit', '... ninth_bit';
}

# --- Reading files made elsewhere.
{
    my $a = Archive::Multics->new;
    ok $a->read_string(gz($b8)), 'ordinary gzip of a byte8 archive (no name)';
    is $a->encoding, 'byte8', '... byte8';
    ok $a->read_string(gz($raw, Name => 'bsh.archive')), 'ordinary gzip of a dense9 archive: self-delimiting';
    is $a->bit_count, 207000, '... bit count from the member headers';

    # An MU subfield (as a later Multics gzip, or another tool, might write),
    # after someone else's subfield, with a longer data length.
    my $mu = pack('a2 v C C V', 'MU', 6, 1, 1, 207000);
    my $other = pack('a2 v a3', 'XY', 3, 'abc');
    ok $a->read_string(gz($raw, ExtraField => $other . $mu)), 'MU subfield found after another subfield';
    is $a->gzip_info->{bits_from}, 'MU subfield', '... bit count from MU';
    my $mu8 = pack('a2 v C C V a2', 'MU', 8, 2, 1, 207000, 'zz');
    ok $a->read_string(gz($raw, ExtraField => $mu8)), 'MU with data length 8, version 2: first six octets used';
    ok !$a->read_string(gz($raw, ExtraField => pack('a2 v C C V', 'MU', 6, 1, 1, 207036))), 'MU bit count wrong';
    is $a->error_code, 'bad_gzip', '... bad_gzip';
    ok !$a->read_string(gz($raw, Name => 'bsh.archive.206964.dense9')), 'stored name with the wrong bit count';
    like $a->error, qr/stored name gives bit count 206964/, '... says so';
    ok !$a->read_string(gz($b8, Name => 'x.archive.100.dense9')), 'a BYTE8 payload named as DENSE9 refused';
    ok $a->read_string(gz($b8, ExtraField => pack('a2 v C C V', 'MU', 6, 1, 0, 9 * length $b8))),
        'MU: BYTE8 with the right bit count';
}

# --- Damage and limits.
{
    my $a = Archive::Multics->new;
    my $g = gz($b8);
    my $bad = $g;
    substr($bad, -8, 1) ^= "\x01";
    ok !$a->read_string($bad), 'CRC mismatch refused';
    like $a->error, qr/CRC/, '... says so';
    ok !$a->read_string(substr($g, 0, length($g) - 4)), 'truncated file refused';
    ok !$a->read_string($g . $g), 'two members refused';
    ok !$a->read_string(gz($g)), 'gzip inside gzip refused';
    like $a->error, qr/decompress only once/, '... says so';
    my $bomb = gz("\0" x (Archive::Multics::MAX_OCTETS() + 10_000));
    ok length($bomb) < 20_000, '(a small file that expands past one segment)';
    ok !$a->read_string($bomb), 'expansion past one segment refused';
    like $a->error, qr/more than one segment/, '... says so';
}

# --- Command.
my $old = getcwd();
my $d = abs_path(tempdir(CLEANUP => 1));
chdir $d or die;
my $CMD = qq{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive"};
spew('bsh.archive.gz', do { my $a = Archive::Multics->new; $a->read_string($raw); $a->set_gzip(1, name => 'bsh.archive'); $a->as_string });

my $out = qx{$CMD tb bsh 2>&1};
like $out, qr/secure_hash_/, 't finds NAME.archive.gz when NAME.archive is absent';
$out = qx{$CMD -B d bsh bound_secure_hash_.bind 2>&1};
like $out, qr/gzip, DENSE9/, 'a change keeps it gzipped (DENSE9)';
my $b = Archive::Multics->new(file => 'bsh.archive.gz');
ok $b && $b->is_gzip, '... it is still gzip';
is_deeply [ $b->component_names ], [qw(secure_hash_ sha256)], '... and changed';

mkdir 's'; spew('s/one', "one\n");
$out = qx{$CMD --gzip a new s/one 2>&1};
like $out, qr/Creating .*new\.archive\.gz/, '--gzip creates NAME.archive.gz';
is(Archive::Multics->new(file => 'new.archive.gz')->gzip_info->{stored_name}, 'new.archive', '... BYTE8, entry name stored');

# --export --gzip, and --import of base64 of a gzip file (the Multics pipeline).
spew('bsh.archive', $raw);
$out = qx{$CMD --gzip --export bsh bsh.gz 2>&1};
is $out, '', '--export --gzip';
spew('bsh.b64', encode_base64(slurp('bsh.gz')));
$out = qx{$CMD --import bsh.b64 back 2>&1};
is $out, '', '--import of base64 of a gzip file';
is sha256_hex(slurp('back.archive')), $SHA, '... raw dense9 archive, bit for bit';
$out = qx{$CMD --import bsh.gz back2 2>&1};
is sha256_hex(slurp('back2.archive')), $SHA, '--import of a gzip file';

# What gunzip -N makes of a DENSE9 file: usable by name, read-only.
spew('bsh.archive.207000.dense9', $raw);
$out = qx{$CMD tb bsh.archive.207000.dense9 2>&1};
like $out, qr/sha256/, 't on NAME.archive.BITCOUNT.dense9';
$out = qx{$CMD d bsh.archive.207000.dense9 sha256 2>&1};
like $out, qr/bit count in its name; rename it bsh\.archive/, '... changing it refused';
spew('bsh.archive.206964.dense9', $raw);
$out = qx{$CMD tb bsh.archive.206964.dense9 2>&1};
like $out, qr/named for bit count 206964/, '... a name that disagrees with the contents refused';

chdir $old;
done_testing;
