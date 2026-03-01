use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Srv::SDK',
    VERSION_FROM => 'lib/Srv/SDK.pm',
    ABSTRACT     => 'SDK shell for Perl bindings',
    AUTHOR       => 'srv-sdks team',
    LICENSE      => 'perl',
    PREREQ_PM    => {
        'Test::More' => 0,
    },
    MIN_PERL_VERSION => '5.20.0',
);
