package Archive::Multics;

use strict;
use warnings;

our $VERSION = '0.07';

use Carp qw(croak);
use Fcntl qw(:mode);
use File::Basename qw(basename dirname);
use File::Temp ();
use MIME::Base64 ();
use Compress::Raw::Zlib ();
use IO::Compress::Gzip ();
use Digest::SHA ();
use POSIX ();
use Archive::Multics::Component;

# ---------------------------------------------------------------------------
# Format constants (archive_data_.alm, archive_header.incl.pl1)

use constant IDENT        => "\f\n\n\n\x0F\n\t\t";          # archive_data_$ident
use constant FENCE        => "\x0F\x0F\x0F\x0F\n\n\n\n";    # archive_data_$fence (= $header_end)
use constant HEADER_BEGIN => "\x0B\n\n\n\x0F\n\t\t";        # obsolete; never recognized
use constant HEADER_SIZE  => 100;                           # 25 words

# dense9 transfers (DENSE9.md): 8 nine-bit characters per 9 octets.
use constant MAX_BITS     => 9_400_320;                     # one 255K-word segment
use constant MAX_OCTETS   => 9 * int((9_400_320 + 71) / 72); # its dense9 size
use constant TRANSFER_WIDTH => 64;                          # base64 line width we write

# Seconds between 1901-01-01 00:00 GMT (Multics clock epoch) and 1970-01-01.
use constant MULTICS_EPOCH_OFFSET => 2_177_452_800;

# Error codes, named after the error_table_ entries archive_ returns, plus
# a few for conditions that only arise on Unix.
our %MESSAGES = (
    not_archive           => 'The segment is not an archive.',
    archive_fmt_err       => 'Format error encountered in archive segment.',
    no_component          => 'Component not found in archive.',
    namedup               => 'Component already in archive.',
    dupname               => 'Component name occurs more than once in archive.',
    entlong               => 'Component name is longer than 32 characters.',
    bad_name              => 'Invalid component name.',
    not_text              => 'Bit count is not a multiple of 9; component cannot be represented in text mode.',
    ninth_bit             => 'The archive contains 9-bit data, which the byte8 format cannot represent.',
    bad_transfer          => 'Not a valid base64 transfer file.',
    bad_gzip              => 'Not a valid gzip file.',
    bad_data              => 'Component data is not 9-bit characters.',
    bad_date              => 'Invalid date.',
    io                    => 'I/O error.',
);

our $error      = '';    # last error message (class-level, like Archive::Tar)
our $error_code = '';

# ---------------------------------------------------------------------------
# Construction and I/O

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        components => [],
        tz         => $opt{tz},                  # undef: local TZ
        pivot      => $opt{century_pivot} // 50, # RFC 5322; or 'window' (see _year)
        now        => $opt{now},                 # for tests: "current" Unix time
        validate   => $opt{validate} // 'full',  # 'full' or 'basic'
        salvage    => $opt{salvage},            # skip damage instead of failing
        force_enc  => $opt{encoding},           # 'byte8' or 'dense9': don't detect
        encoding   => $opt{encoding} // 'byte8', # how the archive is read/written
        transfer   => $opt{transfer} // 0,
        transfer_opt => $opt{transfer},         # explicit: overrides the form read
        error      => '',
        error_code => '',
    }, $class;
    croak "validate must be 'full' or 'basic'"
        unless $self->{validate} =~ /^(?:full|basic)$/;
    croak "century_pivot must be a number from 0 to 100 or 'window'"
        unless $self->{pivot} =~ /^(?:window|\d+)$/ && ($self->{pivot} eq 'window' || $self->{pivot} <= 100);
    croak "encoding must be 'byte8' or 'dense9'"
        if defined $opt{encoding} && $opt{encoding} !~ /^(?:byte8|dense9)$/;
    if (defined $opt{file}) {
        $self->read($opt{file}) or return;
    }
    return $self;
}

sub error      { ref $_[0] ? $_[0]{error}      : $error }
sub error_code { ref $_[0] ? $_[0]{error_code} : $error_code }

sub _fail {
    my ($self, $code, $detail) = @_;
    my $msg = $MESSAGES{$code} // $code;
    $msg .= " $detail" if defined $detail && length $detail;
    ($self->{error}, $self->{error_code}) = ($msg, $code);
    ($error, $error_code) = ($msg, $code);
    return;
}

sub _ok { my $self = shift; $self->{error} = $self->{error_code} = ''; return 1 }

sub read {
    my ($self, $path) = @_;
    open my $fh, '<:raw', $path or return $self->_fail(io => "$path: $!");
    local $/;
    my $buf = <$fh> // '';
    close $fh;
    $self->{path} = $path;
    return $self->read_string($buf);
}

# Reads byte8 (one octet per character), raw dense9 (8 characters packed
# in 9 octets), or a dense9 transfer file ("-dense9 N" line, then base64),
# as detected from the first octets unless 'encoding' was given to new().
sub read_string {
    my ($self, $buf) = @_;
    return $self->_read_gzip($buf) if substr($buf, 0, 2) eq "\x1f\x8b" && !$self->{in_gzip};
    $self->{gzip} = undef unless $self->{in_gzip};
    $self->{b64} = 0;
    my ($enc, $transfer, $d9raw) = ('byte8', 0, 0);
    my $force = $self->{force_enc} // '';
    $self->{warnings} = [];
    my $hi;    # dense9: the 9th bits, one octet (0 or 1) per character
    my ($tbits, $toct);
    if ($buf =~ /\A-(?:dense9 |sha256 |byte8\r?\n)/) {
        ($tbits, $toct) = $self->_decode_transfer($buf) or return;
    }
    if (defined $toct && !defined $tbits) {
        # Base64 of byte8 data (encode_base64 without -dense9: "-byte8"
        # and/or "-sha256" lines): an archive, or a gzip file. Read what
        # it holds.
        return $self->_fail(not_archive => 'It holds base64 of another base64 transfer.')
            if $toct =~ /\A-(?:dense9 |sha256 |byte8\r?\n)/;
        my $ok;
        {
            local $self->{force_enc} = $self->{force_enc} // 'byte8' unless substr($toct, 0, 2) eq "\x1f\x8b";
            $ok = $self->read_string($toct);
        }
        return unless $ok;
        $self->{b64} = 1;
        return $self->_ok;
    }
    if (defined $toct) {
        return $self->_fail(not_archive => 'It is a dense9 transfer file.') if $force eq 'byte8';
        my ($bits, $oct) = ($tbits, $toct);
        return $self->_fail(not_archive => "Bit count $bits is not a whole number of words.")
            if $bits % 36;
        $self->_check_pad($oct, $bits);
        ($buf, $hi) = _unpack9_split($oct, $bits / 9);
        ($enc, $transfer) = ('dense9', 1);
    }
    elsif ($force eq 'dense9' || ($force ne 'byte8' && length($buf) >= 9 && substr($buf, 0, 9) eq _dense9_ident())) {
        return $self->_fail(not_archive => 'It is ' . length($buf) . ' octets; one segment in dense9 form is at most '
            . MAX_OCTETS . '.') if length($buf) > MAX_OCTETS;
        if (length($buf) % 9) {
            return $self->_fail(not_archive => 'A raw dense9 file is a whole number of 9-octet groups.')
                unless $self->{salvage};
            $self->_warn('ignored ', length($buf) % 9, ' octets after the last 9-octet group');
        }
        ($buf, $hi) = _unpack9_split(substr($buf, 0, length($buf) - length($buf) % 9));
        ($enc, $d9raw) = ('dense9', 1);
    }
    local $self->{keep_warnings} = 1;
    my $comps = $self->_parse($buf, $d9raw, $hi) or return;
    $self->{components} = $comps;
    # The archive command never makes two components with the same name,
    # but joined or crafted archives can hold them. Say so: by name, only
    # the first can be found, and some keys act on all of them.
    my %n;
    $n{ $_->name }++ for @$comps;
    $self->_warn('component name "', _printable($_), "\" occurs $n{$_} times")
        for grep { $n{$_} > 1 } sort keys %n;
    ($self->{encoding}, $self->{transfer}) = ($enc, $transfer);
    $self->{transfer} = $self->{transfer_opt} if $enc eq 'dense9' && defined $self->{transfer_opt};
    return $self->_ok;
}

