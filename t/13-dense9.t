use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use lib "$FindBin::Bin/../lib";
use Archive::Multics;

# bound_secure_hash_.dense9: bound_secure_hash_.archive from Multics
# (encode_base64 -dense9, header removed, base64 decoded). Two object
# segments (9th bits set) and a bindfile.

my $ROOT = abs_path("$FindBin::Bin/..");
my $DATA = "$ROOT/t/data";
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; <$fh> }
sub spew  { my ($f, $s) = @_; open my $fh, '>:raw', $f or die "$f: $!"; print $fh $s; close $fh }

my $raw = slurp("$DATA/bound_secure_hash_.dense9");

# --- The checked example from DENSE9.md: "abcdefg\n", 72 bits.
{
    my $a = Archive::Multics->new;
    my ($bits, $chars) = $a->_transfer_contents("-dense9 72\nMJiMZkMpmM4K\n");
    is $bits, 72, 'example: bit count';
    is $chars, "abcdefg\n", 'example: unpacks to abcdefg\n';
    is sha256_hex(Archive::Multics::_pack9($chars)),
        'b983bc28d71d360ec06584c8e600a28c67834a724265abdbfcf8ebc60cfa43fd',
        'example: sha256 matches sha256 -dense9 on Multics';
}

# --- Raw dense9: detection, listing, round trip.
my $ar = Archive::Multics->new;
ok $ar->read_string($raw), 'raw dense9 read' or diag $ar->error;
is $ar->encoding, 'dense9', 'detected as dense9';
ok !$ar->is_transfer, '... raw, not a transfer file';
is $ar->bit_count, 207000, 'archive bit count';
is_deeply [ map { [ $_->name, $_->bit_count, $_->is_text ] } $ar->list_components ],
    [ [ 'secure_hash_', 127080, 0 ], [ 'sha256', 70200, 0 ], [ 'bound_secure_hash_.bind', 7002, 1 ] ],
    'components, bit counts, text or not';
ok $ar->get_component('sha256')->has_ninth_bits, 'object segment has 9th bits';
like $ar->get_component('bound_secure_hash_.bind')->data, qr{\A/\* Bindfile for bound_secure_hash_ \*/\n},
    'bindfile extracts as text';
is $ar->as_string, $raw, 'unchanged archive written back identically (raw)';

# --- Transfer form.
$ar->set_encoding('dense9', transfer => 1);
my $tr = $ar->as_string;
like $tr, qr/\A-dense9 207000\n[A-Za-z0-9+\/]{64}\n/, 'transfer file: header and 64-column body';
is 9 * int((207000 + 71) / 72), length($raw), 'octet count is 9 * ceil(bits / 72)';
my $t2 = Archive::Multics->new;
ok $t2->read_string($tr), 'transfer file read' or diag $t2->error;
ok $t2->is_transfer, '... detected as a transfer file';
is $t2->as_string, $tr, '... written back identically';
$t2->set_encoding('dense9', transfer => 0);
is $t2->as_string, $raw, '... and as raw dense9, identical to the original';

# --- byte8 cannot hold 9-bit data.
{
    my $b = Archive::Multics->new; $b->read_string($raw);
    $b->set_encoding('byte8');
    ok !defined $b->as_string, 'byte8 refuses an archive with 9-bit data';
    is $b->error_code, 'ninth_bit', '... ninth_bit';
}

# --- Oracle: a text-only archive is the same in both encodings.
{
    my $outer = Archive::Multics->new(file => "$DATA/tests.archive");
    my $ok8 = $outer->get_component('t_ok.archive')->data;      # 69 words: odd
    my $a = Archive::Multics->new; $a->read_string($ok8);
    $a->set_encoding('dense9', transfer => 0);
    my $d9 = $a->as_string;
    is length($d9), 9 * 35, 'odd word count: padded to a whole 72-bit group';
    my $b = Archive::Multics->new;
    ok $b->read_string($d9), 'raw dense9 with a pad word read' or diag $b->error;
    is_deeply [ map { $_->data } $b->list_components ], [ map { $_->data } $a->list_components ],
        'components identical to the byte8 reading';
    $b->set_encoding('byte8');
    is $b->as_string, $ok8, 'converted back to byte8: identical octets';
}

