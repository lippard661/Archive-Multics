use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use IO::Compress::Gzip qw(gzip $GzipError);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# encode_base64 on Multics writes "-sha256 <digest>" by default: with
# -dense9 (two header lines, in either order), or alone, before base64 of
# byte8 data (a source archive, or a gzip file). The digest is of the
# octets carried.

my $ROOT = abs_path("$FindBin::Bin/..");
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; <$fh> }
sub spew  { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }
sub b64   { my $s = encode_base64($_[0], ''); $s =~ s/(.{1,64})/$1\n/g; $s }

my $raw = slurp("$ROOT/t/data/bound_secure_hash_.dense9");
my $SHA = sha256_hex($raw);
my $t = 1_790_000_000;
my $src = Archive::Multics->new;
$src->append_component(alpha => "hello\n", time_modified => $t, time_updated => $t) or die;
my $b8 = $src->as_string;

my %f = (
    d9_sha => "-dense9 207000\n-sha256 $SHA\n" . b64($raw),
    sha_d9 => "-sha256 $SHA\n-dense9 207000\n" . b64($raw),
    d9     => "-dense9 207000\n" . b64($raw),
    b8_sha => "-sha256 " . sha256_hex($b8) . "\n" . b64($b8),
);
my $gz; gzip(\$b8 => \$gz, Name => 'src.archive') or die $GzipError;
$f{gz_sha} = "-sha256 " . sha256_hex($gz) . "\n" . b64($gz);

for my $k (qw(d9_sha sha_d9 d9)) {
    my $a = Archive::Multics->new;
    ok $a->read_string($f{$k}), "dense9 transfer read: $k" or diag $a->error;
    is $a->bit_count, 207000, '... bit count';
    ok $a->is_transfer, '... is a transfer';
}
{
    my $a = Archive::Multics->new;
    ok $a->read_string($f{b8_sha}), '-sha256 alone, byte8 archive' or diag $a->error;
    is_deeply [ $a->component_names ], ['alpha'], '... its components';
    ok $a->is_transfer, '... is a transfer (not to be changed in place)';
    ok $a->read_string($f{gz_sha}), '-sha256 alone, gzip file' or diag $a->error;
    ok $a->is_gzip && $a->is_transfer, '... gzip inside the transfer';
}

# "-byte8" on a line by itself, with or without "-sha256", in either order.
{
    my $d = sha256_hex($b8);
    for my $hdr ("-byte8\n-sha256 $d\n", "-sha256 $d\n-byte8\n", "-byte8\n") {
        my $a = Archive::Multics->new;
        (my $name = $hdr) =~ s/ [0-9a-f]{64}//; $name =~ s/\n/ /g;
        ok $a->read_string($hdr . b64($b8)), "byte8 transfer: $name" or diag $a->error;
        is_deeply [ $a->component_names ], ['alpha'], '... its components';
        ok $a->is_transfer, '... is a transfer';
    }
    my $a = Archive::Multics->new;
    ok $a->read_string("-byte8\n-sha256 " . sha256_hex($gz) . "\n" . b64($gz)), '-byte8 with a gzip file';
    ok $a->is_gzip, '... gzip inside';
    ok !$a->read_string("-byte8\n-dense9 207000\n" . b64($raw)), '-byte8 with -dense9 refused';
    like $a->error, qr/both "-byte8" and "-dense9"/, '... says so';
    ok !$a->read_string("-byte8 yes\n" . b64($b8)), '-byte8 with a value refused';
    ok !$a->read_string("-byte8\n-byte8\n" . b64($b8)), '-byte8 twice refused';
}

# Damage and malformed headers.
{
    my $a = Archive::Multics->new;
    (my $bad = $f{d9_sha}) =~ s/-sha256 7/-sha256 8/;
    ok !$a->read_string($bad), 'digest mismatch refused';
    like $a->error, qr/SHA-256 of the data does not match/, '... says so';
    (my $bad8 = $f{b8_sha}) =~ s/-sha256 (.)/"-sha256 " . ($1 eq 'a' ? 'b' : 'a')/e;
    ok !$a->read_string($bad8), 'digest mismatch refused (byte8)';
    ok !$a->read_string("-dense9 207000\n-dense9 207000\n" . b64($raw)), 'duplicate header line refused';
    like $a->error, qr/appears twice/, '... says so';
    ok !$a->read_string("-dense9 207000\n-md5 abc\n" . b64($raw)), 'unknown header line refused';
    like $a->error, qr/Unknown header line "-md5"/, '... says so';
    ok !$a->read_string("-dense9 207000\n-sha256 xyz\n" . b64($raw)), 'malformed digest refused';
    my $u = "-sha256 $SHA\n-dense9 207000\n" . b64($raw);
    $u =~ s/\n/\r\n/g;
    ok $a->read_string($u), 'CR LF header lines read';
    like join(' ', $a->warnings), qr/CR LF/, '... with a warning';
}

