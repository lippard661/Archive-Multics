use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Archive::Multics',
    VERSION_FROM     => 'lib/Archive/Multics.pm',
    ABSTRACT_FROM    => 'lib/Archive/Multics.pm',
    AUTHOR           => 'Jim Lippard',
    LICENSE          => 'bsd',
    MIN_PERL_VERSION => '5.010',
    PREREQ_PM        => {},    # core modules only
    TEST_REQUIRES    => { 'Test::More' => 0 },
    EXE_FILES        => ['bin/archive'],
    # "make dist" makes Archive-Multics-VERSION.tgz
    dist             => { COMPRESS => 'gzip -9f', SUFFIX => '.gz', DIST_DEFAULT => 'tgz' },
);

sub MY::postamble {
    return <<'EOT';
tgz: tardist
	mv $(DISTVNAME).tar$(SUFFIX) $(DISTVNAME).tgz
EOT
}
