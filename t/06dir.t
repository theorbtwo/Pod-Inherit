#!/usr/bin/perl
use lib 't/auxlib';
use Test::JMM;
use Test::More 'no_plan';
use Test::Differences;
use Test::NoWarnings;
use Test::Pod;
use Path::Class::Dir;

use_ok('Pod::Inherit');

use lib 't/lib';

## Remove all existing/old pod files in t/doc
my $dir = Path::Class::Dir->new('t/06dir-out');
$dir->rmtree;
$dir->mkpath;

## Run over entire t/lib dir
my $pi = Pod::Inherit->new({ 
                            input_files => ["t/lib/"],
                            out_dir => $dir,
                           });

isa_ok($pi, 'Pod::Inherit');
$pi->write_pod();

sub check_file {
  my ($outfile) = @_;
  (my $goldenfile = $outfile) =~ s!06dir-out!golden!;
  
  eq_or_diff(do {local (@ARGV, $/) = $outfile; scalar <> || 'NO OUTPUT?'},
             do {local (@ARGV, $/) = $goldenfile; scalar <> || 'NO GOLDEN'},
             "Running on directory: $outfile");
  pod_file_ok($outfile, "Running on directory: $outfile - Test::Pod");
}

# Check that for each output file, it matches the golden file...
my @todo = $dir;
while (@todo) {
  $_ = shift @todo;
  if (-d $_) {
    push @todo, glob("$_/*");
  } else {
    check_file($_);
  }
}

# ...and for each golden file, there is a coorosponding output file.
@todo = "t/golden";
while (@todo) {
  $_ = shift @todo;
  if (/~$/) {
    # Skip editor backup files, eh?
  } elsif (/\.was$/) {
    # ...and byhand backup files.
  } elsif (-d $_) {
    push @todo, glob("$_/*");
  } else {
    (my $outfile = $_) =~ s/golden/06dir-out/;
    ok(-e $outfile, "golden file $_ has matching output");
  }
}

## test lack of foo.txt in output dir


# foreach my $outfile (<t/06dir-out/*.pod>) {
#   my $origfile = Path::Class::Dir->new("t/golden")->file(Path::Class::File->new($outfile)->basename);
  
#   eq_or_diff( do { local (@ARGV, $/) = "$outfile"; scalar <> },
#               do { local (@ARGV, $/) = "$origfile"; scalar <> },
#               "Running on directory: $outfile - matches");
  
#   pod_file_ok("$outfile", "Running on directory: $outfile - Test::Pod passes");   
# }

# ## should we do this with no out_dir as well?

$dir->rmtree;
