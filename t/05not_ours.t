#!/usr/bin/perl
use lib 't/auxlib';
use Test::JMM;
use warnings;
use strict;
use Pod::Inherit;
use Test::More 'no_plan';
use Test::Differences;
# FIXME: Test that we actually generate the warning we are supposed to.
# use Test::NoWarnings;

use lib 't/lib';
my $pi = Pod::Inherit->new({
                            input_files => 't/lib/not_ours.pm',
                           });
$pi->write_pod();
my $orig = do {local (@ARGV, $/) = "t/lib/not_ours.pod"; scalar <>};
eq_or_diff(do {local (@ARGV, $/) = "t/lib/not_ours.pod"; scalar <>},
           $orig,
           "output file doesn't begin with our autogen marker");