# The archive as written: byte8, raw dense9, or a dense9 transfer file,
# following the form it was read in (or set_encoding). Undef, with an
# error, if byte8 is asked for and the archive holds 9-bit data.
sub as_string {
    my $self = shift;
    my $s = join '', map { $_->_entry } @{ $self->{components} };
    return $self->_gzip_string($s) if $self->{gzip};
    if ($self->{encoding} eq 'dense9') {
        my $bits = 9 * length $s;
        return $self->_fail(io => "The archive is $bits bits; the limit is " . MAX_BITS . '.')
            if $bits > MAX_BITS;
        my $oct = _pack9($s, $bits);
        return $self->{transfer} ? _encode_transfer($oct, $bits) : $oct;
    }
    return $self->_fail(ninth_bit => 'Write it in dense9 instead.') if $s =~ /[^\x00-\xFF]/;
    utf8::downgrade($s);
    return $self->{transfer} ? _encode_transfer_byte8($s) : $s;
}

# A byte8 transfer, as encode_base64 writes it without -dense9: "-byte8",
# the SHA-256 of the octets (sha256 -byte8 of the segment), then base64.
sub _encode_transfer_byte8 {
    my ($oct) = @_;
    my $b64 = MIME::Base64::encode_base64($oct, '');
    $b64 =~ s/(.{1,${\ TRANSFER_WIDTH}})/$1\n/g;
    return "-byte8\n-sha256 " . Digest::SHA::sha256_hex($oct) . "\n$b64";
}

# ---------------------------------------------------------------------------
# gzip, as written and read by the Multics gzip and gunzip commands: one
# member; the payload is the archive as byte8 octets (BYTE8) or packed
# dense9 (DENSE9). The bit count comes from an "MU" extra subfield (read,
# never written: some gunzips mishandle an extra field), else from a stored
# name ending ".BITCOUNT.dense9", else nine bits to the octet.

use constant GZIP_OS_UNIX => 3;

sub is_gzip { $_[0]{gzip} ? 1 : 0 }
sub gzip_info { $_[0]{gzip} ? { %{ $_[0]{gzip} } } : undef }

# set_gzip(1, name => $entry, derivation => 'auto'|'byte8'|'dense9'), or
# set_gzip(0). The name is the Multics entry name stored in the file.
sub set_gzip {
    my ($self, $on, %o) = @_;
    unless ($on) { $self->{gzip} = undef; return $self->_ok }
    my $g = $self->{gzip} //= {};
    $g->{name} = $o{name} if defined $o{name};
    my $d = $o{derivation} // $g->{derivation_opt} // 'auto';
    croak "derivation must be 'auto', 'byte8' or 'dense9'" unless $d =~ /^(?:auto|byte8|dense9)$/;
    $g->{derivation_opt} = $d;
    $g->{transfer} = $o{transfer} ? 1 : 0 if exists $o{transfer};
    return $self->_ok;
}

sub _gzip_string {
    my ($self, $s) = @_;
    my $g = $self->{gzip};
    my $d = $g->{derivation_opt} // 'auto';
    my $ninth = $s =~ /[^\x00-\xFF]/;
    # The Multics rule: BYTE8 when it loses nothing, DENSE9 otherwise.
    $d = $ninth ? 'dense9' : 'byte8' if $d eq 'auto';
    my $bits = 9 * length $s;
    return $self->_fail(io => "The archive is $bits bits; the limit is " . MAX_BITS . '.')
        if $bits > MAX_BITS;
    my ($payload, $name);
    my $entry = $g->{name} // (defined $self->{path} ? basename($self->{path}) : 'archive');
    $entry =~ s/\.gz\z//;
    if ($d eq 'dense9') {
        $payload = _pack9($s, $bits);
        $name = "$entry.$bits.dense9";
    }
    else {
        return $self->_fail(ninth_bit => 'Use the dense9 derivation instead.') if $ninth;
        utf8::downgrade($payload = $s);
        $name = $entry;
    }
    my $out;
    IO::Compress::Gzip::gzip(\$payload => \$out, Name => $name, Time => $self->{now} // time,
        OS_Code => GZIP_OS_UNIX, -Level => 9, Minimal => 0)
        or return $self->_fail(io => "gzip: $IO::Compress::Gzip::GzipError");
    $g->{derivation} = $d;
    $g->{stored_name} = $name;
    # With transfer => 1, the gzip file as encode_base64 would carry it:
    # "-byte8", "-sha256" (of the gzip octets), then base64.
    return $g->{transfer} ? _encode_transfer_byte8($out) : $out;
}

sub _read_gzip {
    my ($self, $buf) = @_;
    my $bad = sub { $self->_fail(bad_gzip => $_[0]) };
    return $bad->('It is too short.') if length($buf) < 18;
    my ($cm, $flg, $mtime) = unpack 'x2 C C V', $buf;
    return $bad->("Compression method $cm is not deflate.") unless $cm == 8;
    return $bad->('Reserved flag bits are set.') if $flg & 0xE0;
    my $p = 10;
    my ($mu, $fname);
    if ($flg & 4) {                         # FEXTRA
        return $bad->('The extra field is truncated.') if $p + 2 > length $buf;
        my $xlen = unpack 'v', substr($buf, $p, 2);
        $p += 2;
        return $bad->('The extra field is truncated.') if $p + $xlen > length $buf;
        my $x = substr($buf, $p, $xlen);
        $p += $xlen;
        my $q = 0;
        while ($q + 4 <= length $x) {       # walk the subfields
            my ($id, $len) = unpack 'a2 v', substr($x, $q, 4);
            last if $q + 4 + $len > length $x;
            if ($id eq 'MU' && $len >= 6 && !$mu) {
                my ($ver, $der, $bc) = unpack 'C C V', substr($x, $q + 4, 6);
                return $bad->("The MU subfield has an unknown derivation ($der).") if $der > 1;
                $mu = { derivation => $der ? 'dense9' : 'byte8', bits => $bc };
            }
            $q += 4 + $len;
        }
    }
    for my $f (8, 16) {                     # FNAME, FCOMMENT: NUL-terminated
        next unless $flg & $f;
        my $z = index($buf, "\0", $p);
        return $bad->('The header is truncated.') if $z < 0;
        $fname = substr($buf, $p, $z - $p) if $f == 8;
        $p = $z + 1;
    }
    $p += 2 if $flg & 2;                    # FHCRC
    return $bad->('The header is truncated.') if $p > length $buf;

    # Inflate, a slice at a time, stopping past one segment's worth.
    my ($inf, $st) = Compress::Raw::Zlib::Inflate->new(
        -WindowBits => -Compress::Raw::Zlib::MAX_WBITS(), -ConsumeInput => 1, -AppendOutput => 1);
    return $bad->("inflate: $st") unless $inf;
    my ($in, $out, $end) = (substr($buf, $p), '', 0);
    while (length $in) {
        my $slice = substr($in, 0, 4096, '');
        $st = $inf->inflate($slice, $out);
        if ($st == Compress::Raw::Zlib::Z_STREAM_END()) { $in = $slice . $in; $end = 1; last }
        return $bad->("The compressed data is damaged ($st).") if $st != Compress::Raw::Zlib::Z_OK()
            && $st != Compress::Raw::Zlib::Z_BUF_ERROR();
        return $bad->('It expands to more than one segment (' . MAX_OCTETS . ' octets).')
            if length($out) > MAX_OCTETS;
    }
    return $bad->('The compressed data is truncated.') unless $end;
    return $bad->('It expands to more than one segment (' . MAX_OCTETS . ' octets).')
        if length($out) > MAX_OCTETS;
    return $bad->('The trailer is truncated.') if length($in) < 8;
    my ($crc, $isize) = unpack 'V V', substr($in, 0, 8, '');
    return $bad->('The check value (CRC-32) does not match.')
        unless $crc == Compress::Raw::Zlib::crc32($out);
    return $bad->('The length in the trailer does not match.') unless $isize == length($out) % 2**32;
    return $bad->('It has more than one member, or data after the first.') if $in =~ /[^\0]/;
    return $bad->('It holds another gzip file; decompress only once.')
        if substr($out, 0, 2) eq "\x1f\x8b";

    # Where the bit count comes from, in gunzip's order.
    my ($der, $bits, $src);
    if ($mu) { ($der, $bits, $src) = ($mu->{derivation}, $mu->{bits}, 'MU subfield') }
    elsif (defined $fname && $fname =~ /\.([0-9]{1,8})\.dense9\z/) {
        ($der, $bits, $src) = ('dense9', $1 + 0, 'stored name');
    }
    if (defined $der) {
        my $want = $der eq 'dense9' ? 9 * int(($bits + 71) / 72) : $bits / 9;
        return $bad->("Its $src gives bit count $bits ($der), which is "
            . ($der eq 'dense9' ? "$want octets" : 'not a whole number of octets')
            . '; it holds ' . length($out) . '.')
            if $want != length($out) || ($der eq 'byte8' && $bits % 9);
    }
    my $inner;
    {
        local $self->{in_gzip}   = 1;
        local $self->{force_enc} = $der if defined $der;
        $inner = $self->read_string($out);
    }
    return unless $inner;
    return $bad->("Its $src gives bit count $bits, but the archive is " . $self->bit_count . ' bits.')
        if defined $bits && $bits != $self->bit_count;
    my $entry = $fname;
    $entry =~ s/\.[0-9]{1,8}\.dense9\z// if defined $entry;
    $self->{gzip} = { name => $entry, stored_name => $fname, mtime => $mtime,
                      derivation => $self->{encoding}, bits_from => $src };
    return $self->_ok;
}