# --- Binary extraction and re-adding.
my $dir = abs_path(tempdir(CLEANUP => 1));
{
    my $a = Archive::Multics->new; $a->read_string($raw);
    ok $a->extract_component('sha256', "$dir/sha256"), 'binary component extracted' or diag $a->error;
    my $o = $a->get_component('sha256')->dense9;
    is slurp("$dir/sha256"), $o, '... as raw dense9 by default';
    is sha256_hex(slurp("$dir/sha256")),
        'e8754291c6c162bc67b1dcd64f62877a1da31e4a099cb09613db05bedf019f9d',
        '... whose SHA-256 is that of the dense9 bits';
    unlink "$dir/sha256";
    ok $a->extract_component('sha256', "$dir/sha256", transfer => 1), 'extracted with transfer => 1'
        or diag $a->error;
    my $x = slurp("$dir/sha256");
    like $x, qr/\A-dense9 70200\n/, '... as a transfer file with its bit count';
    is $x, $a->get_component('sha256')->transfer_string, '... the component\'s transfer string';
    ok $a->add_file("$dir/sha256", action => 'replace'), 'transfer file put back' or diag $a->error;
    is $a->get_component('sha256')->dense9, $o, '... bits identical';
    is $a->get_component('sha256')->bit_count, 70200, '... bit count preserved';
    is $a->bit_count, 207000, '... archive bit count unchanged';

    spew("$dir/bound_secure_hash_.bind", "/* short */\n");
    ok $a->add_file("$dir/bound_secure_hash_.bind"), 'text component replaced';
    my $bits = 0; $bits += 900 + 36 * int(($_->bit_count + 35) / 36) for $a->list_components;
    is $a->bit_count, $bits, 'bit count follows the contents';
    $a->set_encoding('dense9', transfer => 1);
    like $a->as_string, qr/\A-dense9 $bits\n/, 'transfer header carries the new bit count';
}

# --- Damaged and crafted input.
{
    my $a = Archive::Multics->new;
    (my $cut = $tr) =~ s/\n[^\n]*\n\z/\n/;
    ok !$a->read_string($cut), 'truncated transfer rejected';
    like $a->error, qr/truncated/, '... says so';
    ok !$a->read_string("-dense9  207000\n" . substr($tr, 15)), 'two spaces after -dense9 rejected';
    ok !$a->read_string("-dense9 72\nMJiMZkMpmM4K\n"), 'bit count not a whole number of words rejected';
    ok !$a->read_string("-dense9 99999999\n"), 'bit count over one segment rejected';
    (my $crlf = $tr) =~ s/\A(-dense9 \d+)\n/$1\r\n/;
    ok $a->read_string($crlf), 'CR LF header line read' or diag $a->error;
    like join(' ', $a->warnings), qr/CR LF/, '... with a warning';

    # Nonzero pad bits: t_ok (odd word count) as a transfer with the pad set.
    my $outer = Archive::Multics->new(file => "$DATA/tests.archive");
    my $b = Archive::Multics->new; $b->read_string($outer->get_component('t_ok.archive')->data);
    $b->set_encoding('dense9', transfer => 0);
    my $d9 = $b->as_string;
    substr($d9, -1, 1) = "\x01";
    my $bits = $b->bit_count;
    my $t = "-dense9 $bits\n" . encode_base64($d9);
    ok $a->read_string($t), 'transfer with nonzero pad bits read' or diag $a->error;
    like join(' ', $a->warnings), qr/pad bits/, '... with a warning';

    # A header character with its 9th bit set.
    my $c = Archive::Multics->new; $c->read_string($raw);
    my $chars = Archive::Multics::_unpack9($raw, 207000 / 9);
    substr($chars, 20, 1) = chr(0x141);                 # in the first name
    ok !$a->read_string(Archive::Multics::_pack9($chars)), 'header character with 9th bit rejected';
    like $a->error, qr/9th bit/, '... says so';
}

