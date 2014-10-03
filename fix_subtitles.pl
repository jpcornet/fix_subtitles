#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use Encode;

my $usage = <<END_USAGE;
Usage:

  fix_subtitles.pl [-v] [--start num] [-o outfile] nr=TIME ... [file]

Re-sync subtitles. Will overwrite file if no outfile is given, and a file
argument is provided. Makes sure "nr" subtitle is at given TIME. Best to
provide two times, rest will be interpolated or extrapolated. With more
than two given times, will use linear interpolation between given points.

Given "nr" refers to the start time of the number of the subtitle in the
input file. TIME can be relative to that. If you provide --start=NUM, the
output file will start with that number of subtitle.
END_USAGE

my ($verbose, $start_num, $help, $outfile);
$verbose = -t STDERR;
$start_num = 1;
GetOptions( 'v|verbose!' => \$verbose,
            'start=i'    => \$start_num,
            'o=s'        => \$outfile,
            'h|?|help'   => \$help,
) or die $usage;

$help and die $usage;

die $usage if !@ARGV;
my %timestr_arg;
while ( @ARGV and $ARGV[0] =~ /^(\d+)=(.*)$/ ) {
    my ($num, $timestr) = ($1, $2);
    die "Duplicate input nr $num\n$usage" if exists $timestr_arg{$num};
    $timestr_arg{$num} = $timestr;
    shift @ARGV;
}

my $infh;
if ( @ARGV > 1 ) {
    die "Too many file arguments, what is $ARGV[0] ?\n$usage";
}
elsif ( @ARGV == 1 ) {
    my $file = $ARGV[0];
    if ( ! -r $file ) {
        die "Cannot read $file\n";
    }
    open $infh, "<", $file
        or die "Cannot open $file\: $!\n";
    $outfile //= $file;
}
else {
    $infh = \*STDIN;
}

if ( !%timestr_arg and $verbose ) {
    warn "No input number specified, no re-synchronisation done, just copying input to output\n" .
         "Use --help for usage instructions\n";
}

my $expect_nr = 1;
my $alt_expect = $start_num;
my @in;
my %in_seen;
my $entry;
my %time_arg;
my $want = 'NR';
my $lines;
while ( <$infh> ) {
    s/\s+$//;
    if ( $. == 1 ) {
        # sometimes line 1 begins with a BOM
        eval {
            $_ = decode_utf8($_);
            s/^\x{FEFF}//;
        };
    }
    if ( /^(\d+)$/ ) {
        my $in_nr = $1;
        if ( $want eq 'TEXT' and $lines > 0 ) {
            warn "No blank line in subtitle file before entry $in_nr\n";
        }
        elsif ( $want ne 'NR' and $want ne 'TEXT-OR-NR' ) {
            die "Unexpected new entry at line $., aborted\n";
        }

        if ( $in_nr != $expect_nr and $in_nr != $alt_expect ) {
            warn "Warning in input, got subtitle nr $in_nr, expected $expect_nr\n" if $verbose;
            $alt_expect = $expect_nr + 1;
            $expect_nr = $in_nr + 1;
        }
        else {
            $alt_expect = $expect_nr = $in_nr + 1;
        }
        if ( $in_seen{$in_nr}++ ) {
            if ( exists $timestr_arg{$in_nr} ) {
                die "Multiple subtitle numbers $in_nr exist! Cannot use it as scheduling argument\n";
            }
            elsif ( $verbose ) {
                warn "Multiple subtitle numbers $in_nr exist in input\n";
            }
        }

        $entry = { NR => $in_nr };
        push @in, $entry;
        $want = 'TIME';
    }
    elsif ( /^(\d\d:\d\d:\d\d,\d\d\d) --> (\d\d:\d\d:\d\d,\d\d\d)$/ ) {
        my ($begin_time, $end_time) = ($1, $2);

        if ( $want ne 'TIME' ) {
            die "Unexpected time at line $., aborted\n";
        }

        $entry->{'BEGIN'} = $begin_time;
        $entry->{'END'}   = $end_time;
        $entry->{TEXT}    = '';
        $lines = 0;

        if ( exists $timestr_arg{ $entry->{NR} } ) {
            my $argstr = delete $timestr_arg{ $entry->{NR} };
            my $file_time = parse_time($begin_time);
            my $newbegin_time;
            if ( $argstr =~ /^\s*([+-])\s*(\S.*)$/ ) {
                my ($dir, $displacement) = ($1, $2);
                my $rel_time = parse_time($displacement);
                if ( $dir eq '-' ) {
                    $newbegin_time = $file_time - $rel_time;
                }
                elsif ( $dir eq '+' ) {
                    $newbegin_time = $file_time + $rel_time;
                }
                else {
                    die "logic error, stop";
                }
            }
            else {
                $newbegin_time = parse_time($argstr);
            }
            $time_arg{ $entry->{NR} } = { ORIG_TIME => $file_time, 
                                          NEW_TIME  => $newbegin_time
                                        };
        }
        $want = 'TEXT';
    }
    elsif ( $want ne 'TEXT' and $want ne 'TEXT-OR-NR' ) {
        die "Unexpected text line at line $.. Not a subtitle file?\n";
    }
    elsif ( /^\s*$/ ) {
        $entry->{TEXT} ||= "\n";
        $want = 'TEXT-OR-NR';
    }
    else {
        if ( $want eq 'TEXT-OR-NR' ) {
            # previous line was a blank line
            $entry->{TEXT} .= "\n";
        }
        $entry->{TEXT} .= "$_\n";
        if ( ++$lines > 10 ) {
            die "More than 10 lines of text at line $., not a subtitle file? Aborted.\n";
        }
        $want = 'TEXT';
    }
}

