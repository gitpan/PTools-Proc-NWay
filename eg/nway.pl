#!/opt/perl/bin/perl
#
# File:  nway.pl
# Desc:  Run a long list of tasks with limited concurrency (N-Ways)
#
# Note:  Since this script changes working directory to parent,
#        to run the demo, add current dir onto the filename:
#
#            cd ..
#            ./eg/nway  -R  eg/input
#
use Cwd;
BEGIN {   # Script is relocatable. See "www.ccobb.net/ptools/"
  my $cwd = $1 if ( $0 =~ m#^(.*/)?.*# );  chdir( "$cwd/.." );
  my($top,$app)=($1,$2) if ( getcwd() =~ m#^(.*)(?=/)/?(.*)#);
  $ENV{'PTOOLS_TOPDIR'} = $top;  $ENV{'PTOOLS_APPDIR'} = $app;
} #-----------------------------------------------------------

use PTools::Local;          # PTools local/global vars/methods
use PTools::Proc::NWay;

##die PTools::Local->dump('inclibs');   # show modules 'used'

exit( run PTools::Proc::NWay );
