#!/usr/bin/perl

# I certianly make no guarantee that this will run on 5.6.0, but I can
# guarantee that it certianly will not work on anything older.  Every
# reasonable effort is made to make it work on 5.8 -- however, you'll
# get better warnings in some cases when running under 5.10.

use 5.006;
use ExtUtils::MakeMaker;
use warnings;
use strict;

WriteMakefile(
              NAME          => 'Pod::Inherit',
              AUTHOR        => 'James Mastros <james@mastros.biz>',
              ABSTRACT_FROM => 'lib/Pod/Inherit.pm',
              VERSION_FROM  => 'lib/Pod/Inherit.pm',
              LICENSE       => 'perl',
              PREREQ_PM     => {
                                'MRO::Compat' => 0,
                                'Sub::Identify' => 0,
                                'Pod::Compiler' => 0,
                                'Path::Class' => 0,
                                'Test::Exception' => 0,
                                'Test::Differences' => 0,
                                'Test::Pod::Coverage' => 0,
                                'Test::NoWarnings' => 0,
                                'Test::More' => 0,
                                'Test::Pod' => 0,
                                
                               },
             );