# The archive's bit count as it would be written: what Multics records for
# the segment (status -bit_count), and what a transfer header carries.
sub bit_count {
    my $self = shift;
    my $n = 0;
    $n += length $_->_entry for @{ $self->{components} };
    return 9 * $n;
}

sub encoding { $_[0]{encoding} }
sub is_transfer { $_[0]{transfer} || $_[0]{b64} ? 1 : 0 }

# set_encoding('byte8') or set_encoding('dense9', transfer => 0|1).
sub set_encoding {
    my ($self, $enc, %o) = @_;
    croak "encoding must be 'byte8' or 'dense9'" unless $enc =~ /^(?:byte8|dense9)$/;
    $self->{encoding} = $enc;
    $self->{transfer} = $o{transfer} // 0;
    return 1;
}

# ---------------------------------------------------------------------------
# dense9: bit packing and the transfer format

# Pack characters (ordinals 0-511) into big-endian 9-bit fields, keep the
# first $bits bits, and pad with zero bits to a multiple of 72.
sub _pack9 {
    my ($chars, $bits) = @_;
    croak 'internal error: character above 0777 in 9-bit data' if $chars =~ /[^\x00-\x{1FF}]/;
    my $b = join '', map { sprintf '%09b', ord } split //, $chars;
    $bits //= length $b;
    $b = substr($b, 0, $bits);
    $b .= '0' x ((72 - length($b) % 72) % 72);
    return pack 'B*', $b;
}

# Unpack octets into $n 9-bit characters (all whole ones by default).
sub _unpack9 {
    my ($oct, $n) = @_;
    my ($lo, $hi) = _unpack9_split($oct, $n);
    return _join9($lo, $hi);
}

# Unpack into two octet strings: the low 8 bits of each character, and its
# 9th bit (0 or 1). The parser walks the first, which is an ordinary octet
# string (a string of wide characters would make every substr at an
# offset cost time proportional to its length).
sub _unpack9_split {
    my ($oct, $n) = @_;
    my $b = unpack 'B*', $oct;
    $n //= int(length($b) / 9);
    my @f = unpack "(a1a8)$n", $b;
    my $hi = pack 'C*', map { $f[2 * $_] } 0 .. $n - 1;
    my $lo = pack '(B8)*', map { $f[2 * $_ + 1] } 0 .. $n - 1;
    return ($lo, $hi);
}

# Characters from low octets and 9th bits; a plain octet string if no 9th
# bit is set.
sub _join9 {
    my ($lo, $hi) = @_;
    return $lo unless defined $hi && $hi =~ /[^\0]/;
    my @h = unpack 'C*', $hi;
    my $i = 0;
    return join '', map { chr($_ + 256 * $h[$i++]) } unpack 'C*', $lo;
}

