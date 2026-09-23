package Archive::Multics;

use strict;
use warnings;

our $VERSION = '0.03';

use Carp qw(croak);
use Fcntl qw(:mode);
use File::Basename qw(basename dirname);
use File::Temp ();
use POSIX ();
use Archive::Multics::Component;

# ---------------------------------------------------------------------------
# Format constants (archive_data_.alm, archive_header.incl.pl1)

use constant IDENT        => "\f\n\n\n\x0F\n\t\t";          # archive_data_$ident
use constant FENCE        => "\x0F\x0F\x0F\x0F\n\n\n\n";    # archive_data_$fence (= $header_end)
use constant HEADER_BEGIN => "\x0B\n\n\n\x0F\n\t\t";        # obsolete; never recognized
use constant HEADER_SIZE  => 100;                           # 25 words

# Seconds between 1901-01-01 00:00 GMT (Multics clock epoch) and 1970-01-01.
use constant MULTICS_EPOCH_OFFSET => 2_177_452_800;

# Error codes, named after the error_table_ entries archive_ returns, plus
# a few for conditions that only arise on Unix.
our %MESSAGES = (
    not_archive           => 'The segment is not an archive.',
    archive_fmt_err       => 'Format error encountered in archive segment.',
    no_component          => 'Component not found in archive.',
    namedup               => 'Component already in archive.',
    entlong               => 'Component name is longer than 32 characters.',
    bad_name              => 'Invalid component name.',
    not_text              => 'Bit count is not a multiple of 9; component cannot be represented in text mode.',
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
        error      => '',
        error_code => '',
    }, $class;
    croak "validate must be 'full' or 'basic'"
        unless $self->{validate} =~ /^(?:full|basic)$/;
    croak "century_pivot must be a number from 0 to 100 or 'window'"
        unless $self->{pivot} =~ /^(?:window|\d+)$/ && ($self->{pivot} eq 'window' || $self->{pivot} <= 100);
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

sub read_string {
    my ($self, $buf) = @_;
    my $comps = $self->_parse($buf) or return;
    $self->{components} = $comps;
    return $self->_ok;
}

sub as_string {
    my $self = shift;
    return join '', map { $_->_entry } @{ $self->{components} };
}

# Write atomically: build a temp file in the target directory and rename it
# over the original, keeping the original's permissions.
sub write {
    my ($self, $path) = @_;
    $path //= $self->{path} // croak "no path given";
    my $dir = dirname($path);
    my $mode;
    if (my @st = stat $path) { $mode = S_IMODE($st[2]) }
    else                     { $mode = 0666 & ~umask }
    my $tmp = eval { File::Temp->new(DIR => $dir, TEMPLATE => '.archive.XXXXXXXX', UNLINK => 0) }
        or return $self->_fail(io => "$dir: cannot create temporary file: $@");
    binmode $tmp;
    my $ok = print {$tmp} $self->as_string;
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
    my ($self, $buf, $pos) = @_;
    return 'Fewer than 25 words remain for a header.' if length($buf) - $pos < HEADER_SIZE;
    my %h;
    @h{qw(begin pad1 name timeup mode time pad bcf end)} =
        unpack 'a8 a4 a32 a16 a4 a16 a4 a8 a8', substr($buf, $pos, HEADER_SIZE);
    return 'Header does not begin with archive_data_$ident.' if $h{begin} ne IDENT;
    return 'Header does not end with archive_data_$fence.'   if $h{end} ne FENCE;
    (my $bct = $h{bcf}) =~ s/^ +| +$//g;
    return qq{Bit count field "$h{bcf}" is not a number.} unless $bct =~ /^[0-9]+$/;
    return 'Date field contains invalid characters.'
        if $h{timeup} =~ m{[^0-9 ./]} || $h{time} =~ m{[^0-9 ./]};
    return 'Mode field contains invalid characters.' if $h{mode} =~ /[^rewa ]/;
    ($h{cname} = $h{name}) =~ s/ +$//;
    $h{bc} = $bct + 0;
    if ($self->{validate} eq 'full') {
        return qq{($h{cname}) Mode field "$h{mode}" is malformed.}
            unless $h{mode} =~ /^[r ][e ][w ][a ]$/;
        for ([modified => $h{time}], [updated => $h{timeup}]) {
            return qq{($h{cname}) Date $_->[0] "$_->[1]" is invalid.}
                unless defined $self->_parse_date($_->[1]);
        }
    }
    return \%h;
}

sub _warn { my $self = shift; push @{ $self->{warnings} }, join '', @_ }

