package OpenBSD::Pledge;
# Test stand-in: records calls in $ENV{SANDBOX_LOG} instead of pledging.
sub pledge { open my $f, '>>', $ENV{SANDBOX_LOG} or die; print $f "pledge @_\n"; 1 }
1;