# A component transfer may carry -sha256; base64 with only a digest is
# stored as it is.
{
    my $a = Archive::Multics->new;
    $a->read_string($raw);
    my $c = $a->get_component('sha256');
    my $ts = $c->transfer_string;
    like $ts, qr/\A-dense9 70200\n-sha256 [0-9a-f]{64}\n/, 'transfer_string writes -sha256';
    my ($data, %attr) = $a->source_data($ts);
    is $attr{bit_count}, 70200, 'source_data: a component transfer with -sha256';
    (my $sw = $ts) =~ s/\A(-dense9 70200\n)(-sha256 [0-9a-f]+\n)/$2$1/;
    ($data, %attr) = $a->source_data($sw);
    is $attr{bit_count}, 70200, '... in either order';
    ($data, %attr) = $a->source_data($f{b8_sha});
    is $data, $f{b8_sha}, '-sha256 alone: stored as it is';
    ok !$a->source_data($ts, bits => 70200), '--bits with a transfer refused';
}

# Command: --import, t, and refusal to change.
my $old = getcwd();
my $d = abs_path(tempdir(CLEANUP => 1));
chdir $d or die;
my $CMD = qq{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive"};
spew("$_.b64", $f{$_}) for keys %f;
for my $k (qw(d9_sha sha_d9)) {
    my $out = qx{$CMD --import $k.b64 out_$k 2>&1};
    is $out, '', "--import $k";
    is sha256_hex(slurp("out_$k.archive")), $SHA, '... raw dense9 archive, bit for bit';
}
spew('b8_hdr.b64', "-byte8\n-sha256 " . sha256_hex($b8) . "\n" . b64($b8));
is qx{$CMD --import b8_hdr.b64 out_b8h 2>&1}, '', '--import: -byte8 and -sha256';
is slurp('out_b8h.archive'), $b8, '... the byte8 archive';
my $out = qx{$CMD --import b8_sha.b64 out_b8 2>&1};
is $out, '', '--import: -sha256 alone, byte8 archive';
is slurp('out_b8.archive'), $b8, '... the byte8 archive';
$out = qx{$CMD --import gz_sha.b64 out_gz 2>&1};
is $out, '', '--import: -sha256 alone, gzip file';
is slurp('out_gz.archive'), $b8, '... decompressed';
spew('x.archive', $f{d9_sha});
like qx{$CMD tb x 2>&1}, qr/sha256/, 't reads a transfer with -sha256';
like qx{$CMD d x sha256 2>&1}, qr/transfer file; convert it with --import/, '... and refuses to change it';
$out = qx{$CMD --export out_d9_sha x2.b64 2>&1};
like slurp('x2.b64'), qr/\A-dense9 207000\n-sha256 $SHA\n/, '--export writes -dense9 and -sha256';

# --export follows the archive's form: byte8 gives -sha256 alone, as
# encode_base64 without -dense9; -9 and -8 choose.
spew('src.archive', $b8);
$out = qx{$CMD --export src src.b64 2>&1};
is $out, '', '--export of a byte8 archive';
my $sb = slurp('src.b64');
like $sb, qr/\A-sha256 ${\ sha256_hex($b8)}\n[A-Za-z0-9+\/=]+\n/, '... -sha256 line (sha256 -byte8), no -dense9';
unlike $sb, qr/-dense9/, '... byte8 base64';
$out = qx{$CMD --import src.b64 src_back 2>&1};
is slurp('src_back.archive'), $b8, '... and --import gives it back';
$out = qx{$CMD -9 --export src src9.b64 2>&1};
like slurp('src9.b64'), qr/\A-dense9 \d+\n-sha256 [0-9a-f]{64}\n/, '-9 --export: a dense9 transfer';
$out = qx{$CMD -8 --export out_d9_sha bad.b64 2>&1};
like $out, qr/9-bit data|dense9/, '-8 --export of 9-bit data refused';
chdir $old;
done_testing;
