package Perfect::Hash::Switch;

use strict;
our $VERSION = '0.01';
#use warnings;
use Perfect::Hash;
use Perfect::Hash::C;
our @ISA = qw(Perfect::Hash Perfect::Hash::C);
use Config;
use integer;
use bytes;
use B ();

=head1 DESCRIPTION

Uses no hash function nor hash table, just generates a fast switch
table in C<C> as with C<gperf --switch>, for smaller dictionaries.

Generates a nested switch table, first switching on the
size and then on the best combination of keys. The difference to
C<gperf --switch> is the automatic generation of nested switch levels,
depending on the number of collisions, and it is optimized to use word size
comparisons if possible for the fixed length comparisons, which is faster
then C<memcmp>.

I<TODO: optimize with more sse ops>

=head1 METHODS

=over

=item new $filename, @options

All options are just passed through.

=cut

sub new { 
  my $class = shift or die;
  my $dict = shift; #hashref, arrayref or filename
  my %options = map { $_ => 1 } @_;
  # enforce HASHREF
  if (ref $dict eq 'ARRAY') {
    my $hash = {};
    my $i = 0;
    $hash->{$_} = $i++ for @$dict;
    $dict = $hash;
  }
  elsif (ref $dict ne 'HASH') {
    if (!ref $dict and -e $dict) {
      my (@keys, $hash);
      open my $d, "<", $dict or die; {
        local $/;
        @keys = split /\n/, <$d>;
        #TODO: check for key<ws>value or just lineno
      }
      close $d;
      my $i = 0;
      $hash->{$_} = $i++ for @keys;
      $dict = $hash;
    } else {
      die "wrong dict argument. arrayref, hashref or filename expected";
    }
  }
  return bless [$dict, \%options], $class;
}

=item save_c fileprefix, options

Generates a $fileprefix.c and $fileprefix.h file.

=cut

sub save_c {
  my $ph = shift;
  my ($dict, $options) = ($ph->[0], $ph->[1]);

  my ($fileprefix, $base) = $ph->save_h_header(@_);
  my $FH = $ph->save_c_header($fileprefix, $base);
  print $FH $ph->c_funcdecl($base)." {";
  unless ($ph->option('-nul')) {
    print $FH "
    const l = strlen(s);"
  }
  print $FH "
    switch (l) {";
  # dispatch on l
  my ($old, @cand);
  for my $s (sort { length($a) <=> length($b) } keys %$dict) {
    my $l = bytes::length($s);
    #print "l=$l, old=$old, s=$s\n" if $options->{-debug};
    $old = $l unless defined $old;
    if ($l != $old and @cand) {
      print "dump l=$old: [",join(" ",@cand),"]\n" if $options->{-debug};
      _do_cand($ph, $FH, $old, \@cand);
      @cand = ();
    }
    push @cand, $s;
    #print "push $s\n" if $options->{-debug};
    $old = $l;
  }
  print "rest l=$old: [",join(" ",@cand),"]\n" if $options->{-debug};
  _do_cand($ph, $FH, $old, \@cand) if @cand;
  print $FH "
    }
}
";
}

# length optimized memcmp
# it's the last statement if $last, otherwise as fallthrough to the next case statement.
# TODO: do away with most memcmp for shorter strings (< 128?)
# TODO: might need to check run-time char* alignment on non-intel platforms
sub _strcmp {
  my ($s, $l, $v, $last) = @_;
  my $cmp;
  if ($l == 1) {
    my $ord = ord($s);
    if ($ord >= 40 and $ord < 127) {
      $cmp = "*s == '$s'";
    } else {
      $cmp = "*s == $ord /* $s */";
    }
  } elsif ($l == 2) {
    my $short = sprintf("0x%x", unpack("S", $s));
    $cmp = "*(short*)s == $short /* $s */";
  } elsif ($Config{intsize} == 4 and $l == 4) {
    my $int = sprintf("0x%x", unpack("L", $s));
    $cmp = "*(int*)s == $int /* $s */";
  } elsif ($Config{longsize} == 8 and $l == 8) {
    my $long = sprintf("0x%lx", unpack("J", $s));
    $cmp = "*(long *)s == $long /* $s */";
  } elsif ($Config{d_quad} and $Config{longlongsize} == 8 and $l == 8) {
    my $quad = sprintf("0x%lx", unpack("Q", $s));
    my $quadtype = $Config{uquadtype};
    $cmp = "*($quadtype *)s == $quad /* $s */";
  } elsif ($Config{d_quad} and $Config{longlongsize} == 16 and $l == 16) { # 128-bit qword
    my $quad = sprintf("0x%llx", unpack("Q", $s));
    my $quadtype = $Config{uquadtype};
    $cmp = "*($quadtype *)s == $quad /* $s */";
  } else {
    $cmp = "!memcmp(s, ".B::cstring($s).", $l)";
  }
  if ($last) {
    return "return $cmp ? $v : -1;";
  } else {
    return "if ($cmp) return $v;";
  }
}

