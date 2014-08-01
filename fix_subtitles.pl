#!/usr/bin/perl -w

use strict;
use warnings;

my $orig1_time = str2sec('00:00:57,630');
my $new1_time  = str2sec('00:00:59,000');

my $orig2_time = str2sec('01:32:53,679');
my $new2_time  = str2sec('01:32:55,200');

# solve linear equation:
# o1 * a + b = n1
# o2 * a + b = n2
#
# o2 * a - o1 * a = n2 - n1
# (o2-o1) * a = n2 - n1
# a = (n2-n1)/(o2-o1)
# b = n1 - o1*a
# a = $rate
# b = $offset

my $rate = ($new2_time - $new1_time) / ($orig2_time - $orig1_time);
#my $rate = 1;

my $offset = $new1_time - $orig1_time * $rate;
#my $offset = 0;

printf STDERR "rate: %.9f, offset: %.2f\n", $rate, $offset;

my $num = 275;
while ( <> ) {
    s/\s+$//;
    if ( /^(\d+)\s*$/ ) {
        print $num++, "\n";
    }
    elsif ( /^(\d\d:\d\d:\d\d,\d\d\d) --> (\d\d:\d\d:\d\d,\d\d\d)\s*$/ ) {
        my $t1 = str2sec($1) * $rate + $offset;
        my $t2 = str2sec($2) * $rate + $offset;

        $t1 = 0 if $t1 < 0;
        $t2 = 0 if $t2 < 0;
        print sec2str($t1), " --> ", sec2str($t2), "\n";
    }
    else {
        print "$_\n";
    }
}

sub str2sec {
    my $str = shift;
    my ($h, $m, $s, $f) = $str =~ /^(\d\d):(\d\d):(\d\d),(\d\d\d)/;

    my $sec = 3600 * $h + 60 * $m + $s + $f / 1000;
    return $sec;
}

sub sec2str {
    my $sec = shift;

    my $h = int($sec / 3600);
    $sec -= $h * 3600;
    my $m = int( $sec / 60 );
    $sec -= $m * 60;
    my $s = int( $sec );
    $sec -= $s;
    my $f = int( $sec * 1000 );

    return sprintf("%02d:%02d:%02d,%03d", $h, $m, $s, $f);
}