if ( $want eq 'TIME' or $want eq 'NR' ) {
    die "Unexpected EOF\n";
}

if ( %timestr_arg ) {
    my @unseen = keys %timestr_arg;
    die "No subtitle number @unseen in input file\n";
}

my @input_points = sort keys %time_arg;
my $rate;
my $offset;
my ($point_a, $point_b);
my $next_inter_point;
if ( !@input_points ) {
    $rate = 1;
    $offset = 0;
}
elsif ( @input_points == 1 ) {
    $rate = 1;
    my $point = $time_arg{ shift @input_points };
    $offset = $point->{NEW_TIME} - $point->{ORIG_TIME};
}
else {
    $point_a = $time_arg{ shift @input_points };
    $next_inter_point = shift @input_points;
    $point_b = $time_arg{ $next_inter_point };
    ($rate, $offset) = linear_interpolate($point_a, $point_b);
}

printf STDERR "Start writing with rate=%.9f, offset=%.2f\n", $rate, $offset
    if $verbose;

my $outfh;
if ( $outfile ) {
    rename $outfile, "$outfile.bak" if -e $outfile;
    open $outfh, ">", $outfile
        or die "Cannot write $outfile\: $!\n";
}
else {
    $outfh = \*STDOUT;
}

my $i = $start_num;
for my $e ( @in ) {
    # check if we need to re-calculate interpolation
    if ( @input_points and $e->{NR} >= $next_inter_point ) {
        $point_a = $point_b;
        $next_inter_point = shift @input_points;
        $point_b = $time_arg{ $next_inter_point };
        ($rate, $offset) = linear_interpolate($point_a, $point_b);
        printf STDERR "At subtitle %d, continu writing with rate=%.9f, offset=%.2f\n",
            $i, $rate, $offset
            if $verbose;
    }
    print $outfh "$i\n";
    my $new_begin = parse_time($e->{'BEGIN'}) * $rate + $offset;
    my $new_end   = parse_time($e->{'END'}) * $rate + $offset;
    if ( $new_begin < 0 ) {
        warn "Begin time for point $i is before 0, chopping\n" if $verbose;
        $new_begin = 0;
    }
    if ( $new_end < 0 ) {
        warn "End time for point $i is before 0, chopping\n" if $verbose;
        $new_end = 0;
    }
    print $outfh sec2str($new_begin), " --> ", sec2str($new_end), "\n";
    print $outfh $e->{TEXT}, "\n";
    $i++;
}

sub linear_interpolate {
    my ($p1, $p2) = @_;

    # solve linear equation:
    # o1 * rate + offset = n1
    # o2 * rate + offset = n2
    #
    # o2 * rate - o1 * rate = n2 - n1
    # (o2-o1) * rate = n2 - n1
    # rate = (n2-n1)/(o2-o1)
    # offset = n1 - o1*rate

    my $rate = ( $p2->{NEW_TIME} - $p1->{NEW_TIME} ) / ( $p2->{ORIG_TIME} - $p1->{ORIG_TIME} );
    my $offset = $p1->{NEW_TIME} - $p1->{ORIG_TIME} * $rate;
    return ($rate, $offset);
}

sub parse_time {
    my $str = shift;
    my ($h, $m, $s, $f) = $str =~ m{
        ^
        (?:                     # optional HH:MM:
            (?:                 # optional HH:
                (\d{1,2})       # match optional hours
                :
            )?
            (\d{1,3})           # match optional minutes
            :
        )?
        (\d{1,4})               # match seconds
        (?:                     # optionally match ,fraction
            ,
            (\d{1,3})
        )?
        $
    }x;
    if ( !defined $s ) {
        die "Cannot parse time string $str\n";
    }
    if ( defined $h and length($m) > 2 ) {
        die "What time is $h\:$m ??\n";
    }
    if ( defined $m and length($s) > 2 ) {
        die "What time is $m\:$s ??\n";
    }
    $s += $m * 60 if defined $m;
    $s += $h * 3600 if defined $h;
    $s += $f / 10 ** length($f) if defined $f;
    return $s;
}

sub sec2str {
    my $sec = shift;

    my $h = int($sec / 3600);
    $sec -= $h * 3600;
    my $m = int( $sec / 60 );
    $sec -= $m * 60;
    my $s = int( $sec );
    $sec -= $s;
    my $f = int( $sec * 1000 + 0.5 );

    return sprintf("%02d:%02d:%02d,%03d", $h, $m, $s, $f);
}