# handle candidate list of keys with equal length
# either 1 or do a nested switch
# TODO: check char* alignment on non-intel platforms for _strcmp
sub _do_cand {
  my ($ph, $FH, $l, $cand) = @_;
  my ($dict, $options) = ($ph->[0], $ph->[1]);
  # switch on length
  print $FH "
      case $l: "; #/* ", join(", ", @$cand)," */";
  if (@$cand == 1) { # only one candidate to check
    my $s0 = $cand->[0];
    my $v = $dict->{$s0};
    print $FH "\n        ",_strcmp($s0, $l, $v);
  } else {
    # switch on the most diverse char in the strings
    _do_switch($ph, $FH, $cand);
  }
}

# handle candidate list of keys with equal length
# find the best char(s) to switch on
# TODO: try char ranges 8,4,2,1 if length allows it (long*,int*,short*,char*)
sub _do_switch {
  my ($ph, $FH, $cand, $indent) = @_;
  $indent = 1 unless $indent;
  my ($dict, $options) = ($ph->[0], $ph->[1]);
  # find the best char in @cand to switch on
  my $maxkeys = [0,0,undef];
  my $l = bytes::length($cand->[0]);
  for my $i (0 .. $l-1) {
    my %h = ();
    for my $c (map { substr($_,$i,1) } @$cand) {
      $h{$c}++;
    }
    # find max of keys, i-th char in @cand
    my $keys = scalar keys %h;
    $maxkeys = [$keys,$i,\%h] if $keys > $maxkeys->[0];
    last if $keys == scalar @$cand;
  }
  my $i = $maxkeys->[1];
  my $h = $maxkeys->[2];
  my $space = 4 + (4 * $indent);
  print $FH "\n"," " x $space,"switch ((unsigned char)s[$i]) {";
  print "switch on $i in @$cand\n" if $options->{-debug};
  print $FH " /* ",join(", ",@$cand)," */";
  # TODO: collect @cand into buckets for the selected char
  # and switch on these
  #my @c = map { substr($_,$i,1) } @$cand;
  my ($old_c, $new_case) = ('');
  for my $s (sort {substr($a,$i,1) cmp substr($b,$i,1) } @$cand) {
    my $c = substr($s, $i, 1);
    # if $h{$c} > 3 nest one more switch recursively
    print ">3 cases on $i in @$cand\n" if $options->{-debug} and $h->{$c} > 3;
    if ($h->{$c} > 3) {
      # TODO check for recursive loop
      my @cand_c = grep { substr($_,$i,1) eq $c ? $_ : undef } @$cand;
      _do_switch($ph, $FH, \@cand_c, $indent+1);
      #TODO: restart loop without cand_c?
      my @rest = grep { substr($_,$i,1) ne $c ? $_ : undef } @$cand;
      _do_switch($ph, $FH, \@rest, $indent+1);
      print $FH "\n"," " x $space,"}\n",
                " " x $space, "return -1;";
      return;
    } else {
      my $v = $dict->{$s};
      my $ord = ord($c);
      my $case = ($ord >= 40 and $ord < 127) ? "'$c':" : "$ord: /* $c */";
      if ($new_case and $c ne $old_c) {
        print $FH "\n    "," " x $space,"break;";
      }
      if ($h->{$c} == 1) {
        print $FH "\n  "," " x $space,"case $case";
        print $FH "\n    "," " x $space, _strcmp($s, $l, $v);
        $new_case = 1;
      } else {
        if ($c ne $old_c) {
          print $FH "\n  "," " x $space,"case $case";
          $new_case = 1;
        }
        print $FH "\n    "," " x $space, _strcmp($s, $l, $v);
        $old_c = $c;
      }
    }
  }
  print $FH "\n"," " x $space,"}\n";
  if ($indent == 1) {
    print $FH "\n"," " x $space, "return -1;",
  }
}

=item perfecthash $ph, $key

dummy pure-perl variant just for testing.

=cut

sub perfecthash {
  my $ph = shift;
  my $dict = $ph->[0];
  my $key = shift;
  return exists $dict->{$key} ? $dict->{$key} : undef;
}

=item false_positives

Returns undef, always checks the keys.

=cut

sub false_positives {}

=item option $ph

Access the option hash in $ph.

=cut

sub option {
  return $_[0]->[1]->{$_[1]};
}

=item c_lib, c_include

empty as Switch needs no external dependencies.

=cut

sub c_include { "" }

sub c_lib { "" }

=back

=cut

unless (caller) {
  __PACKAGE__->new(@ARGV ? @ARGV : "examples/words20")->save_c;
}

1;
