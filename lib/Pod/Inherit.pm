package Pod::Inherit;
use warnings;
use strict;
use MRO::Compat;
our $DEBUG;
BEGIN {
  if ($DEBUG) {
    require Data::Dump::Streamer;
    Data::Dump::Streamer->import('Dump');
  }
}
use Sub::Identify;
use Pod::POM;

# Eww, monkeypatching.  Also, eww, replacing Perl's exception handling... poorly.
BEGIN {
  delete $Pod::POM::Node::{error};
}
sub Pod::POM::Node::error {
  my ($self, @rest) = @_;
  die "->error on Pod::POM::Node: @rest";
}

use Path::Class;
use Scalar::Util 'refaddr';
our $VERSION = '0.09';

=head1 NAME

Pod::Inherit - auto-create pod sections listing inherited methods

=head1 SYNOPSIS

  use Pod::Inherit;

  my $config = {
    out_dir => "/usr/src/perl/dbix-class/bast/DBIx-Class/0.08/trunk/doc,
    input_files => ['/usr/src/perl/dbix-class/bast/DBIx-Class/0.08/trunk/lib/'],
    skip_underscored => 1,
    class_map =>
      {
          "DBIx::Class::Relationship::HasMany" => "DBIx::Class::Relationship",
          "DBIx::Class::Relationship::HasOne" => "DBIx::Class::Relationship",
          "DBIx::Class::Relationship::BelongsTo" => "DBIx::Class::Relationship",
          "DBIx::Class::Relationship::ManyToMany" => "DBIx::Class::Relationship",
          "DBIx::Class::ResultSourceProxy" => "DBIx::Class::ResultSource",
          "DBIx::Class::ResultSourceProxy::Table" => "DBIx::Class::ResultSource",
      }
   };

  my $pi = Pod::Inherit->new( $config });
  $pi->write_pod;

=head1 DESCRIPTION

Ever written a module distribution with base classes and dependencies,
that had the pod for the various methods next to them, but hard to
find for the user of your modules? Ever wished POD could be
inheritable? Now it can.

This module will B<load> each of the classes in the list of input
files or directories given (default: C<@ARGV>), auto-discover which
methods each class provides, locate the actual class the method is
defined in, and produce a list in pod.

The resulting documentation is written out to a separate F<.pod> file
for each class (F<.pm>) encountered. The new file contains the
original POD from the Perl Module file, plus a section called
C<INHERITED METHODS>. The new section lists each class that the
current class inherits from, plus each method that can be used in the
current class as a result.

By default, methods beginning with an underscore, C<_> are skipped, as
by convention these are private methods.

=head2 METHODS

=head3 new

=over

=item Arguments: \%config

=item Return value: Pod::Inherit object

=back

Create a new Pod::Inherit object.

The config hashref can contain the following keys:

=over

=item skip_underscored

Default: true.

Do not display inherited methods that begin with an underscore. Set to
0 to display these as well.

=item input_files

Default: @ARGV

Arrayref of directories to search for F<.pm> files in, or a list of
F<.pm> files or a mixture.

=item out_dir

Default: Same as input_files

A directory to output the results into. If not supplied, the F<.pod>
file is created alongside the F<.pm> file it came from.

=item class_map

Default: none

A hashref of key/value string pairs. The keys represent classes in
which inherited methods will be found, the values are the classes
which it should link to in the new pod for the actual pod of the
methods.

Some distributions will already have noticed the plight of the users,
and documented the methods of some of their base classes further up
the inheritance chain. This config option lets you tell Pod::Inherit
where you moved the pod to.

=item force_permissions

ExtUtils::MakeMaker makes directories in blib read-only before we'd
like to write into them.  If this is set to a true value, we'll catch
permission denied errors, and try to make the directory writeable,
write the file, and then set it back to how it was before.

=back

=cut

sub new {
    my ($class, $args) = @_;
    $args = {
        'skip_underscored' => 1,
        'input_files' => [], # \@ARGV,
        'out_dir' => '',
        'class_map' => {},
        %{ $args || {} },
    };

    # Accept just a single filename in here -- OR A SINGLE Path::Class::File!
    $args->{input_files} = [$args->{input_files}] if not ref($args->{input_files}) eq 'ARRAY';

    my $self = bless($args, $class);
    return $self;
}

=head3 write_pod

=over

=item Arguments: none

=item Return value: none

=back

Run the pod creation stage.

=cut