sub _parse {
    my ($self, $buf) = @_;
    my $len     = length $buf;
    my $salvage = $self->{salvage};
    $self->{warnings} = [];
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
        $self->_warn("skipped $pos bytes before the first component header") if $pos;
    }

    my (@comps, $unpadded);
    while ($pos < $len) {
        if ($mit_here->($pos)) { $stop_mit->($pos); last }
        my $n = @comps + 1;
        my $where = "Component $n at word " . int($pos / 4) . '.';
        my $h = $self->_header_at($buf, $pos);

        unless (ref $h) {
            return $self->_fail(archive_fmt_err => "$where $h") unless $salvage;
            my $next = index $buf, IDENT, $pos + 1;
            while ($next >= 0 && !ref $self->_header_at($buf, $next)) {
                $next = index $buf, IDENT, $next + 1;
            }
            if ($next < 0) {
                $self->{trailer} = substr $buf, $pos;
                $self->_warn('ignored ', $len - $pos, " bytes at byte $pos ($h)");
                last;
            }
            $self->_warn('skipped ', $next - $pos, " bytes at byte $pos ($h)");
            $pos = $next;
            next;
        }

        my $bc     = $h->{bc};
        my $chars  = int($bc / 9);
        my $size   = HEADER_SIZE + 4 * int(($bc + 35) / 36);
        my $data_e = $pos + HEADER_SIZE + $chars;            # end of the data
        my $at_boundary = sub { my $p = shift; $p == $len || substr($buf, $p, 8) eq IDENT || $mit_here->($p) };
        my $raw;

        my $padded = $pos + $size <= $len
            && substr($buf, $data_e, $size - HEADER_SIZE - $chars) !~ /[^\0]/;

        if (!$salvage) {
            return $self->_fail(archive_fmt_err => "$where Component extends past the end of the archive.")
                if $pos + $size > $len;
            $raw = substr $buf, $pos, $size;
        }
        elsif ($padded && $at_boundary->($pos + $size)) {
            $raw = substr $buf, $pos, $size;
        }
        elsif ($data_e <= $len && $at_boundary->($data_e)) {    # no word padding
            $raw = substr($buf, $pos, HEADER_SIZE + $chars) . ("\0" x ($size - HEADER_SIZE - $chars));
            $size = HEADER_SIZE + $chars;
            $unpadded++;
        }
        elsif ($pos + $size <= $len) {                          # padded, junk follows
            $raw = substr $buf, $pos, $size;
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
            data      => substr($buf, $pos + HEADER_SIZE, $chars),
            raw       => $raw,
        );
        $pos += $size;
    }
    $self->_warn("$unpadded components were not padded to a word boundary",
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

sub _make_component {
    my ($self, $name, $data, %a) = @_;
    $self->_check_new_name($name) or return;
    my $now = $a{time_updated} // time;
    return Archive::Multics::Component->_new(
        archive   => $self,
        name      => $name,
        bit_count => 9 * length($data),
        mode      => _normalize_mode($a{access}),
        timeup    => $self->_format_date($now),
        time      => $self->_format_date($a{time_modified} // $now),
        data      => $data,
    );
}

# Replace the named component in place, or append it (key "r").
sub replace_component {
    my ($self, $name, $data, %a) = @_;
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

# Attributes Multics would record for a source segment: its dtcm and the
# user's effective access.
sub file_attributes {
    my ($self, $path) = @_;
    my @st = stat $path or return $self->_fail(io => "$path: $!");
    return $self->_fail(io => "$path: Not a plain file.") unless -f _;
    my $access = (-r _ ? 'r' : '') . (-x _ ? 'e' : '') . (-w _ ? 'w' : '');
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
sub extract_component {
    my ($self, $name, $dest, %o) = @_;
    my $c = $self->get_component($name) or return;
    return $self->_fail(not_text => "\"$name\"") unless $c->is_text;
    $dest //= $c->name;
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
    sysopen my $fh, $dest, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600
        or return $self->_fail(io => "$dest: $!");
    binmode $fh;
    print {$fh} $c->data or return $self->_fail(io => "$dest: $!");
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
Multics C<archive> command, as transferred to Unix in text mode (one
8-bit byte per 9-bit Multics character). It follows the MR12.8
C<archive_> subroutine for reading and C<archive> for writing, so an
archive read and written without changes is byte-for-byte identical, and
unchanged components keep their original headers.

See F<docs/FORMAT.md> for the format, and L<archive(1)> for the
command and its deliberate differences from Multics.

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

=item file

Read this archive immediately.

=back

=head1 METHODS

=head2 read($path), read_string($bytes)

Read an archive from a file or a string. Returns false on error.

=head2 write([$path]), as_string

C<write> replaces the file atomically (temporary file and rename),
keeping its permissions. Hard links to the old file are not updated.

=head2 list_components, component_names

All components (objects) or their names, in archive order.

=head2 get_component($name) (alias get_component_info)

Returns the first component with that name, or undef with
C<error_code> C<no_component>. Names longer than 32 characters are an
error (C<entlong>), not truncated as C<archive_> does.

=head2 next_component($prev) (alias next_component_info)

The component after C<$prev>, or the first if C<$prev> is undef; undef
at the end.

=head2 contains_component($name)

True if a component has this name.

=head2 replace_component($name, $data, %attr)

Replace the component in place, or add it at the end (key C<r>).

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

=head2 add_file($path, action => 'replace'|'append'|'update', name => $name)

Add a file as a component, with its modification time and access.
The name defaults to the file's base name.

=head2 extract_component($name, [$dest], force => 1)

Write a component to a file (see L</DESCRIPTION> for permissions and
times). An existing file is replaced only with C<force>.

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
C<archive_fmt_err>, C<no_component>, C<namedup>, C<entlong>,
C<bad_name>, C<not_text>, C<io>.

=head1 COMPONENT METHODS

C<name>, C<bit_count>, C<length> (words), C<size> (characters),
C<is_text>, C<data>, C<access>, C<readable>, C<executable>,
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
