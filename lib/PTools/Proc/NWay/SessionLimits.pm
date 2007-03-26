# -*- Perl -*-
#
# File:  PTools/Proc/NWay/SessionLimits.pm
# Desc:  Determine the min and max number of concurrent sessions allowed
# Date:  Wed Feb 02 17:03:35 2005
# Stat:  Prototype, Experimental
#
# Usage:
#        use PTools::Proc::NWay::SessionLimits;
#
#        my $SessionLimits = "Proc::NWay::SessionLimits";
#
#        my($sesDflt, $sesMax) = get $SessionLimits();
#
package PTools::Proc::NWay::SessionLimits;
use 5.006;
use strict;
use warnings;

our $PACK    = __PACKAGE__;
our $VERSION = '0.01';
our @ISA     = qw( );

use PTools::Local;                            # Local/Global environment
use PTools::Proc::Backtick;                   # simple i/f to `backtick`
use PTools::Debug;                            # simple "debug output" class
use PTools::Options;                          # simple i/f to Getopt::Long

my $Local = "PTools::Local";
my($Debug, $Opts);
my $DefaultMin = 3;

sub new { bless {}, ref($_[0])||$_[0] }       # constructor is optional

*get = \&run;                                 # alias (for semantic clarity)

sub run                                       # main entry point
{   my($class) = @_;

    $Debug = $Local->get('app_debugObj');
    $Opts  = $Local->get('app_optsObj');

    my $min = $class->getNumCPUs() || $DefaultMin;
    my $max = $min * 5;

    return($min,$max);
}

sub getNumCPUs
{   my($class) = @_;

    my $cmd = $Local->path('app_bindir', "numcpus");

    return $DefaultMin unless -x $cmd;        # return default if can't execute

    my $cmdObj = run PTools::Proc::Backtick( $cmd );  # run 'numcpus' command

    my ($stat,$err)= $cmdObj->status();
    $stat and die $err;                       # abort if any error occurred

    my $result = $cmdObj->result();           # collect the result

    my($numCPUs) = $result =~ m#\s(\d+)$#;    # excract the cpu number

    return($numCPUs || $DefaultMin);          # return default if didn't parse
}
#_________________________
1; # Required by require()