sub write_pod {
  my ($self) = @_;
  
  my @targets = map {
    # The origtarget needs to be a directory; if it's a file, lie and claim to the rest
    # of the code that the user passed the directory containing this file.
    -d $_ ? [$_, $_] : [$_, Path::Class::File->new($_)->dir]
  } @{ $self->{input_files} };
  
  if (!@targets) {
    die "no targets";
  }
  
  while (@targets) {
    my ($target, $origtarget) = @{shift @targets};
    
    if ($DEBUG) {
      print "target=$target origtarget=$origtarget \n";
    }
    if (-d $target) {
      #print "-d\n";
      for my $newtarget (glob "$target/*") {
        unshift @targets, [$newtarget, $origtarget];
      }
      next;
    }
    if ($target =~ m/\.pm$/) {
      my $output_filename = Path::Class::File->new($target);
      if ($self->{out_dir}) {
        my $src_rel_orig = Path::Class::File->new($target)->relative($origtarget);
        $output_filename = $src_rel_orig->absolute($self->{out_dir});
      }
      my $ret = $output_filename->dir->mkpath;
      $output_filename =~ s/\.pm$/.pod/g;
      
      if($self->is_ours($output_filename)) {
        my $allpod = $self->create_pod($target);
        # Don't create the output file if there would be nothing in it!
        if (!$allpod) {
          # warn "Not creating empty file $output_filename\n";
          next;
        }
        
        my ($outfh, $oldperm);
        if ($DEBUG) {
          print "Writing $output_filename\n";
        }
        if (not open $outfh, '>', $output_filename) {
          if ($!{EACCES} and $self->{force_permissions} ) {
            unlink $output_filename;
            $output_filename = Path::Class::File->new($output_filename);
            $oldperm = (stat($output_filename->dir))[2];
            chmod $oldperm | 0200, $output_filename->dir 
              or die "Can't chmod ".$output_filename->dir." (or write into it)";
            open $outfh, '>', $output_filename or die "Can't open $output_filename for output (even after chmodding it's parent directory): $!";
          } else {
            die "Can't open $output_filename for output: $!";
          }
        }
        
        print $outfh $allpod;
        close($outfh);
        if (defined $oldperm) {
          chmod $oldperm, $output_filename->dir or die sprintf "Can't chmod %s back to 0%o", $output_filename->dir, $oldperm;
        }
      }
    }
  }
}

=pod

=head3 create_pod

The semantics of the C<class_map> argument need to go something like this:
- Something being in the class_map means that it will be documented, even if it starts with an underscore,
  or would otherwise be skipped.
- If the value is '1', then that's the only effect; it will be documented as being where it is.
- Otherwise, the value is the name of the module that it should be documented as if it was in.
- That module needs to show up, even if it isnt really in the inheritence tree at all.
- It should show up after the real modules that actually exist.

=cut