# --- The command.
{
    my $old = getcwd();
    chdir $dir or die;
    spew("bsh.archive", $raw);
    my $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -B t bsh 2>&1};
    like $out, qr/bit count 207000 \(5750 words, dense9\)/, 'command: -B';
    mkdir "x";
    chdir "x";
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" x ../bsh 2>&1};
    like $out, qr/secure_hash_ has 9-bit data; written in dense9 form/, 'command: x of a binary';
    is slurp("sha256"), Archive::Multics->new(file => "../bsh.archive")->get_component('sha256')->dense9,
        'command: binary extracted raw';
    is slurp("bound_secure_hash_.bind"), Archive::Multics->new(file => "../bsh.archive")
        ->get_component('bound_secure_hash_.bind')->data, 'command: text component extracted as text';
    chdir "..";
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --byte8 r bsh x/bound_secure_hash_.bind 2>&1};
    like $out, qr/use --dense9/, 'command: --byte8 refused for 9-bit data';
    is slurp("bsh.archive"), $raw, '... archive unchanged';
    # --export / --import round trip; updating a transfer file is refused.
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -B --export bsh bsh.b64 2>&1};
    like $out, qr/bit count 207000/, 'command: --export';
    like slurp("bsh.b64"), qr/\A-dense9 207000\n/, '... writes a transfer file';
    spew("tr.archive", slurp("bsh.b64"));
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" r tr x/bound_secure_hash_.bind 2>&1};
    like $out, qr/transfer file; convert it with --import first/, 'command: update of a transfer file refused';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" t tr 2>&1};
    like $out, qr/sha256/, 'command: t reads a transfer file';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --import bsh.b64 back 2>&1};
    is slurp("back.archive"), $raw, 'command: --import gives the raw archive back, identical';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --import bsh.archive back 2>&1 </dev/null};
    like $out, qr/not a dense9 transfer file/, 'command: --import of a raw archive refused';
    chdir "x"; $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -T xf ../bsh sha256 2>&1};
    like $out, qr/written as a dense9 transfer file/, 'command: -T x writes a transfer file';
    like slurp("sha256"), qr/\A-dense9 70200\n/, '... with its bit count';
    chdir "..";
    spew("sha256raw", Archive::Multics->new(file => "bsh.archive")->get_component('sha256')->dense9);
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" r back sha256raw 2>&1};
    rename "sha256raw", "sha256";
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" r back sha256 2>&1};
    like $out, qr/has 9-bit data; give the bit count .* with --bits/s,
        'command: replacing a binary from a raw file without --bits refused';
    my $raw_sha = Archive::Multics->new(file => "bsh.archive")->get_component('sha256')->dense9;
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 70236 r back sha256 2>&1};
    like $out, qr/raw dense9 data of bit count 70236 is 8784/, 'command: --bits with a wrong count refused';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 70200 r back sha256 2>&1};
    is $out, '', 'command: --bits 70200 accepted';
    is(Archive::Multics->new(file => "back.archive")->get_component('sha256')->dense9, $raw_sha,
        '... component bits identical');
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 70200 r back sha256 secure_hash_ 2>&1};
    like $out, qr/--bits needs exactly one component path/, 'command: --bits with two paths refused';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -T r back sha256 2>&1};
    like $out, qr/-T is for the x keys only/, 'command: -T with r refused';
    spew("tf", "-dense9 72\nMJiMZkMpmM4K\n");
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 72 r back tf 2>&1};
    like $out, qr/transfer file, which records its own bit count/, 'command: --bits with a transfer file refused';
    # The mode survives extraction and replacement, for binaries too.
    {
        my $m = abs_path(tempdir(CLEANUP => 1));
        spew("$m/bsh.archive", $raw);
        my $o = getcwd(); chdir $m or die;
        my $u = umask 022;
        my $before = Archive::Multics->new(file => "bsh.archive")->get_component('sha256')->mode_field;
        qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" x bsh sha256 2>&1};
        is((stat "sha256")[2] & 07777, 0555, 'x: mode re extracts as r-x, binary or not');
        qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 70200 r bsh sha256 2>&1};
        my $c = Archive::Multics->new(file => "bsh.archive")->get_component('sha256');
        is($c->mode_field, $before, "... and goes back as '$before' (owner bits, even for root)");
        umask $u;
        chdir $o;
    }
    # Global r: the binaries are skipped, the text component is replaced.
    {
        my $g = abs_path(tempdir(CLEANUP => 1));
        spew("$g/bsh.archive", $raw);
        my $o = getcwd(); chdir $g or die;
        qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" x bsh 2>&1};
        unlink "bound_secure_hash_.bind";    # extracted read-only (mode r)
        spew("bound_secure_hash_.bind", "changed\n");
        $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" r bsh 2>&1};
        like $out, qr/secure_hash_ has 9-bit data/, 'command: global r skips a binary';
        my $ga = Archive::Multics->new(file => "bsh.archive");
        is($ga->get_component('bound_secure_hash_.bind')->data, "changed\n", '... and replaces the text');
        is($ga->get_component('sha256')->dense9, $raw_sha, '... binaries unchanged');
        $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" d bsh sha256 2>&1};
        $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" --bits 70200 a bsh sha256 2>&1};
        is $out, '', 'command: a with --bits';
        is(Archive::Multics->new(file => "bsh.archive")->get_component('sha256')->dense9, $raw_sha,
            '... bits identical');
        chdir $o;
    }
    chdir "x";
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" xf ../bsh sha256 2>&1};
    like $out, qr/bit count 70200 \(to put it back: --bits 70200\)/, 'command: x prints the bit count';
    chdir "..";
    chdir $old;
}

