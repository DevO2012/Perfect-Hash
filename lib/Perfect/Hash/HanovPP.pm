package Perfect::Hash::HanovPP;
our $VERSION = '0.01';
use coretypes;
use strict;
#use warnings;
use integer;
our @ISA = qw(Perfect::Hash);

=head1 DESCRIPTION

Perl variant of the python "Easy Perfect Minimal Hashing" epmh.py
By Steve Hanov. Released to the public domain.
http://stevehanov.ca/blog/index.php?id=119

Based on:
Edward A. Fox, Lenwood S. Heath, Qi Fan Chen and Amjad M. Daoud, 
"Practical minimal perfect hash functions for large databases", CACM, 35(1):105-121

Also a good reference:
"Compress, Hash, and Displace" (CHD algorithm) by Djamal Belazzougui,
Fabiano C. Botelho, and Martin Dietzfelbinger
L<http://cmph.sourceforge.net/chd.html>

=head1 new $dict, options

Computes a minimal perfect hash table using the given dictionary,
given as hashref or arrayref.

Honored options are: I<none>

It returns an object with a list of [\@G, \@V].
@G contains the intermediate table of seeds needed to compute the
index of the value in @V.  @V contains the values of the dictionary.

=cut

sub new {
  my $class = shift or die;
  my $dict = shift; #hashref or arrayref
  my $options = map {$_ => 1 } @_;
  my int $size;
  if (ref $dict eq 'ARRAY') {
    my $i = 0;
    my %dict = map {$_ => $i++} @$dict;
    $size = scalar @$dict;
    $dict = \%dict;
  } else {
    die "new $class: wrong dict argument. arrayref or hashref expected"
      if ref $dict ne 'HASH';
    $size = scalar(keys %$dict) or
      die "new $class: empty dict argument";
  }
  my $last = $size-1;

  # Step 1: Place all of the keys into buckets
  my str @buckets; $#buckets = $last;
  $buckets[$_] = [] for 0 .. $last; # init with empty arrayrefs
  my $buckets = \@buckets;
  my int @G; $#G = $size; @G = map {0} (0..$last);
  my @values; $#values = $last;

  # Step 1: Place all of the keys into buckets
  push @{$buckets[ hash(0, $_) % $size ]}, $_ for sort keys %$dict;

  # Step 2: Sort the buckets and process the ones with the most items first.
  my @sorted = sort { scalar(@{$buckets->[$b]}) <=> scalar(@{$buckets->[$a]}) } (0..$last);
  my $i = 0;
  while (@sorted) {
    my $b = $sorted[0];
    my @bucket = @{$buckets->[$b]};
    last if scalar(@bucket) <= 1; # skip the rest with 1 or 0 buckets
    shift @sorted;
#    print "len[$i]=",scalar(@bucket),"\n";
    my int $d = 1;
    my int $item = 0;
    my int %slots;

    # Repeatedly try different values of $d (the seed) until we find a hash function
    # that places all items in the bucket into free slots.
    while ($item < scalar(@bucket)) {
      my $slot = hash( $d, $bucket[$item] ) % $size;
      # epmh.py uses a list for slots here, we rather use a faster hash
      if (defined $values[$slot] or exists $slots{$slot}) {
        $d++; $item = 0; %slots = (); # nope, try next seed
      } else {
        $slots{$slot} = $item;
#        printf "slots[$slot]=$item, d=0x%x, $bucket[$item] from @bucket\n", $d;
#          unless $d % 100;
        $item++;
      }
    }
    $G[hash(0, $bucket[0]) % $size] = $d;
    $values[$_] = $dict->{$bucket[$slots{$_}]} for keys %slots;
#    print "[".join(",",@values),"]\n";

#    print "buckets[$i]:",scalar(@bucket)," d=$d\n";
#      unless $b % 1000;
    $i++;
  }

  # Only buckets with 1 item remain. Process them more quickly by directly
  # placing them into a free slot. Use a negative value of $d to indicate
  # this.
  my @freelist;
  for my $i (0..$last) {
    push @freelist, $i unless defined $values[$i];
  }
  #print "len[freelist]=",scalar(@freelist),"\n";

  #print "xrange(",$last - $#sorted - 1,", $size)\n";
  while (@sorted) {
    $i = $sorted[0];
    my @bucket = @{$buckets->[$i]};
    last unless scalar(@bucket);
    shift @sorted;
    my $slot = pop @freelist;
    # We subtract one to ensure it's negative even if the zeroeth slot was
    # used.
    $G[hash(0, $bucket[0]) % $size] = - $slot-1;
    $values[$slot] = $dict->{$bucket[0]};
  }
  return bless [\@G, \@values, $options], $class;
}

=head1 perfecthash $obj, $key

Look up a $key in the minimal perfect hash table
and return the associated index into the initially 
given $dict.

=cut

sub perfecthash {
  my ($ph, $key ) = @_;
  my ($G, $V) = ($ph->[0], $ph->[1]);
  my $d = $G->[hash(0, $key) % scalar(@$G)];
  return $d < 0 ? $V->[- $d-1] : $V->[hash($d, $key) % scalar(@$G)];
}

sub false_positives { 1 }

=head1 hash salt, string

pure-perl FNV-1 hash function as in http://isthe.com/chongo/tech/comp/fnv/

=cut

sub hash {
  my int $d = shift || 0x01000193;
  my str $str = shift;
  for my $c (split//,$str) {
    $d = ( ($d * 0x01000193) ^ ord($c) ) & 0xffffffff;
  }
  return $d
}

# local testing: p -d -Ilib lib/Perfect/Hash/HanovPP.pm examples/words20
unless (caller) {
  require Perfect::Hash;
  &Perfect::Hash::_test(@ARGV)
}

1;
