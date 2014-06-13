use warnings;
use strict;

use Test::More;
use Test::EOL;
use Path::Class;

Test::EOL::all_perl_files_ok(
  qw/t lib/,
);

# Changes is not a "perl file", hence checked separately
Test::EOL::eol_unix_ok('Changes');

# Unfortunately, *.pod isn't a "perl file", either
my @pod_files;
dir('.')->recurse(callback => sub {
    my $file = shift;
    if (-f $file and $file =~ /\.pod$/i) {
        push @pod_files, $file->stringify;
    }
});
Test::EOL::eol_unix_ok($_) for (@pod_files);

# FIXME - Test::EOL declares 'no_plan' which conflicts with done_testing
# https://github.com/schwern/test-more/issues/14
#done_testing;