# --- Review follow-ups.
{
    # Characters above octal 777 are refused, not silently corrupted.
    my $a = Archive::Multics->new; $a->read_string($raw);
    ok !$a->replace_component('x', "caf\x{263A}\n"), 'character above 0777 refused';
    is $a->error_code, 'bad_data', '... bad_data';

    # A raw dense9 file larger than one segment is refused before unpacking.
    my $big = Archive::Multics::_dense9_ident() . ("\0" x (Archive::Multics::MAX_OCTETS()));
    ok !$a->read_string($big), 'oversized raw dense9 file refused';
    like $a->error, qr/at most/, '... says why';

    # A transfer body of the wrong size is refused before decoding.
    ok !$a->read_string("-dense9 36\n" . ('A' x 4000)), 'oversized transfer body refused';

    # Bit counts that are not a multiple of 9, in dense9.
    my $d = Archive::Multics->new(encoding => 'dense9');
    ok $d->replace_component('odd', "\x{101}\x{80}", bit_count => 13), '13-bit component made'
        or diag $d->error;
    my $c = $d->get_component('odd');
    ok !$c->is_text && $c->lossless, '... not text, lossless';
    my $d2 = Archive::Multics->new; ok $d2->read_string($d->as_string), '... archive read back' or diag $d2->error;
    is $d2->get_component('odd')->bit_count, 13, '... bit count kept';
    is $d2->get_component('odd')->dense9, $c->dense9, '... bits kept';
    ok $d2->extract_component('odd', "$dir/odd", transfer => 1), '... extracted' or diag $d2->error;
    like slurp("$dir/odd"), qr/\A-dense9 13\n/, '... as a transfer file';

    # byte8-read components keep the old rule: bits already lost.
    my $b8 = Archive::Multics->new(encoding => 'byte8');
    $b8->replace_component('t', "text\n");
    my $b8r = Archive::Multics->new; $b8r->read_string($b8->as_string);
    ok !$b8r->get_component('t')->lossless, 'byte8-read component is not lossless';
    ok $b8r->get_component('t')->is_text, '... but text is still text';

    # A text file that merely starts with "-dense9 " is text.
    spew("$dir/apples", "-dense9 5 apples\n");
    ok $a->add_file("$dir/apples"), 'text starting with "-dense9 " added' or diag $a->error;
    is $a->get_component('apples')->data, "-dense9 5 apples\n", '... as text';

    # Control characters in a name: readable, but never used as a file name.
    my $e = Archive::Multics->new(encoding => 'byte8');
    $e->{components} = [];
    my $hdr = Archive::Multics::_build_header("bad\e[2Jname", '09/22/26  1639.0', 'r w ', '09/22/26  1639.0', 9 * 4);
    my $arc = $hdr . "abc\n";
    my $er = Archive::Multics->new;
    ok $er->read_string($arc), 'name with a control character still read (as archive_ does)' or diag $er->error;
    ok !Archive::Multics::safe_file_name("bad\e[2Jname"), '... but not usable as a file name';

    # Error text from the archive is escaped.
    (my $badbc = $arc) =~ s/      36/\e[2J  36/;
    ok !$er->read_string($badbc), 'bad bit count field rejected';
    unlike $er->error, qr/\e/, '... error message has no escape characters';

    # Parsing many components with 9th bits stays fast (not quadratic).
    my $m = Archive::Multics->new(encoding => 'dense9');
    $m->replace_component(sprintf('c%04d', $_), "\x{100}" x 36, bit_count => 324) for 1 .. 2000;
    my $mo = $m->as_string;
    my $t0 = time;
    my $mr = Archive::Multics->new;
    ok $mr->read_string($mo), '2000 9-bit components read' or diag $mr->error;
    cmp_ok time - $t0, '<=', 10, '... in reasonable time';
    is scalar($mr->list_components), 2000, '... all of them';
}

# --- Command: -8 does not stop extraction of 9-bit data read losslessly.
{
    my $old = getcwd();
    my $d = abs_path(tempdir(CLEANUP => 1));
    chdir $d or die;
    spew("bsh.archive", $raw);
    my $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -8 x bsh sha256 2>&1};
    like $out, qr/written in dense9 form/, 'command: -8 x still extracts a binary';
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -8 -B r bsh sha256 2>&1};
    unlike $out, qr/bit count \d+ \(/, 'command: no -B line when nothing was written';
    unlink "sha256";
    qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -T x bsh sha256 2>&1};
    $out = qx{"$^X" "-I$ROOT/lib" "$ROOT/bin/archive" -8 -B r bsh sha256 2>&1};
    like $out, qr/9th bit|9-bit/, 'command: -8 write of 9-bit data fails';
    unlike $out, qr/bit count \d+ \(/, 'command: no -B line after a failed write';
    chdir $old;
}

done_testing;
