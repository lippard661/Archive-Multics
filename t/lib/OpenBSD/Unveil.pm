package OpenBSD::Unveil;
# Test stand-in: records calls in $ENV{SANDBOX_LOG} instead of unveiling.
sub unveil { open my $f, '>>', $ENV{SANDBOX_LOG} or die; print $f @_ ? "unveil @_\n" : "unveil\n"; 1 }
1;
