package Pod::Inherit;
use warnings;
use strict;
use MRO::Compat;
use Sub::Identify;
use Pod::POM;
use List::MoreUtils qw(any firstidx);
use Carp;

our $DEBUG = 0;

# Eww, monkeypatching.  Also, eww, replacing Perl's exception handling... poorly.
BEGIN {
  delete $Pod::POM::Node::{error};
}
sub Pod::POM::Node::error {
  my ($self, @rest) = @_;
  print STDERR Carp::longmess;
  die "->error on Pod::POM::Node: @rest";
}

use Path::Class;
use Scalar::Util 'refaddr';
our $VERSION = '0.11';

=head1 NAME

Pod::Inherit - auto-create pod sections listing inherited methods

=head1 SYNOPSIS

  use Pod::Inherit;

  my $config = {
    out_dir          => "/usr/src/perl/dbix-class/bast/DBIx-Class/0.08/trunk/doc",
    input_files      => ['/usr/src/perl/dbix-class/bast/DBIx-Class/0.08/trunk/lib/'],
    skip_underscored => 1,
    class_map        => {
      "DBIx::Class::Relationship::HasMany"    => "DBIx::Class::Relationship",
      "DBIx::Class::Relationship::HasOne"     => "DBIx::Class::Relationship",
      "DBIx::Class::Relationship::BelongsTo"  => "DBIx::Class::Relationship",
      "DBIx::Class::Relationship::ManyToMany" => "DBIx::Class::Relationship",
      "DBIx::Class::ResultSourceProxy"        => "DBIx::Class::ResultSource",
      "DBIx::Class::ResultSourceProxy::Table" => "DBIx::Class::ResultSource",
    },
    skip_classes    => ['DBIx/Class/Serialize/Storable.pm'],
    skip_inherits   => [ qw/
      DBIx::Class::Componentised
      Class::C3::Componentised
    / ],
    force_inherits  => {
      'DBIx::Class::Row' => 'DBIx::Class::Core',
      'DBIx::Class::AccessorGroup' => [
        'Class::Accessor',
        'Class::Accessor::Grouped'
      ]
    },
    method_format   => 'L<%m|%c/%m>'
    debug           => 1,
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

=item force_permissions

ExtUtils::MakeMaker makes directories in blib read-only before we'd
like to write into them.  If this is set to a true value, we'll catch
permission denied errors, and try to make the directory writeable,
write the file, and then set it back to how it was before.

=item class_map

Default: none

A hashref of key/value string pairs. The keys represent classes in
which inherited methods will be found; the values are the classes
which it should link to in the new pod for the actual pod of the
methods.

Some distributions will already have noticed the plight of the users,
and documented the methods of some of their base classes further up
the inheritance chain. This config option lets you tell Pod::Inherit
where you moved the pod to.

=item skip_classes

Default: none

A arrayref of classes and/or F<.pm> files.  Any class/file found in
the list will be skipped for POD creation.

=item skip_inherits

Default: none

A arrayref of classes.  This is a list of classes that shouldn't
show up in any of the C<INHERITED METHODS> sections.

=item force_inherits

Default: none

A hashref of arrayrefs.  Like the opposite of skip_inherits, this
will forcefully add the classes listed to the C<INHERITED METHODS>
sections, except this will only work on a per-class basis.  The keys
represent the classes affected; the values are arrayrefs (or single
strings) specifying which classes to add.

In order to access the methods for the new modules, we'll need to
load them manually after the main class is loaded.  If there are
some sort of weird conflicts, this may cause undesirable results.
Also, any methods that the NEW module inherits will also be added
to the method list.

=item method_format

Default: '%m'

A string with a few custom percent-encoded variables.  This string
will be used on each method name found when writing the new POD
section.  The custom variables are C<%m>, C<%c>, C<%%>, which stand
for the method name, class name, and a literal percent sign
(respectively).  The default basically just prints out the method
name, unaltered.

This string can be used to add method links to the POD files (like
C<'LZ<><%m|%c/%m>'>), or to change the formatting (like C<'CZ<><%mE>'>).

=item debug

Default: 0

Either 1 or 2.  A debug level of 1 will print out a managable level
of debug information per module.  To get POD outputs, set this to
2.

This used to be set with C<$Pod::Inherit::DEBUG>, but this property
is now preferred.  However, the old method still works for
backwards-compatibility.

=back

=cut

sub new {
  my ($class, $args) = @_;
  $args = {
    skip_underscored => 1,
    input_files      => [], # \@ARGV,
    out_dir          => '',
    class_map        => {},
    skip_classes     => [],
    skip_inherits    => [],
    force_inherits   => {},
    method_format    => '%m',
    %{ $args || {} },
  };

  $DEBUG = $args->{debug} || 0;
  if ($DEBUG >= 2) {
    require Data::Dump::Streamer;
    Data::Dump::Streamer->import('Dump');
  }
  
  # Accept just a single filename in here -- OR A SINGLE Path::Class::File!
  for (qw/input_files skip_classes skip_inherits/) {
    $args->{$_} = [$args->{$_}] if not ref($args->{$_}) eq 'ARRAY';
  }
  if (my $fi = $args->{force_inherits}) {
    for (keys %$fi) {
      $fi->{$_} = [$fi->{$_}] if not ref($fi->{$_}) eq 'ARRAY';
    }
  }

  my $self = bless($args, $class);

  # Clean up skip_classes
  @{$self->{skip_classes}} = grep { /./ } map {
    my $c = $_;
    $_ = /::/ ? $self->classname_to_real_file($c) : (-d $_ ? Path::Class::Dir->new($c) : Path::Class::File->new($c))->cleanup->resolve;
    warn "Cannot find real file for $c (found in skip_classes)" unless defined;
    $_;
  } @{$self->{skip_classes}};

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
  
  die "no targets" if (!@targets);
    
  while (@targets) {
    my ($target, $origtarget) = @{shift @targets};
    print "target=$target origtarget=$origtarget \n" if ($DEBUG);
    
    # Check skip list before we do anything
    my $output_filename = (-d $target ? Path::Class::Dir->new($target) : Path::Class::File->new($target))->cleanup->resolve;
    if ( scalar grep { $_ eq $output_filename } @{$self->{skip_classes}} ) {
      print "  target skipped per skip_classes\n" if ($DEBUG);
      next;
    }
    
    if (-d $target) {
      print "  directory: adding children as new targets\n" if ($DEBUG);
      unshift @targets, map { [$_, $origtarget] } ($output_filename->children);
      next;
    }
    if ($target =~ m/\.pm$/) {
      $output_filename = $output_filename->relative($origtarget)->absolute($self->{out_dir}) if ($self->{out_dir});

      $output_filename =~ s/\.pm$/.pod/g;
      $output_filename = Path::Class::File->new($output_filename);
      
      my $dir = $output_filename->dir;
      my $ret = $dir->mkpath;
      
      if ($self->is_ours($output_filename)) {
        my $allpod = $self->create_pod($target);
        # Don't create the output file if there would be nothing in it!
        if (!$allpod) {
          print "  not creating empty file $output_filename\n" if ($DEBUG);
          next;
        }
        
        my ($outfh, $oldperm);
        print "  Writing $output_filename\n" if ($DEBUG);
        unless ( $outfh = $output_filename->open('w') ) {
          if ($!{EACCES} and $self->{force_permissions} ) {
            $output_filename->remove;
            $oldperm = $dir->stat->mode;
            chmod $oldperm | 0200, $dir or die "Can't chmod ".$dir." (or write into it)";
            $outfh = $output_filename->open('w') or die "Can't open $output_filename for output (even after chmodding it's parent directory): $!";
          } else {
            die "Can't open $output_filename for output: $!";
          }
        }
        
        $outfh->print($allpod);
        $outfh->close;
        if (defined $oldperm) {
          chmod $oldperm, $dir or die sprintf "Can't chmod %s back to 0%o", $dir, $oldperm;
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
  $src = Path::Class::File->new($src)->cleanup->resolve->stringify;

  my $tt_stash;
  
  my $classname = $tt_stash->{classname} = $self->require_class($src) || return;
  my @isa_flattened = @{mro::get_linear_isa($classname)};

  # Check for force inherits to add
  my $fi = $self->{force_inherits};
  my $force_inherits = $fi->{$src} || $fi->{$classname};
  if ($force_inherits) {
    # Forced inherits still need to be loaded manually
    foreach my $class (@$force_inherits) {
      print "  Found force inherit: $class\n" if ($DEBUG);
      $self->require_class(undef, $class) || return;
      push @isa_flattened, @{mro::get_linear_isa($class)};
    }
  }
  
  # Now for ones to skip (including its own class)
  foreach my $s ( @{ $self->{skip_inherits} }, $classname ) {
    for (my $i = 0; $i < @isa_flattened; $i++) {
      if ($s eq $isa_flattened[$i]) {
        print "  Skipped per skip_inherits: $s\n" if ($DEBUG);
        splice(@isa_flattened, $i--, 1);
      }
    }
  }
  
  # We can't possibly find anything.  Just short-circuit and save ourselves a lot of trouble.
  if (!@isa_flattened) {
    print "  No parent classes\n" if ($DEBUG);
    return;
  }
  $tt_stash->{isa_flattened} = \@isa_flattened;
  
  my %seen;
  for my $parent_class (@isa_flattened) {
    print "  Parent class: $parent_class\n" if ($DEBUG);
    my $stash;
    {
      no strict 'refs';
      $stash = \%{"$parent_class\::"};
    }
    # There's something subtle and brain-melting going on here, but I think it works.
    my $local_config = $stash->{_pod_inherit_config};
    if (not exists $local_config->{skip_underscored}) {
      $local_config->{skip_underscored} = $self->{skip_underscored};
    }
    $local_config->{class_map} ||= $class_map;

    for my $globname (sort keys %$stash) {
      next if ($local_config->{skip_underscored} and $globname =~ m/^_/);
      next if $seen{$globname};
      
      # Skip the typical UPPERCASE sub blocks that aren't really user-friendly methods
      next if ($globname =~ m/^(?:AUTOLOAD|CLONE|DESTROY|BEGIN|UNITCHECK|CHECK|INIT|END)$/);
      
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
          print "  Got not a subref for $globname in $parent_class; it is probably imported accidentally.\n" if ($DEBUG);
          $exists=0;
        } else {
          die "While checking if $parent_class $globname is a sub: $@";
        }
      }
      next unless ($exists);
      
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
      if ($force_inherits && !$subref) {  # forced inherits may be the ones with the methods...
        foreach my $class (@$force_inherits) {
          $subref //= $class->can($globname);
        }
      }
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
      $seen{$globname} = $parent_class;
#      push @derived, { $parent_class => $nice_name };

      my $doc_parent_class = $local_config->{class_map}->{$parent_class} || $parent_class;
      push @{$tt_stash->{methods}{$doc_parent_class}}, $nice_name;
      splice(@isa_flattened, (firstidx { $_ eq $parent_class } @isa_flattened), 0, $doc_parent_class)
        unless (any {$_ eq $doc_parent_class} @isa_flattened);
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
    
    # Put in the method format
    $new_pod .= join(", ", map {
      my $method = $_;
      my $mlf = $self->{method_format};
      $mlf =~ s/\%m/$method/g;
      $mlf =~ s/\%c/$class/g;
      $mlf =~ s/\%\%/\%/g;
      $mlf;
    } @{$tt_stash->{methods}{$class}}) . "\n\n";
  }

  $new_pod .= "=back\n\n=cut\n\n";

  print "New pod, before Pod::POMification: \n", $new_pod if ($DEBUG >= 2);

  my $parser = Pod::POM->new;
  $new_pod = $parser->parse_text($new_pod)
    or die "Generated pod invalid?";

  # examine any warnings raised
  foreach my $warning ($parser->warnings()) {
    warn "Generated pod warning: $warning\n";
  }

  if ($DEBUG >= 2) {
    print "New pod, after Pod::POMification: \n";
    print $new_pod->dump;
  }

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
    ### TODO: Config variable? ###
    if (grep {$title eq $_} qw<LICENSE AUTHORS LIMITATIONS CONTRIBUTORS AUTHOR CAVEATS COPYRIGHT BUGS>, 'SEE ALSO', 'ALSO SEE', 'WHERE TO GO NEXT', 'COPYRIGHT AND LICENSE') {
      print "  Fount head $title at index $i, going before that section\n" if $DEBUG;
      $insertion_point = $i;
      $before = 1;
      last;
    } else {
      print "  Found head $title at index $i, going after that section\n" if $DEBUG;
      $insertion_point = $i;
      $before = 0;
      last;
    }
  }
  
  
  if (!$insertion_point and $pod->content) {
    print "  Going at end\n" if $DEBUG;
    $insertion_point = -1;
    $before = 0;
  }
  if (!$insertion_point) {
    print "  Going as only section\n" if $DEBUG;
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
    return $1 if (m/^package\s+([A-Za-z0-9_:]+);/);
    if (m/^package\b/) {  # still not immune to "hide from PAUSE" tricks
      print "  Package hidden with anti-PAUSE tricks in $filename\n" if ($DEBUG);
      return undef;
    }
  }  

  print "  Couldn't find any package statement in $filename\n" if ($DEBUG);
  return undef;
}

sub classname_to_filename {
  my ($self, $classname) = @_;
  $classname =~ s/\.p(?:m|od)$//i; 
  return Path::Class::File->new( split(/::|\/|\\/, $classname.'.pm') )->cleanup;
}

sub classname_to_real_file {
  my ($self, $classname) = @_;
  my $filename = $self->classname_to_filename($classname);
  
  for (@{ $self->{input_files} }, '') {  # include "current directory" last, wherever that is
    my $d = -d $_ ? $_ : Path::Class::File->new($_)->dir;
    my $f = $filename->relative($d)->cleanup;
    return $f->resolve if (-f $f);
  }
  return undef;
}

sub require_class {
  my ($self, $src, $classname) = @_;

  $classname ||= $self->filename_to_classname($src) || return undef;
  $src       ||= $self->classname_to_real_file($classname);
  
  # What we had here was hack on top of hack on top of hack, and still didn't work.
  # Fuckit.  Rewrite.
  my $class_as_filename = $self->classname_to_filename($classname);
  
  # Let's just snuff this one right away
  no warnings 'redefine';

  local $|=1;
  my $old_sig_warn = $SIG{__WARN__};
  local $SIG{__WARN__} = sub {
    # Still getting these; we need to filter here...
    return if ($_[0] =~ /^(?:Constant )?[Ss]ubroutine [\w\:]+ redefined /);
  
    my $warning = "  While working on $src: ".$_[0];
    if ($old_sig_warn) { $old_sig_warn->($warning); }
    else               { warn $warning;             }
  };

  
  # Just like require, except without that pesky checking @INC thing,
  # but making sure we put the "right" thing in %INC.
  unless (exists $INC{$class_as_filename}) {
    # Still no source?  Great... we'll have to pray that require will work...
    print "Still no source found for $classname; forced to use 'require'\n" if ($DEBUG && !$src);
    my $did_it = $src ? do $src : require $classname;
    unless ($did_it) {
      my $err = $@;
      $err =~ s/ \(\@INC contains: .*\)//;
      print STDERR "Couldn't autogenerate documentation for $src: $err\n";
      return undef;
    }
  }
  # There's what is arguably a bug in perl itself lurking here: Foo.pm
  # dies during complation (IE not because it wasn't in @INC).  An
  # undef entry is left in %INC, but it's a READONLY undef, which
  # means that you can't just assign something else to the slot.
  $INC{$class_as_filename} = $src unless (exists $INC{$class_as_filename});
  
  return $classname;
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
__END__

=head2 Inline configuration

As well as passing explicit configuration options to L</new>, you can
also leave Pod::Inherit hints in your actual code. To define in a class
that all methods with a leading underscore should be included when
listing methods in that module, use the following snippet in your
code:

  our %_pod_inherit_config = ( skip_underscored => 0 );

=head1 AUTHOR

James Mastros, theorbtwo <james@mastros.biz>

=head1 CONTRIBUTORS

Brendan Byrd, SineSwiper <BBYRD@cpan.org>

=head1 LICENSE

Copyright 2009, James Mastros.  Licensed under the same terms as
perl itself.

=cut
