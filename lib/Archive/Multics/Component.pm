package Archive::Multics::Component;

use strict;
use warnings;

our $VERSION = '0.04';

# A single archive component. Mirrors archive_component_info
# (archive_component_info.incl.pl1), plus the raw header text so that
# unmodified components can be written back byte for byte.
#
# Fields:
#   name           component name (trailing blanks removed)
#   bit_count      comp_bc
#   raw            header (100 bytes) + data + padding, exactly as read;
#                  undef for new or changed components
#   data           component contents in text mode (bit_count / 9 bytes)
#   mode           4-char mode field, e.g. "r w "
#   timeup         16-char "updated" field
#   time           16-char "modified" field
#   archive        the owning Archive::Multics (weak), for time conversion

use Scalar::Util qw(weaken);
use Carp qw(croak);

sub _new {
    my ($class, %f) = @_;
    my $self = bless {%f}, $class;
    weaken($self->{archive}) if $self->{archive};
    return $self;
}

sub name      { $_[0]{name} }
sub bit_count { $_[0]{bit_count} }

# comp_lth: size in words, derived from the bit count.
sub length    { int(($_[0]{bit_count} + 35) / 36) }

# Size in text-mode bytes, i.e. Multics characters.
sub size      { int($_[0]{bit_count} / 9) }

# True if the bit count is a whole number of 9-bit characters.
sub is_text   { $_[0]{bit_count} % 9 == 0 }

sub data      { $_[0]{data} }
*content = \&data;

sub mode_field          { $_[0]{mode} }
sub time_updated_string  { $_[0]{timeup} }
sub time_modified_string { $_[0]{time} }

# Access as in archive_component_info.access: r, e, w only.
sub readable   { substr($_[0]{mode}, 0, 1) eq 'r' }
sub executable { substr($_[0]{mode}, 1, 1) eq 'e' }
sub writable   { substr($_[0]{mode}, 2, 1) eq 'w' }

# Access as a Multics mode string: "rew", "rw", "r", "null".
sub access {
    my $self = shift;
    my $m = join '', grep { $_ ne ' ' } split //, substr($self->{mode}, 0, 3);
    return CORE::length($m) ? $m : 'null';
}

sub _archive {
    my $self = shift;
    return $self->{archive} || croak "component is not attached to an archive";
}

# Unix times, interpreted in the archive's time zone.
sub time_updated  { my $s = shift; $s->_archive->_parse_date($s->{timeup}) }
sub time_modified { my $s = shift; $s->_archive->_parse_date($s->{time}) }
*mtime = \&time_modified;

# Multics clock readings (microseconds since 1901-01-01 00:00 GMT).
sub multics_time_updated  { Archive::Multics::unix_to_multics_clock($_[0]->time_updated) }
sub multics_time_modified { Archive::Multics::unix_to_multics_clock($_[0]->time_modified) }

# Header bytes for this component: the original if unchanged, else rebuilt.
sub header {
    my $self = shift;
    return substr($self->{raw}, 0, 100) if defined $self->{raw};
    return Archive::Multics::_build_header(@$self{qw(name timeup mode time bit_count)});
}

# The full entry as written to the archive: header, data, NUL padding.
sub _entry {
    my $self = shift;
    return $self->{raw} if defined $self->{raw};
    my $data = $self->{data};
    my $pad  = (4 - CORE::length($data) % 4) % 4;
    return $self->header . $data . ("\0" x $pad);
}

1;
