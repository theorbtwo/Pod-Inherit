#!/usr/bin/perl
use lib 't/auxlib';
use Test::JMM;
use warnings;
use strict;
use Test::Pod::Coverage tests=>2;
use Test::NoWarnings;

pod_coverage_ok('Pod::Inherit',
                { also_private => [
                                   'filename_to_classname',
                                   'get_inherit_header',
                                   'is_ours',
                                  ] }
               );