# archive_data_$ident is char (8) aligned: exactly one 72-bit group, so its
# dense9 form is a fixed 9-octet string.
{
    my $ident9;
    sub _dense9_ident { $ident9 //= _pack9(IDENT) }
}

sub _encode_transfer {
    my ($oct, $bits) = @_;
    my $b64 = MIME::Base64::encode_base64($oct, '');
    $b64 =~ s/(.{1,${\ TRANSFER_WIDTH}})/$1\n/g;
    # As encode_base64 -dense9 writes it: the bit count, then the SHA-256
    # of the octets (which is sha256 -dense9 of the segment).
    return "-dense9 $bits\n-sha256 " . Digest::SHA::sha256_hex($oct) . "\n$b64";
}

# The header lines of a base64 transfer, as encode_base64 writes them:
# "-dense9 <bit count>" or "-byte8", and/or "-sha256 <64 hex digits>",
# one per line, in
# either order. Returns (\%h, $offset of the body), () if the data does not
# begin with one, or undef with an error if the header block is malformed.
sub _transfer_headers {
    my ($self, $buf) = @_;
    return () unless $buf =~ /\A-(?:dense9 [0-9]{1,8}|sha256 [0-9A-Fa-f]{64}|byte8)\r?\n/;
    my (%h, $cr);
    pos($buf) = 0;
    while ($buf =~ /\G-([a-z0-9]+)(?: ([^\r\n]*?))?(\r?)\n/gc) {
        my ($k, $v) = ($1, $2 // '');
        $cr ||= $3;
        return $self->_fail(bad_transfer => "The header line \"-$k\" appears twice.") if exists $h{$k};
        if ($k eq 'byte8') {
            return $self->_fail(bad_transfer => 'The "-byte8" line takes no value.') if length $v;
            $h{byte8} = 1;
        }
        elsif ($k eq 'dense9') {
            return $self->_fail(bad_transfer => 'The "-dense9" line must give a bit count.')
                unless $v =~ /\A[0-9]{1,8}\z/;
            $h{dense9} = $v + 0;
        }
        elsif ($k eq 'sha256') {
            return $self->_fail(bad_transfer => 'The "-sha256" line must give 64 hexadecimal digits.')
                unless $v =~ /\A[0-9A-Fa-f]{64}\z/;
            $h{sha256} = lc $v;
        }
        else { return $self->_fail(bad_transfer => 'Unknown header line "-' . _printable($k) . '".') }
    }
    my $off = pos($buf) // 0;
    return $self->_fail(bad_transfer => 'Unknown header line "' . _printable(substr($buf, $off, 20)) . '".')
        if substr($buf, $off, 1) eq '-';
    return $self->_fail(bad_transfer => 'It has both "-byte8" and "-dense9" lines.')
        if $h{byte8} && defined $h{dense9};
    $self->_warn('the header lines end in CR LF; decode_base64 on Multics requires LF') if $cr;
    return (\%h, $off);
}

# Parse a transfer file ("-dense9 N", LF, base64): returns (N, octets), or
# an empty list with an error. The octet count must be exactly
# 9 * ceil(N / 72), as decode_base64 requires, so a truncated transfer is
# caught.
# Returns (N, octets) for a dense9 transfer, (undef, octets) for one with
# only a "-sha256" line (byte8 data: an archive, or a gzip file), or an
# empty list with an error. With "-dense9", the octet count must be exactly
# 9 * ceil(N / 72), as decode_base64 requires, so a truncated transfer is
# caught; with "-sha256", the octets must have that digest.
sub _decode_transfer {
    my ($self, $buf) = @_;
    my ($h, $off) = $self->_transfer_headers($buf);
    return unless $h;
    my $bits = $h->{dense9};
    return $self->_fail(bad_transfer => "Bit count $bits is more than one segment (" . MAX_BITS . ').')
        if defined $bits && $bits > MAX_BITS;
    my $body = substr $buf, $off;
    $body =~ s/\s+//g;
    return $self->_fail(bad_transfer => 'The body contains characters that are not base64.')
        if $body =~ m{[^A-Za-z0-9+/=]};
    my $oct;
    if (defined $bits) {
        my $want = 9 * int(($bits + 71) / 72);
        return $self->_fail(bad_transfer => 'Its body holds ' . int(length($body) * 3 / 4)
            . " octets; a bit count of $bits needs $want (truncated or damaged?).")
            unless length($body) == $want / 3 * 4;
        $oct = MIME::Base64::decode_base64($body);
        return $self->_fail(bad_transfer => 'It holds ' . length($oct)
            . " octets; a bit count of $bits needs $want (truncated or damaged?).")
            unless length($oct) == $want;
    }
    else {
        return $self->_fail(bad_transfer => 'The body is more than one segment.')
            if length($body) > 4 * int((MAX_OCTETS + 2) / 3);
        $oct = MIME::Base64::decode_base64($body);
    }
    return $self->_fail(bad_transfer => 'The SHA-256 of the data does not match its "-sha256" line'
        . ' (damaged in transfer?).')
        if defined $h->{sha256} && Digest::SHA::sha256_hex($oct) ne $h->{sha256};
    return ($bits, $oct);
}

# Warn if any of the pad bits after the first $bits are not zero.
sub _check_pad {
    my ($self, $oct, $bits) = @_;
    my $b = unpack 'B*', $oct;
    $self->_warn('pad bits after the bit count are not all zero')
        if substr($b, $bits) =~ /1/;
}

# The data to archive from a source file's contents: a dense9 transfer file
# (e.g. an extracted object segment) goes in with its exact bit count and
# 9th bits; anything else is octets, one per character. Returns
# ($data, %attributes), or an empty list with an error for a malformed
# transfer file.
#
# With bits => N, the contents are raw dense9 octets holding a component of
# bit count N (a raw dense9 file records no bit count): they must be
# exactly 9 * ceil(N / 72) octets.
sub source_data {
    my ($self, $contents, %o) = @_;
    $self->{source_warnings} = [];
    if (defined(my $bits = $o{bits})) {
        return $self->_fail(bad_data => "Bit count \"$bits\" is not a number from 0 to " . MAX_BITS . '.')
            unless $bits =~ /^[0-9]+$/ && $bits <= MAX_BITS;
        my $want = 9 * int(($bits + 71) / 72);
        return $self->_fail(bad_data => 'The file is a dense9 transfer file, which'
            . ' records its own bit count; give it without a bit count.')
            if $self->_transfer_contents_is($contents);
        return $self->_fail(bad_data => 'The file is ' . length($contents)
            . " octets; raw dense9 data of bit count $bits is $want.")
            unless length($contents) == $want;
        local $self->{warnings} = [];
        $self->_check_pad($contents, $bits);
        $self->{source_warnings} = [ @{ $self->{warnings} } ];
        return (_unpack9($contents, int(($bits + 8) / 9)), bit_count => $bits + 0);
    }
    my @t = $self->_transfer_contents($contents);
    return if @t == 1;
    return ($t[1], bit_count => $t[0]) if @t;
    return ($contents);
}

# Is this data (e.g. a file's contents) a dense9 transfer? Returns
# (bits, characters) if so, () if it is not one, and undef on a malformed
# transfer (with an error).
# Only a first line of exactly "-dense9 <digits>" makes it one; a text file
# that merely starts with "-dense9 " is text.
sub _transfer_contents_is {
    my ($self, $data) = @_;
    return $data =~ /\A(?:-sha256 [0-9A-Fa-f]{64}\r?\n)?-dense9 [0-9]{1,8}\r?\n/ ? 1 : 0;
}

sub _transfer_contents {
    my ($self, $data) = @_;
    # A component transfer has a "-dense9" line (and perhaps "-sha256");
    # base64 with only a digest is stored as it is, not decoded.
    return () unless $self->_transfer_contents_is($data);
    local $self->{warnings} = [];
    my ($bits, $oct) = $self->_decode_transfer($data) or return undef;
    $self->_check_pad($oct, $bits);
    $self->{source_warnings} = [ @{ $self->{warnings} } ];
    return ($bits, _unpack9($oct, int(($bits + 8) / 9)));
}

# Write atomically: build a temp file in the target directory and rename it
# over the original, keeping the original's permissions.
sub write {
    my ($self, $path) = @_;
    $path //= $self->{path} // croak "no path given";
    my $out = $self->as_string;
    return unless defined $out;
    my $dir = dirname($path);
    my $mode;
    if (my @st = stat $path) { $mode = S_IMODE($st[2]) }
    else                     { $mode = 0666 & ~umask }
    my $tmp = eval { File::Temp->new(DIR => $dir, TEMPLATE => '.archive.XXXXXXXX', UNLINK => 0) }
        or return $self->_fail(io => "$dir: cannot create temporary file: $@");
    binmode $tmp;
    my $ok = print {$tmp} $out;
    $ok &&= close $tmp;
    unless ($ok && chmod($mode, $tmp->filename) && rename($tmp->filename, $path)) {
        my $err = $!;
        unlink $tmp->filename;
        return $self->_fail(io => "$path: $err");
    }
    $self->{path} = $path;
    return $self->_ok;
}

# ---------------------------------------------------------------------------
# Parsing, following archive_.pl1 (CHECK_ARCHIVE, NEXT_HEADER_PTR,
# GET_COMPONENT_INFO, GET_ALL_COMPONENT_INFO), plus two relaxations:
#
# - The MIT Multics source site appends Bull's copyright notice to its
#   downloads as a mangled pseudo-component ("bull_copyright_notice.txt",
#   with DOS line endings). It is recognized wherever a header is expected
#   and ignored, with a warning.
# - With salvage => 1, damage is skipped rather than fatal: components
#   without word padding (e.g. NULs lost in transfer), junk between
#   components, a truncated last component, and trailing data.

sub _mit_notice_at {
    my ($buf, $pos) = @_;
    return substr($buf, $pos, 200)
        =~ /\A[\r\n]*\f[\r\n\t\x0F]*[ \t]*bull_copyright_notice\.txt[ \t]/;
}

# Check the header at $pos. Returns a hash of its fields, or an error string.
sub _header_at {
    my ($self, $buf, $pos, $hi) = @_;
    return 'Fewer than 25 words remain for a header.' if length($buf) - $pos < HEADER_SIZE;
    my %h;
    my $hd = substr $buf, $pos, HEADER_SIZE;
    @h{qw(begin pad1 name timeup mode time pad bcf end)} =
        map { substr $hd, $_->[0], $_->[1] } [0, 8], [8, 4], [12, 32], [44, 16], [60, 4],
                                            [64, 16], [80, 4], [84, 8], [92, 8];
    return 'Header does not begin with archive_data_$ident.' if $h{begin} ne IDENT;
    return 'Header contains a character with the 9th bit set.' if $hi && substr($hi, $pos, HEADER_SIZE) =~ /[^\0]/;
    return 'Header does not end with archive_data_$fence.'   if $h{end} ne FENCE;
    (my $bct = $h{bcf}) =~ s/^ +| +$//g;
    return 'Bit count field "' . _printable($h{bcf}) . '" is not a number.' unless $bct =~ /^[0-9]+$/;
    return 'Date field contains invalid characters.'
        if $h{timeup} =~ m{[^0-9 ./]} || $h{time} =~ m{[^0-9 ./]};
    return 'Mode field contains invalid characters.' if $h{mode} =~ /[^rewa ]/;
    ($h{cname} = $h{name}) =~ s/ +$//;
    $h{bc} = $bct + 0;
    if ($self->{validate} eq 'full') {
        my $cn = _printable($h{cname});
        return qq{($cn) Mode field "$h{mode}" is malformed.}
            unless $h{mode} =~ /^[r ][e ][w ][a ]$/;
        for ([modified => $h{time}], [updated => $h{timeup}]) {
            return qq{($cn) Date $_->[0] "$_->[1]" is invalid.}
                unless defined $self->_parse_date($_->[1]);
        }
    }
    return \%h;
}

sub _warn { my $self = shift; push @{ $self->{warnings} }, join '', @_ }

# Text from an archive, safe to print: characters outside printable ASCII
# as octal escapes, so a crafted field cannot send terminal controls.
sub _printable {
    my ($s) = @_;
    $s =~ s/([^\x20-\x7E])/sprintf '\\%03o', ord $1/ge;
    return $s;
}

sub _parse {
    my ($self, $buf, $d9raw, $hi) = @_;
    my $len     = length $buf;
    my $unit    = defined $hi ? 'characters' : 'bytes';
    # Characters $p .. $p+$l-1 (with their 9th bits, in dense9).
    my $chars_at = sub {
        my ($p, $l) = @_;
        my $s = substr $buf, $p, $l;
        return $s unless defined $hi;
        return _join9($s, substr $hi, $p, $l);
    };
    my $salvage = $self->{salvage};
    $self->{warnings} = [] unless $self->{keep_warnings};
    $self->{trailer}  = '';

    # Where the MIT notice starts, if there is one.
    my $mit;
    my $t = rindex $buf, 'bull_copyright_notice.txt';
    if ($t >= 0) {
        my $f = rindex $buf, "\f", $t;
        $mit = $f if $f >= 0 && $t - $f < 40;
    }
    my $mit_here = sub {
        my ($pos) = @_;
        return defined $mit && $pos <= $mit
            && substr($buf, $pos, $mit - $pos) =~ /\A[\r\n]*\z/ && _mit_notice_at($buf, $pos);
    };
    my $stop_mit = sub {
        my ($pos) = @_;
        $self->{trailer} = substr $buf, $pos;
        $self->_warn('ignored ', length($self->{trailer}), ' bytes after the last component',
            ' (the copyright notice appended by the MIT Multics source site)');
    };

    return [] if $len == 0;
    my $pos = 0;
    unless ($salvage) {
        return $self->_fail(not_archive => 'Length is not a whole number of words.')
            if $len % 4 && !defined $mit;
        return $self->_fail(not_archive => 'Shorter than one header.') if $len < HEADER_SIZE;
        return $self->_fail(not_archive => 'First header does not begin with archive_data_$ident.')
            if substr($buf, 0, 8) ne IDENT;
        return $self->_fail(not_archive => 'First header does not end with archive_data_$fence.')
            if substr($buf, 92, 8) ne FENCE;
    }
    else {
        $pos = index $buf, IDENT;
        if ($pos < 0) {
            return $self->_fail(not_archive => 'No component header found.');
        }
        $self->_warn("skipped $pos $unit before the first component header") if $pos;
    }

    my (@comps, $unpadded);
    while ($pos < $len) {
        # A raw dense9 file is padded to 72 bits: an archive with an odd
        # number of words ends with one zero pad word.
        last if $d9raw && $pos == $len - 4 && substr($buf, $pos, 4) eq "\0" x 4;
        if ($mit_here->($pos)) { $stop_mit->($pos); last }
        my $n = @comps + 1;
        my $where = "Component $n at word " . int($pos / 4) . '.';
        my $h = $self->_header_at($buf, $pos, $hi);

        unless (ref $h) {
            return $self->_fail(archive_fmt_err => "$where $h") unless $salvage;
            my $next = index $buf, IDENT, $pos + 1;
            while ($next >= 0 && !ref $self->_header_at($buf, $next, $hi)) {
                $next = index $buf, IDENT, $next + 1;
            }
            if ($next < 0) {
                $self->{trailer} = substr $buf, $pos;
                $self->_warn('ignored ', $len - $pos, " $unit at $pos ($h)");
                last;
            }
            $self->_warn('skipped ', $next - $pos, " $unit at $pos ($h)");
            $pos = $next;
            next;
        }

        my $bc     = $h->{bc};
        my $chars  = int($bc / 9);
        my $cchars = int(($bc + 8) / 9);                     # including a partial last one
        my $size   = HEADER_SIZE + 4 * int(($bc + 35) / 36);
        my $data_e = $pos + HEADER_SIZE + $cchars;           # end of the data
        my $at_boundary = sub { my $p = shift; $p == $len || substr($buf, $p, 8) eq IDENT || $mit_here->($p) };
        my $raw;

        my $padded = $pos + $size <= $len
            && substr($buf, $data_e, $size - HEADER_SIZE - $cchars) !~ /[^\0]/;

        if (!$salvage) {
            return $self->_fail(archive_fmt_err => "$where Component extends past the end of the archive.")
                if $pos + $size > $len;
            $raw = $chars_at->($pos, $size);
        }
        elsif ($padded && $at_boundary->($pos + $size)) {
            $raw = $chars_at->($pos, $size);
        }
        elsif ($data_e <= $len && $at_boundary->($data_e)) {    # no word padding
            $raw = $chars_at->($pos, HEADER_SIZE + $cchars) . ("\0" x ($size - HEADER_SIZE - $cchars));
            $size = HEADER_SIZE + $cchars;
            $unpadded++;
        }
        elsif ($pos + $size <= $len) {                          # padded, junk follows
            $raw = $chars_at->($pos, $size);
        }
        else {
            $self->_warn("dropped component $n ($h->{cname}): it extends past the end of the archive");
            $self->{trailer} = substr $buf, $pos;
            last;
        }

        push @comps, Archive::Multics::Component->_new(
            archive   => $self,
            name      => $h->{cname},
            bit_count => $bc,
            mode      => $h->{mode},
            timeup    => $h->{timeup},
            time      => $h->{time},
            data      => substr($raw, HEADER_SIZE, $chars),
            cdata     => substr($raw, HEADER_SIZE, $cchars),
            raw       => $raw,
            lossless  => defined $hi ? 1 : 0,
        );
        $pos += $size;
    }
    $self->_warn($unpadded == 1 ? '1 component was' : "$unpadded components were",
        ' not padded to a word boundary',
        ' (NUL bytes lost in transfer?)') if $unpadded;
    return \@comps;
}

# Warnings from the last read (recognized MIT trailer; salvage repairs).
sub warnings { @{ $_[0]{warnings} // [] } }

# Bytes after the last component that were ignored, if any.
sub trailer { $_[0]{trailer} // '' }

# ---------------------------------------------------------------------------
# Dates. Header dates are the first 16 characters of date_time_ output,
# "mm/dd/yy  hhmm.m", in the writer's local time zone with no zone recorded.
# They are interpreted here in $self->{tz} (default: the local zone).

sub _with_tz {
    my ($self, $code) = @_;
    return $code->() unless defined $self->{tz};
    my $had = exists $ENV{TZ};
    my $old = $ENV{TZ};
    $ENV{TZ} = $self->{tz};
    POSIX::tzset();
    my @r = eval { $code->() };
    my $err = $@;
    if ($had) { $ENV{TZ} = $old } else { delete $ENV{TZ} }
    POSIX::tzset();
    die $err if $err;
    return wantarray ? @r : $r[0];
}

# Four-digit year for a two-digit header year.
#
# century_pivot => N: fixed cutoff, yy >= N is 19yy. The default, 50, is
# the rule of RFC 5322 section 4.3 (00-49 = 20yy, 50-99 = 19yy), proposed
# for Multics as the fix for its year-2030 problem. 30 reproduces
# convert_date_to_binary_ on MR12.8 (CONVERT_TO_4_DIGIT_YEAR), which fails
# from 2030.
#
# century_pivot => 'window': the latest year ending in yy that is no more than one
# year after the current year. Header dates record past events, so this
# reads 1970s archives correctly until 2069 and keeps working after 2029,
# and past 2049.
sub _year {
    my ($self, $yy) = @_;
    return ($yy >= $self->{pivot} ? 1900 : 2000) + $yy unless $self->{pivot} eq 'window';
    my $limit = (localtime($self->{now} // time))[5] + 1900 + 1;
    my $year  = $limit - (($limit - $yy) % 100);
    return $year;
}

sub _parse_date {
    my ($self, $s) = @_;
    my ($mo, $d, $y, $h, $mi, $t) =
        $s =~ m{^(\d\d)/(\d\d)/(\d\d)  (\d\d)(\d\d)\.(\d)$} or return;
    return if $mo < 1 || $mo > 12 || $d < 1 || $d > 31 || $h > 23 || $mi > 59;
    my $year = $self->_year($y);
    my $sec  = 6 * $t;
    return $self->_with_tz(sub {
        my $e = POSIX::mktime($sec, $mi, $h, $d, $mo - 1, $year - 1900, 0, 0, -1);
        return unless defined $e;
        my @lt = localtime $e;    # reject dates like 02/31 that mktime normalizes
        return unless $lt[3] == $d && $lt[4] == $mo - 1;
        return $e;
    });
}

# Tenths of a minute are truncated, as date_time_ does (to be confirmed).
sub _format_date {
    my ($self, $epoch) = @_;
    return $self->_with_tz(sub {
        my @lt = localtime $epoch;
        sprintf '%02d/%02d/%02d  %02d%02d.%d',
            $lt[4] + 1, $lt[3], $lt[5] % 100, $lt[2], $lt[1], int($lt[0] / 6);
    });
}

sub unix_to_multics_clock { my $t = shift; return int(($t + MULTICS_EPOCH_OFFSET) * 1_000_000) }
sub multics_clock_to_unix { my $c = shift; return $c / 1_000_000 - MULTICS_EPOCH_OFFSET }

sub _build_header {
    my ($name, $timeup, $mode, $time, $bc) = @_;
    my $h = IDENT . '    ' . sprintf('%-32s', $name) . $timeup . $mode . $time
          . '    ' . sprintf('%8d', $bc) . FENCE;
    die "internal error: header length " . length($h) unless length $h == HEADER_SIZE;
    return $h;
}

# ---------------------------------------------------------------------------
# Queries (archive_ entries)

sub list_components { @{ $_[0]{components} } }
sub component_names { map { $_->name } @{ $_[0]{components} } }

sub _check_lookup_name {
    my ($self, $name) = @_;
    $name =~ s/ +$//;
    return $self->_fail(entlong => "\"$name\"") if length $name > 32;
    return $name;
}

sub _index_of {
    my ($self, $name) = @_;
    my $c = $self->{components};
    for my $i (0 .. $#$c) { return $i if $c->[$i]{name} eq $name }
    return;
}

# First component with this name (archive_$get_component[_info]).
sub get_component {
    my ($self, $name) = @_;
    defined($name = $self->_check_lookup_name($name)) or return;
    my $i = $self->_index_of($name);
    return $self->_fail(no_component => "\"$name\"") unless defined $i;
    $self->_ok;
    return $self->{components}[$i];
}
*get_component_info = \&get_component;

sub contains_component {
    my ($self, $name) = @_;
    $name =~ s/ +$//;
    return defined $self->_index_of($name);
}

# The component after $prev, or the first if $prev is undef
# (archive_$next_component[_info]). Returns undef at the end.
sub next_component {
    my ($self, $prev) = @_;
    my $c = $self->{components};
    return $c->[0] unless defined $prev;
    for my $i (0 .. $#$c) { return $c->[$i + 1] if $c->[$i] == $prev }
    croak "next_component: component is not in this archive";
}
*next_component_info = \&next_component;

# ---------------------------------------------------------------------------
# Changes

sub _check_new_name {
    my ($self, $name) = @_;
    return $self->_fail(bad_name => '(empty)') unless defined $name && length $name;
    return $self->_fail(entlong => "\"$name\"") if length $name > 32;
    return $self->_fail(bad_name => "\"$name\"")
        if $name =~ /[^\x20-\x7E]/ || $name =~ /[<>]/ || $name =~ /^ | $/;
    return 1;
}

sub _normalize_mode {
    my ($m) = @_;
    $m = 'rw' unless defined $m;
    return $m if $m =~ /^[r ][e ][w ] $/;
    $m = '' if $m eq 'null';
    croak "invalid access mode \"$m\"" if $m =~ /[^rew]/;
    return join('', map { index($m, $_) >= 0 ? $_ : ' ' } qw(r e w)) . ' ';
}

# $data is characters (octets for text). For 9-bit data, bit_count => N
# gives the exact bit count and $data holds ceil(N / 9) characters.
sub _make_component {
    my ($self, $name, $data, %a) = @_;
    $self->_check_new_name($name) or return;
    my $now = $a{time_updated} // time;
    my $bc  = $a{bit_count} // 9 * length($data);
    return $self->_fail(bad_data => "Bit count \"$bc\" is not a number from 0 to " . MAX_BITS . '.')
        unless $bc =~ /^[0-9]+$/ && $bc <= MAX_BITS;
    return $self->_fail(bad_data => "Bit count $bc does not match the data.")
        unless length($data) == int(($bc + 8) / 9);
    return $self->_fail(bad_data => 'A character is above octal 777.') if $data =~ /[^\x00-\x{1FF}]/;
    return Archive::Multics::Component->_new(
        archive   => $self,
        name      => $name,
        bit_count => $bc,
        cdata     => $data,
        data      => substr($data, 0, int($bc / 9)),
        lossless  => 1,
        mode      => _normalize_mode($a{access}),
        timeup    => $self->_format_date($now),
        time      => $self->_format_date($a{time_modified} // $now),
    );
}

# Replace the named component in place, or append it (key "r").
sub replace_component {
    my ($self, $name, $data, %a) = @_;
    # Which of several components with this name is meant is unknowable;
    # replacing them all with the same data is rarely wanted. Refuse.
    return $self->_fail(dupname => "\"$name\"")
        if (grep { $_->name eq $name } @{ $self->{components} }) > 1;
    my $new = $self->_make_component($name, $data, %a) or return;
    my $i = $self->_index_of($name);
    if (defined $i) { $self->{components}[$i] = $new }
    else            { push @{ $self->{components} }, $new }
    $self->_ok;
    return $new;
}

# Append only if not already present (key "a").
sub append_component {
    my ($self, $name, $data, %a) = @_;
    return $self->_fail(namedup => "\"$name\"") if $self->contains_component($name);
    return $self->replace_component($name, $data, %a);
}

# Replace only if the new modification time is later than the component's,
# compared at the header's tenth-of-a-minute resolution (key "u").
# Returns the new component, 0 if the archive copy is current, or undef on
# error (no_component if the name is not in the archive).
sub update_component {
    my ($self, $name, $data, %a) = @_;
    my $old = $self->get_component($name) or return;
    unless ($self->is_newer($a{time_modified} // time, $old)) { $self->_ok; return 0 }
    return $self->replace_component($name, $data, %a);
}

# True if Unix time $t is later than the component's "modified" date, compared
# at the header's tenth-of-a-minute resolution, as archive 'u' does. An
# unparseable component date counts as the beginning of time.
sub is_newer {
    my ($self, $t, $comp) = @_;
    my $new_t = $self->_parse_date($self->_format_date($t)) // 0;
    my $old_t = $comp->time_modified // 0;
    return $new_t > $old_t;
}

# Display form of a date, as written in headers.
sub format_date { my ($self, $t) = @_; return $self->_format_date($t) }

# Remove a specific component object (e.g. one of several with a name).
sub remove_component {
    my ($self, $comp) = @_;
    my $c = $self->{components};
    for my $i (0 .. $#$c) {
        if ($c->[$i] == $comp) { splice @$c, $i, 1; return $self->_ok }
    }
    croak "remove_component: component is not in this archive";
}

sub delete_component {
    my ($self, $name) = @_;
    defined($name = $self->_check_lookup_name($name)) or return;
    my $i = $self->_index_of($name);
    return $self->_fail(no_component => "\"$name\"") unless defined $i;
    splice @{ $self->{components} }, $i, 1;
    return $self->_ok;
}

# ---------------------------------------------------------------------------
# Files

# Attributes Multics would record for a source segment: its dtcm and access
# (Multics records the user's effective mode; here, the owner's bits).
sub file_attributes {
    my ($self, $path) = @_;
    my @st = stat $path or return $self->_fail(io => "$path: $!");
    return $self->_fail(io => "$path: Not a plain file.") unless -f _;
    # The owner's permission bits, the counterpart of the access that
    # extraction sets (-r and -w would always be true for root).
    my $access = ($st[2] & 0400 ? 'r' : '') . ($st[2] & 0100 ? 'e' : '') . ($st[2] & 0200 ? 'w' : '');
    return (time_modified => $st[9], access => $access);
}

# add_file($path, action => replace|append|update, name => ...)
sub add_file {
    my ($self, $path, %o) = @_;
    my %attr = $self->file_attributes($path) or return;
    open my $fh, '<:raw', $path or return $self->_fail(io => "$path: $!");
    local $/;
    my $data = <$fh> // '';
    close $fh;
    my @sd = $self->source_data($data, (defined $o{bits} ? (bits => $o{bits}) : ())) or return;
    ($data, my %extra) = @sd;
    %attr = (%attr, %extra);
    my $name   = $o{name} // basename($path);
    my $action = $o{action} // 'replace';
    return $self->replace_component($name, $data, %attr) if $action eq 'replace';
    return $self->append_component($name, $data, %attr)  if $action eq 'append';
    return $self->update_component($name, $data, %attr)  if $action eq 'update';
    croak "add_file: unknown action \"$action\"";
}

# Write a component to a file. Permissions come from the recorded access
# (r, e, w -> read, execute, write, filtered by umask; a blank mode means
# rw), and the file's mtime is set from the "modified" date.
# True if a component name can be used as a Unix file name as it stands:
# not empty, not "." or "..", and no "/" or NUL. Component names come from
# the archive, which may have been crafted, so they must be checked before
# they are used to name a file.
sub safe_file_name {
    my ($name) = @_;
    return defined $name && length $name && $name ne '.' && $name ne '..'
        && $name !~ m{[/\x00-\x1F\x7F]};
}

sub extract_component {
    my ($self, $name, $dest, %o) = @_;
    # A component object (from list_components) selects that component,
    # even if an earlier one has the same name.
    my $c = ref $name ? $name : $self->get_component($name);
    return unless $c;
    $name = $c->name;
    # A component that is not text is written in dense9 form: raw octets
    # (whose SHA-256 is sha256 -dense9 of the segment on Multics), or with
    # transfer => 1 a transfer file, which keeps the bit count. Only if all
    # its bits are known: not if it was read from a byte8 archive, where
    # the 9th bits were lost.
    my $binary = !$c->is_text;
    return $self->_fail(not_text => "\"$name\"")
        if $binary && !$c->lossless;
    unless (defined $dest) {
        return $self->_fail(io => "Component name \"$name\" cannot be used as a file name.")
            unless safe_file_name($c->name);
        $dest = $c->name;
    }
    if (-e $dest || -l $dest) {
        return $self->_fail(io => "$dest: File exists.") unless $o{force};
        unlink $dest or return $self->_fail(io => "$dest: $!");
    }
    my $m = $c->mode_field;
    $m = 'r w ' if $m eq '    ';
    my $perm = (substr($m, 0, 1) eq 'r' ? 0444 : 0)
             | (substr($m, 1, 1) eq 'e' ? 0111 : 0)
             | (substr($m, 2, 1) eq 'w' ? 0222 : 0);
    $perm &= ~umask;
    my $out = !$binary ? $c->data : $o{transfer} ? $c->transfer_string : $c->dense9;
    utf8::downgrade($out);
    sysopen my $fh, $dest, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600
        or return $self->_fail(io => "$dest: $!");
    binmode $fh;
    print {$fh} $out or return $self->_fail(io => "$dest: $!");
    close $fh            or return $self->_fail(io => "$dest: $!");
    my $mtime = $c->time_modified;
    utime $mtime, $mtime, $dest if defined $mtime;
    chmod $perm, $dest;
    $self->_ok;
    return $c;
}

1;

__END__

=head1 NAME

Archive::Multics - read and write Multics archive segments

=head1 SYNOPSIS

    use Archive::Multics;

    my $ar = Archive::Multics->new(tz => 'America/Phoenix');
    $ar->read('bound_foo_.s.archive') or die $ar->error;

    for my $c ($ar->list_components) {
        printf "%-32s %8d %s\n", $c->name, $c->bit_count, $c->time_updated_string;
    }

    my $c = $ar->get_component('foo.pl1') or die $ar->error;
    print $c->data;

    $ar->add_file('bar.pl1', action => 'update');
    $ar->write or die $ar->error;

=head1 DESCRIPTION

Archive::Multics reads and writes archives in the format used by the
Multics C<archive> command, as transferred to Unix either in text mode
("byte8": one octet per 9-bit Multics character, 9th bit lost) or in
"dense9" form (every bit kept, 8 characters in 9 octets), raw or as a
transfer file (C<encode_base64> output: header lines C<-dense9> I<N> or
C<-byte8>, and/or C<-sha256> I<digest>, in any order, then base64; the digest,
of the octets carried, is checked), and gzipped as the
Multics C<gzip> command writes it (see L</GZIP>). It follows the MR12.8
C<archive_> subroutine for reading and C<archive> for writing, so an
archive read and written without changes is byte-for-byte identical, and
unchanged components keep their original headers.

See F<docs/FORMAT.md> for the format, and L<archive(1)> for the
command and its deliberate differences from Multics.

=head1 GZIP

A file beginning with the gzip magic number is decompressed and read as
the Multics C<gunzip> command reads it. Its payload is the archive as
byte8 octets (BYTE8) or packed dense9 (DENSE9); the bit count comes from
an C<MU> extra subfield if there is one (version, derivation 0 = BYTE8 or
1 = DENSE9, 32-bit little-endian bit count; subfields are walked, and a
data length over six is allowed), else from a stored name ending
C<.>I<BITCOUNT>C<.dense9>, else nine bits to the octet. A bit count given
must match both the octet count and the archive's own. Only one member is
read, a gzip file inside a gzip file is refused, the expanded size is
limited to one segment, and the stored name is never used as a file name.

Written, an archive is gzipped as the Multics C<gzip> command does it:
BYTE8 unless the archive holds 9-bit data, DENSE9 otherwise, with the
stored name I<entry> (BYTE8) or I<entry>C<.>I<BITCOUNT>C<.dense9>
(DENSE9), no extra field, and operating system code 3 (Unix). An
archive read from a gzip file is written back as one.

=head1 CONSTRUCTOR

=head2 new(%options)

=over 4

=item tz

Time zone in which header dates are interpreted and written (they carry
no zone). Default: the local zone.

=item century_pivot

How two-digit header years get their century. A number is a fixed
cutoff: years at or above it are 19yy, below it 20yy. The default is 50,
the rule of RFC 5322 section 4.3, which reads every archive date from
1950 to 2049 correctly. 30 reproduces C<convert_date_to_binary_> on
Multics MR12.8, which misreads dates from 2030 on.

C<window> takes a two-digit year as the latest year ending in those
digits that is at most one year after the current year. It agrees with
50 for every date that can occur before 2050 and keeps working after
that, but its results depend on the current date.

=item validate

C<full> (default) applies every check C<archive_$get_component_info>
applies, including mode positions and date parsing. C<basic> applies
only the character-set checks C<archive_$get_component> applies.

=item salvage

Read damaged archives as far as possible instead of failing: components
without word padding (NUL bytes lost in transfer) are repaired, junk
before or between components is skipped, a truncated last component and
any trailing data are dropped. Each repair is reported by C<warnings>.
Writing such an archive produces a clean one.

=item encoding

C<byte8> or C<dense9>: read the archive in this form instead of
detecting it, and write it in this form. With C<dense9>, a transfer file
is still recognized by its first line; with C<byte8>, one is refused. Without it, the form is detected: a transfer
file, then the 9-octet dense9 form of C<archive_data_$ident> at offset 0,
otherwise byte8. New archives are byte8.

=item transfer

Whether a dense9 archive is written as a transfer file (true) or as raw
octets (false). If given, it applies whatever form a dense9 archive was
read in; if not, the form read is kept, and a new dense9 archive is
raw.

=item file

Read this archive immediately.

=back

=head1 METHODS

=head2 read($path), read_string($bytes)

Read an archive from a file or a string, in any of the three forms.
Returns false on error.

=head2 encoding, is_transfer, set_encoding($enc, transfer => $bool)

The form the archive is read in and will be written in (C<byte8> or
C<dense9>), whether it is written as a transfer file (dense9: C<-dense9>
and C<-sha256> lines; byte8: a C<-sha256> line; then base64), and a way
to change both. Writing byte8 fails with C<ninth_bit> if any
component has 9-bit data.

=head2 is_gzip, gzip_info, set_gzip($on, name => $entry, derivation => $d, transfer => $bool)

Whether the archive was read from, and will be written as, a gzip file;
what its header said (C<stored_name>, C<name>, C<mtime>, C<derivation>,
C<bits_from>); and a way to turn gzip on or off. C<name> is the Multics
entry name to store; C<derivation> is C<auto> (the default), C<byte8> or
C<dense9>; with C<transfer>, the gzip file is written as a base64
transfer (C<-byte8> and C<-sha256> lines, then base64), as
C<encode_base64> carries a C<.gz>. See L</GZIP>.

=head2 bit_count

The archive's bit count as it would be written: the segment's bit count
on Multics, and the number in a transfer file's first line.

=head2 source_data($contents, bits => $n)

What a source file's contents become as a component: a dense9 transfer
file gives its characters and C<bit_count =E<gt> N>; anything else is
octets; with C<bits>, the contents are raw dense9 data of that bit
count. Returns C<($data, %attributes)> for C<replace_component> and the
like, or an empty list (with an error) if a transfer file is malformed or
the length does not fit C<bits>.

=head2 write([$path]), as_string

C<write> replaces the file atomically (temporary file and rename),
keeping its permissions. Hard links to the old file are not updated.

=head2 list_components, component_names

All components (objects) or their names, in archive order.

=head2 get_component($name) (alias get_component_info)

Returns the first component with that name, or undef with
C<error_code> C<no_component>. (The archive command never makes two
components with the same name, but a joined or crafted archive can hold
them; reading such an archive gives a warning.) Names longer than 32 characters are an
error (C<entlong>), not truncated as C<archive_> does.

=head2 next_component($prev) (alias next_component_info)

The component after C<$prev>, or the first if C<$prev> is undef; undef
at the end.

=head2 contains_component($name)

True if a component has this name.

=head2 replace_component($name, $data, %attr)

Replace the component in place, or add it at the end (key C<r>).
Refused (C<dupname>) if more than one component has the name.

=head2 append_component($name, $data, %attr)

Add the component unless one with that name exists (key C<a>).

=head2 update_component($name, $data, %attr)

Replace the component only if C<time_modified> is later (key C<u>).

C<%attr>: C<time_modified> (Unix time), C<time_updated> (default now),
C<access> (C<"rew">, C<"rw">, C<"null"> ...; default C<"rw">).
C<update_component> returns 0 when the archive copy is current.

=head2 is_newer($unix_time, $component)

True if the time is later than the component's "modified" date at the
header's tenth-of-a-minute resolution (the C<u> key's test).

=head2 format_date($unix_time)

The 16-character header form, C<mm/dd/yy  hhmm.m>, in the archive's zone.

=head2 delete_component($name)

Delete the first component with this name.

=head2 remove_component($component)

Remove a particular component object.

=head2 add_file($path, action => 'replace'|'append'|'update', name => $name, bits => $n)

Add a file as a component, with its modification time and access.
The name defaults to the file's base name. A dense9 transfer file (such
as a binary component extracted earlier) is added with its exact bit
count and 9th bits. With C<bits>, the file is taken as raw dense9 data of
that bit count, and must be exactly C<9 * ceil(bits / 72)> octets.

=head2 extract_component($name_or_component, [$dest], force => 1, transfer => 1)

Write a component to a file (see L</DESCRIPTION> for permissions and
times). Given a component object (from C<list_components>), that
component is written, even if an earlier one has the same name. An existing file is replaced only with C<force>. A component
that is not text (9th bits set, or a bit count that is not a whole
number of characters) is written in dense9 form, as raw octets (whose
SHA-256 is C<sha256 -dense9> of the segment on Multics) or, with
C<transfer>, as a transfer file, which records the bit count so that the
file can be added back exactly. Either only if all its bits are known
(C<lossless>: read from a dense9 archive, or made from a file); a
component read from a byte8 archive, whose 9th bits were lost, is
refused with C<not_text>. Bits after the bit count in the last word are
written as zeros.
Without C<$dest>, the file is named after the component, and a name that
fails C<safe_file_name> is refused.

=head2 Archive::Multics::safe_file_name($name)

True if C<$name> can be used as a file name as it stands: not empty, not
C<.> or C<..>, and without C</> or NUL. Component names come from the
archive, which may have been crafted; check them with this before using
one to name a file.

=head2 warnings, trailer

C<warnings> lists what the last read ignored or repaired. C<trailer>
returns the bytes after the last component that were ignored.

Archives downloaded from the MIT Multics source site end with Bull's
copyright notice, appended as a malformed pseudo-component named
F<bull_copyright_notice.txt>. It is recognized without C<salvage>,
ignored with a warning, and not written back.

=head2 error, error_code

Also available as C<$Archive::Multics::error> and
C<$Archive::Multics::error_code>. Codes: C<not_archive>,
C<archive_fmt_err>, C<no_component>, C<namedup>, C<dupname>, C<entlong>,
C<bad_name>, C<not_text>, C<ninth_bit>, C<bad_transfer>, C<bad_gzip>,
C<bad_data>, C<io>.

=head1 COMPONENT METHODS

C<name>, C<bit_count>, C<length> (words), C<size> (characters),
C<is_text> (octets lose nothing), C<has_ninth_bits>, C<lossless>
(every bit known), C<data>,
C<dense9> (the component's bits, packed), C<transfer_string> (as a
dense9 transfer file), C<access>, C<readable>, C<executable>,
C<writable>, C<mode_field>, C<time_updated>, C<time_modified>
(Unix times), C<time_updated_string>, C<time_modified_string>
(raw header text), C<multics_time_updated>, C<multics_time_modified>
(Multics clock readings), C<header>.

=head1 OPENBSD PLEDGE AND UNVEIL

The module does not call L<pledge(2)> or L<unveil(2)> itself. A program
using it needs:

=over 4

=item *

C<rpath> and read access to the archive, for C<read>; also read access
to F</usr/share/zoneinfo> and F</etc/localtime>, since header dates are
converted with L<localtime(3)> and L<mktime(3)>.

=item *

C<wpath cpath fattr> and read/write/create access to the archive's
directory, for C<write> (a temporary file is created there, its mode set,
and renamed over the archive).

=item *

C<rpath> and read access to the file, for C<add_file>.

=item *

C<wpath cpath fattr> and write/create access to the destination
directory, for C<extract_component> (it creates the file and sets its
mode and times).

=back

Perl may load some modules on first use, so unveiling the directories in
C<@INC> read-only is advisable. The F<archive> command shows one way to do
all of this.

=head1 SEE ALSO

L<archive(1)>

=head1 AUTHOR

Jim Lippard

=head1 LICENSE

BSD 3-clause; see F<LICENSE>.

=cut