sub create_pod {
  my ($self, $src) = @_;
  my $class_map = $self->{class_map};
  # Canonize src; not only does not doing it produce a minor testing & prettiness problem
  # with the generated-data comment, far more importantly, it will keep require from
  # knowing that t/lib//foo and t/lib/foo are the same library, leading to "redefined"
  # warnings.
  # (And we need to make it a string again, because otherwise Pod::Parser gets confused.)
  $src = Path::Class::File->new($src)->stringify;

#  print "handle_pmfile($src)\n";
  
  my $tt_stash;
  
  my $classname = $self->filename_to_classname($src);
  if (!$classname) {
#    print "Couldn't find any package statement in $src\n";
    return;
  }
  $tt_stash->{classname}=$classname;

  # What we had here was hack on top of hack on top of hack, and still didn't work.
  # Fuckit.  Rewrite.
  local $|=1;
  my $class_as_filename = $classname;
  $class_as_filename =~ s!::!/!g;
  $class_as_filename .= ".pm";

  my $old_sig_warn = $SIG{__WARN__};
  local $SIG{__WARN__} = sub {
    my ($warning) = @_;
    $warning = "While working on $src: $warning";
    if ($old_sig_warn) {
      $old_sig_warn->($warning);
    } else {
      warn $warning;
    }
  };

  # Just like require, except without that pesky checking @INC thing,
  # but making sure we put the "right" thing in %INC.
  if (!exists $INC{$class_as_filename}) {
    if (!do $src) {
      my $err = $@;
      $err =~ s/ \(\@INC contains: .*\)//;
      print STDERR "Couldn't autogenerate documentation for $src: $err\n";
      return;
    }
  }
  # There's what is arguably a bug in perl itself lurking here: Foo.pm
  # dies during complation (IE not because it wasn't in @INC).  An
  # undef entry is left in %INC, but it's a READONLY undef, which
  # means that you can't just assign something else to the slot.
  if (!exists $INC{$class_as_filename}) {
    $INC{$class_as_filename} = $src;
  }
  
  my @isa_flattened = @{mro::get_linear_isa($classname)};
  
  # The isa tree seems to always begin with ourself.  Fair enough, but not
  # really wanted here.
  if ($isa_flattened[0] eq $classname) {
    shift @isa_flattened;
  }
  # We can't possibly find anything.  Just short-circuit and save ourselves a lot of trouble.
  if (!@isa_flattened) {
#    print "No parent classes\n";
    return;
  }
  $tt_stash->{isa_flattened} = \@isa_flattened;
  
  my %seen;
  my @derived;
  for my $parent_class (@isa_flattened) {
    # print "$parent_class\n";
    my $stash;
    {
      no strict 'refs';
      $stash = \%{"$parent_class\::"};
    }
    #if ($parent_class eq 'DBIx::Class::Relationship::HasOne') {
    #  Dump $stash;
    #}
    # There's something subtle and brain-melting going on here, but I think it works.
    my $local_config = $stash->{_pod_inherit_config};
    #print "Parent class $parent_class\n";
    #print "local config: \n";
    #Dump $local_config;
    #print "stringy local_config: ". $local_config. "\n";
    if (not exists $local_config->{skip_underscored}) {
      $local_config->{skip_underscored} = $self->{skip_underscored};
    }
    $local_config->{class_map} ||= $class_map;

    #print "post-defaulting local config: \n";
    #Dump $local_config;
    #print "skip_underscored: $local_config->{skip_underscored}\n";
    for my $globname (sort keys %$stash) {
      if ($local_config->{skip_underscored} and $globname =~ m/^_/) {
        next;
      }
      next if $seen{$globname};
      my $glob = $stash->{$globname};
      # Skip over things that aren't *code* globs, and cache entries.
      # (You might think that ->can will return false for non-code globs.  You'd be right.  It'll return true
      # for cache globs, and we want to skip those, so that we'll get them later.)
      my $exists;
      eval {
        # Don't next here directly, it'll cause a warning.
        $exists = exists &$glob;
      };
      if ($@) {
        # This specific error happens in DBIx::Class::Storage O_LARGEFILE, which is exported from IO::File
        # (I loose track of exactly how...)
        # Strange, considering O_LARGEFILE clearly *is* a subroutine...
        if ($@ =~ /Not a subroutine reference/) {
#          print "Got not a subref for $globname in $parent_class; it is probbaly imported accidentally.\n";
          $exists=0;
        } else {
          die "While checking if $parent_class $globname is a sub: $@";
        }
      }
      if (!$exists) {
        next;
      }

      # This should probably be in the template.
      my $nice_name;
      if ($globname eq '()') {
        $nice_name = 'I<overload table>';
      } elsif ($globname =~ m/^\((.*)/) {
        my $sort = $1;
        $sort =~ s/(.)/sprintf "E<%d>", ord $1/ge;
        $nice_name = "I<$sort overloading>";
      } else {
        $nice_name = $globname;
      }

      my $subref = $classname->can($globname);
      # Must not be a method, but some other strange beastie.
      next if !$subref;
      
      my $identify_name = Sub::Identify::stash_name($subref);
      # No reason to list it, really.  Then again, no reason not to,
      # really...  Yes there is.  It's just noise for anybody who actually knows perl.
      next if $identify_name eq 'UNIVERSAL';

      if ($identify_name ne $parent_class) {
        warn "Probable unexpected import of $nice_name from $identify_name into $parent_class"
          if $[ >= 5.010;
        next;
      }
      # print "$globname $nice_name $identify_name\n";
      # Note that this needs to happen *after* we determine if it's a cache entry, so that we *will* get them later.
      $seen{$globname}=$parent_class;
#      push @derived, { $parent_class => $nice_name };

      my $doc_parent_class = $parent_class;
      if ($local_config->{class_map}->{$parent_class}) {
        $doc_parent_class = $local_config->{class_map}->{$parent_class};
      }
      push @{$tt_stash->{methods}{$doc_parent_class}}, $nice_name;
      if (!grep {$_ eq $doc_parent_class} @isa_flattened) {
        # Hm, is there a better way of doing this?
        # We want to insert $doc_parent_class just before $parent_class in @isa_flattened.
        @isa_flattened = map {$_ eq $parent_class ? ($doc_parent_class, $_) : $_} @isa_flattened;
      }
    }
  }

  # There were parent classes, but we don't inherit any methods from them.  Don't insert an empty section.
  return if !keys %{$tt_stash->{methods}};
  
  # We used to use TT here, but TT doesn't like hash elements that have
  # names beginning with underscores.
  
  my $new_pod = <<'__END_POD__';
 =head1 INHERITED METHODS
 
 =over
 
__END_POD__
  
  # Indent, so doesn't show up as POD::Inherit's own POD.
  $new_pod =~ s/^ //mg;
  
  for my $class (@{$tt_stash->{isa_flattened}}) {
    next unless ($tt_stash->{methods}{$class});
    $new_pod .= "=item L<$class>\n\n";
    $new_pod .= join(", ", @{$tt_stash->{methods}{$class}}) . "\n\n";
  }

  $new_pod .= "=back\n\n=cut\n\n";

  print "New pod, before Pod::POMification: \n", $new_pod if $DEBUG;

  my $parser = Pod::POM->new;
  $new_pod = $parser->parse_text($new_pod)
    or die "Generated pod invalid?";

  # examine any warnings raised
  foreach my $warning ($parser->warnings()) {
    warn "Generated pod warning: $warning\n";
  }

  print "New pod, after Pod::POMification: \n"  if $DEBUG;
  print $new_pod->dump  if $DEBUG;

  $parser = Pod::POM->new;
  my $pod = $parser->parse_file($src)
    or die "Couldn't parse existing pod in $src: ".$parser->error;
  my $outstr = $self->get_inherit_header($classname, $src);
  
  # If set, we should go *before* the insertion point.
  # Otherwise we should go *after*.
  my $before;
  # What is the index of the section that we should be going before / after?
  my $insertion_point;

  my $i = 0;
  for (reverse $pod->content) {
    $i--;
    next unless $_->isa('Pod::POM::Node::Head1');
    
    my $title = $_->title;
    # This should be a list of all POD sections that should be "at the end of the file".
    # That is, things that we should go before.
    if (grep {$title eq $_} qw<LICENSE AUTHORS LIMITATIONS CONTRIBUTORS AUTHOR CAVEATS COPYRIGHT BUGS>, 'SEE ALSO', 'ALSO SEE', 'WHERE TO GO NEXT') {
      print "Fount head $title at index $i, going before that section\n"  if $DEBUG;
      $insertion_point = $i;
      $before = 1;
      last;
    } else {
      print "Found head $title at index $i, going after that section\n" if $DEBUG;
      $insertion_point = $i;
      $before = 0;
      last;
    }
  }
  
  
  if (!$insertion_point and $pod->content) {
    print "Going at end\n" if $DEBUG;
    $insertion_point = -1;
    $before = 0;
  }
  if (!$insertion_point) {
    print "Going as only section\n" if $DEBUG;
    $insertion_point = $pod;
    $outstr .= $new_pod;
    return $outstr;
  }

  if (not $before and $insertion_point == -1) {
    push @{$pod->{content}}, $new_pod;
  } elsif ($before) {
    splice(@{$pod->content}, $insertion_point-1, 0, $new_pod);
  } else {
    splice(@{$pod->content}, $insertion_point, 0, $new_pod);
  }

  $outstr .= $pod;

  return $outstr;
}

sub filename_to_classname {
  my ($self, $filename) = @_;

  open my $fh, "<", $filename or die "Can't open $filename: $!";
  
  while (<$fh>) {
    if (m/^package\s+([A-Za-z0-9_:]+);/) {
      return $1;
    }
  }
}

sub is_ours {
    my ($self, $outfn) = @_;

    # If it already exists, make sure it's one of ours
    if (-e $outfn) {
        open my $outfh, '<', $outfn
            or die "Can't open pre-existing $outfn for reading: $!";
        # FIXME: Should probably check past the first line for this, in case something else placed it's autogenerated marker before ours.
        if (<$outfh> ne "=for comment POD_DERIVED_INDEX_GENERATED\n") {
            warn "$outfn already exists, and it doesn't look like we generated it.  Skipping this file";
            return 0;
        }
#        print "Output file already exists, but seems to be one of ours, overwriting it\n";
    }

    return 1;
}


sub get_inherit_header {
    my ($self, $classname, $src) = @_;

    # Always give source paths as unix, so the tests don't need to
    # vary depending on what OS the user is running on.  This may be
    # construed as a bug.  If you care, patches are welcome, if they
    # fix the tests, too.
    $src = Path::Class::File->new($src)->as_foreign('Unix');

return  <<__END_HEADER__;
=for comment POD_DERIVED_INDEX_GENERATED
The following documentation is automatically generated.  Please do not edit
this file, but rather the original, inline with $classname
at $src
(on the system that originally ran this).
If you do edit this file, and don't want your changes to be removed, make
sure you change the first line.

=cut

__END_HEADER__

}

1;


=head2 Inline configuration

As well as passing explicit configuration options to L</new>, you can
also leave Pod::Inherit hints in your actual code. To define in a class
that all methods with a leading underscore should be included when
listing methods in that module, use the following snippet in your
code:

  our %_pod_inherit_config = ( skip_underscored => 0 );

=head2 $DEBUG

In order to get verbose debug information, simply set
C<$Pod::Inherit::DEBUG> to 1.  Please do this B<before> loading
Pod::Inherit, so that the requisite debugging modules can be loaded.
(Which aren't in the dependencies list, in order to keep the
dependencies list down slightly.  You can figure them out, it's not
hard.)

=head1 AUTHOR

James Mastros, theorbtwo <james@mastros.biz>

=head1 LICENSE

Copyright 2009, James Mastros.  Licensed under the same terms as
perl itself.

=cut
