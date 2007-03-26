# -*- Perl -*-
#
# File:  PTools/Proc/NWay.pm
# Desc:  Run a list of tasks with parallel processing
# Date:  Wed Sep 22 14:01:28 2004
# Stat:  Prototype, Experimental
#
# Synopsis A - Using this module: 
#        Create a small script to use this module. Then run the small
#        script using the "-h" option for usage help. Exempli gratia:
#
#        use PTools::Local;
#        use PTools::Proc::NWay;
#        exit( run PTools::Proc::NWay );
#
# Synopsis B - Running the script:
#
#        Usage: nway [<options>] filename [ - command [ -arg [...]]]
#  
#        Run with '-h' to see current synopsis
#
# Note:  See the man page for full usage after the end of this module.
#
# Dependencies:
#        The Driver and Session modules are implemented via "POE."
#        In addition, NWay modules require the PerlTools framework. 
#
package PTools::Proc::NWay;
use 5.006;                                    # requires Perl 5.006 or later
use strict;
use warnings;

our $PACK    = __PACKAGE__;
our $VERSION = '0.09';
our @ISA     = qw( );

$|= 1;                                        # unbuffer STDOUT

use PTools::Local;                            # Local/Global environment
use PTools::Counter 0.08;      # can "accume" # keep track of various events
use PTools::Debug;                            # simple "debug output" class
use PTools::Loader qw( generror );            # load Perl modules at runtime
use PTools::Options 0.14;                     # simple i/f to Getopt::Long
use PTools::Proc::NWay::Driver;               # controls session processes
use PTools::Proc::NWay::Logger;               # facilitates session logging
use PTools::Proc::NWay::Session;              # runs a single session/task
use PTools::Proc::NWay::SessionLimits;        # concurrent session min & max
use PTools::SDF::SDF 0.30 qw( noparse );      # manipulate colon separated data
use PTools::SDF::ARRAY;                       # load SDF::SDF obj from a list
use PTools::SDF::Lock::Advisory;              # simple advisory file locking

my $Local         = "PTools::Local";
my $Driver        = "PTools::Proc::NWay::Driver";
my $SessionLimits = "PTools::Proc::NWay::SessionLimits";
my $LoggerClass   = "PTools::Proc::NWay::Logger";
my $LockClass     = "PTools::SDF::Lock::Advisory";
my $OptsClass     = "PTools::Options";
my $CountClass    = "PTools::Counter";
my $DebugClass    = "PTools::Debug";
my($Opts,$Counter,$Debug);

sub run                                               # main entry point
{   my($class,@args) = @_;

    $class->parseCmdLineOptions();    # parse @ARGV, set $Opts,$Counter,$Debug

    my($lockFile,$lockObj,$ccVers,$hostname,$mode,$prioritizedCount);

  # $lockFile = $Local->path('app_datdir', "/tmp/nway.lock");
  # $lockObj  = $class->advisoryLock( $lockFile )  or return -1;
    $mode     = ( $Opts->preview ? "preview" : "processing" );
    $hostname = $Local->getFqdn;       # "fully qualified domain name"

    $Driver->run();                           # process the task list

    print $Counter->format();

    print "\nDone.\n";

  # print $Local->dump('inclib');    # list the 105 or so used Modules

  # $class->advisoryUnlock( $lockObj, $lockFile );

    return 0;                       # Aaaannnnddd Weeeerrr''ee Outta Here!
}

sub advisoryLock
{   my($class,$lockFile) = @_;

    my $basename = $Local->get('basename');
    my $lockObj  = new $LockClass;

    # When previewing, return something or script will abort.

    return $lockObj if $Opts->preview;

    my($stat,$err) = $lockObj->lock( $lockFile );

    if ($stat) {
	my $mode = ( $Opts->force ? "Error" : "Warning" );
	warn "\n$basename: $mode: Can't obtain lock (is script already running?)\n\n  lock file is: $lockFile\n  error is: $!\n\n";

	die "abort"  if ($Opts->force);
    }

    return $lockObj;
}

sub advisoryUnlock
{   my($class,$lockObj,$lockFile) = @_;

    return if $Opts->preview;

    $lockObj->unlock;
    unlink( $lockFile );

    return;
}

sub parseCmdLineOptions
{   my($class) = @_;

  # my($sDflt, $sMax) = (3,25);
    my($sDflt, $sMax) = get $SessionLimits();   # Now based on CPU count.

    my $basename   = $Local->get('basename');
    #__________________________________________________
    # Define valid options and Usage help text.

    my @optArgs = (

       "sessions|concurrent|s|c=i",
                     "Debug|D:i",
		       "IFS|F=s",
		      "help|h",
		      "Keep|K",
		 "LogPrefix|L=s",
	        "logdir|log|l=s",
    "maxseconds|maxtime|max|m=i",
	           "preview|p:i",
		    "Remove|R",
            "randomize|rand|r",

	  ##      "parseifs",           # not supported (for testing only)
	  ##   "command|cmd|c=s",       # not supported (use "- command")
	  ## "filename|file|f=s",       # not supported (use <filename>)
    );


### Not yet enabled:
###     --parseifs - allow IFS char in field  default is no IFS parsing

    my $usage   = <<"__EndOfUsage";

 Usage: $basename [<options>] { -K | -R } filename [ - command [ -arg [...]]]

   where <options> include
        -c <num>   - concurrent sessions (*)  default is $sDflt, max is $sMax
        -L <str>   - specify logfile prefix   default is to use 'CMD_'
        -l <dir>   - log dir for the output   default is /tmp/nway.<PID>
        -m <secs>  - max seconds for a task   default is unlimited time
        -p [<num>] - preview of commands (+)  default is to run commands
        -r         - randomize the task list  default is original order
        -h         - display usage help text  and ignore other options
        -F <char>  - IFS char for data file   default is a colon (':')
        -D [<num>] - enable debugging output  default is no debug output

   where 
       { -K | -R } - specifes whether to keep (-K) or remove (-R) the
                     temporary output logfiles created for each task

         filename  - specifies a file of tasks to perform concurrently
                     use a value of "stdin" to read from STDIN file

     [ - command ] - is a command used to run each of the task lines

     [ -arg [...]] - is a list of opts/args passed to the <command> 

   Note: (*) Default and maximum values for '-c <num>' may be calculated 
	 for each server based on the number of CPUs. These limits can 
	 vary depending on the class of the host machine. However, the 
	 actual maximum value used will be the smaller of the following:
	 A) calculated maximum, B) tasks to run, or C) value for 'num'

   Note: (+) The '-p' (--preview) option can be used as '-p <num>' where
         'num' is a number equal to 2 or more. When used in this manner,
         will cause a random (1 .. num) second delay in the preview to
         simulate tasks running with various ending times.

__EndOfUsage
    #__________________________________________________
    # Parse command-line options: Abort on error / Exit if help
    # Note that we disable 'permute' so that a single dash ('-') char
    # will terminate argument parsing. (Requires Options 0.14 or later
    # for the delayed parsing feature to work.)

    $Opts = $OptsClass->new();                       # create options parser

    $Opts->config( "no_permute" );                   # config options parser

    $Opts->parse( $usage, @optArgs );                # PARSE @ARGV

    $Opts->abortOnError();                           # invalid args??
    $Opts->exitWithUsage()   if   $Opts->help();     # was '-h' used?
    $Opts->abortWithUsage()  if ! $Opts->args->[0];  # first arg is <file>
    #__________________________________________________
    # Verify the correct arguments were used correctly

    my(@args) = $Opts->args();                       # list of cmd-line args

    my $filename = shift @args;                      # filename (required)

    my $dash = shift @args;                          # strip 'lonesome dash'
    if ($dash) {
	$Opts->abortWithUsage() unless ($dash eq "-");   # ... and verify.
    }
    my $command  = shift @args;                      # command (optional)

    $Opts->set('filename', $filename );              # turn arg into option
    $Opts->set('command',  $command  );              # turn arg into option

    # Okay, at this point any remaining args in the
    # list are intended for the named "$command".
    # Here we reset the list for easy use later on.

    $Opts->resetArgs( \@args );                      # redefine 'args' list


    # One or the other of '-K' or '-R' but not both here.
    # However, if the 'command' looks like a 'Perl::Module'
    # then both the '-K' and '-R' arguments become optional.
    # And, if we are previewing, these are optional as well.
    #
    if ($command and $command =~ m#\w+\:\:\w+#) {
	# do nothing

    } elsif (! $Opts->preview) {
	$Opts->abortWithUsage()     if ( $Opts->Keep and $Opts->Remove );
	$Opts->abortWithUsage() unless ( $Opts->Keep  or $Opts->Remove );
    }

    #__________________________________________________
    # Set option defaults 

    my $prefix = $Opts->LogPrefix;
    if ($prefix) {
	if ($prefix !~ m#^\w*$#) {
	    warn "Warning: LogPrefix '$prefix' reset to 'CMD_'\n";
	    $prefix = "";
	}
    }
    $Opts->set('LogPrefix', "CMD_") unless $prefix;

    my $ifs = $Opts->IFS() ||":";
    if (length($ifs) > 1) {
	if ($ifs =~ m#^\\s\+?$#) {
	    # allow for special cases
	} else {
	    my $tmp = substr($ifs,0,1);
	    warn "Warning: IFS string '$ifs' truncated to '$tmp' char\n";
	    $Opts->set('IFS', $tmp);
	}
    }

    my $sessions = $Opts->sessions() || $sDflt;
    $sessions = $sMax if ($sessions > $sMax);

    $Debug   = $DebugClass->new( $Opts->Debug() );
    $Counter = $class->initCounters();
    #__________________________________________________
    # Handle the logDir setup for session/task logging

    my($logObj,$stat,$err) = new $LoggerClass($Debug, $Opts);

    $Opts->set('logdir', $logObj->logDir  );

    if ($stat) {
	die "\n$basename: $err\n\n";
	## $Opts->abortWithUsage();
    }
    #__________________________________________________
    # Load the task list

    my $taskObj = $class->loadTaskList( $Opts );

    my $count = $taskObj->count();
    $sessions = $count if ($sessions > $count);
    #__________________________________________________
    # Stash the results for later use

    $Local->set('app_taskObj',      $taskObj   );   # the "task list"
    $Local->set('app_optsObj',      $Opts      );
    $Local->set('app_debugObj',     $Debug     );
    $Local->set('app_counterObj',   $Counter   );
    $Local->set('app_maxSessions',  $sessions  );
    $Local->set('app_logObj',       $logObj    );

    # DEBUG:
    #warn $Opts->dump();
    #warn $taskObj->dump; ##(0, 1);
    #die  "\nterminate";

    return $Opts;
}

sub loadTaskList
{   my($class, $Opts) = @_;

    #----------------------------------------------------
    # Load the specified data into an object. 

    my $filename = $Opts->filename();
    my $taskObj  = "";

    if ($filename =~ /^stdin$/i) {
	my(@list)= <STDIN>;
	$taskObj = new PTools::SDF::ARRAY( \@list, "", $Opts->IFS() );
    } elsif (! -f $filename) {
	die "Error: File not found: '$filename'";
    } elsif (! -r _) {
	die "Error: Can't read '$filename': $!";
    } else {
	$taskObj = new PTools::SDF::SDF( $filename, "", $Opts->IFS() );
    }

    #----------------------------------------------------
    # It's simple to randomly sort the list. Just "extend" the 
    # "sort" method on the SDF::SDF object with a randomizer.
    # But, if we only have one record, don't bother sorting!

    if ( $Opts->randomize()  and  $taskObj->isSortable() ) {

	$taskObj->extend( "sort", "SDF::Sort::Random" );

	$taskObj->sort();           # SORT list into a random order
    }

    return( $taskObj );
}

sub initCounters
{   my($class) = @_;

    # Init various counters ... initialize in the same order
    # that they should be displayed when script has completed.
    # Note: With counters used for "internal" processes, init
    # with the "-hidden-" (or "-internal-") option to prevent
    # these from being displayed after the cleanup is complete.
    #
    my $Counter     = $CountClass->new();
    my $starttime   = $Local->param('starttime') || time();
    my($head,$foot) = ("Results of Tasks", "End of Tasks.");

    # Customize the Counter setup, based on the run mode.
    # FIX: what else do we want to count around here, anyway?

    $Counter->init('total',      "    Total Tasks:  ");
  # $Counter->init('note',       "          Notes:  ");
    $Counter->init('warn',       "       Warnings:  ");
    $Counter->init('error',      "         Errors:  ");

    # Also, set the header and footer strings we will emit
    # with the Counter variables when the script is done.

    $Counter->head("$head\n". "-" x 16);
    $Counter->foot("-" x 16 ."\n$foot\n");

    # These additional special counters are used/calculated/output
    # by the "format" method of the Counter class which is invoked
    # in the "run" method of this class.
    #
    $Counter->start   ("  Tasks Started:  ", $starttime );
    $Counter->end     ("    Tasks Ended:  ");
    $Counter->cumulate("Cumulative Time:  ");    # aka "cumulative" time
    $Counter->elapsed ("   Elapsed Time:  ");

    return $Counter;
}
#_________________________
1; # Required by require()

__END__

=head1 NAME

PTools::Proc::NWay -  Run a list of tasks with concurrent processing

=head1 VERSION

This document describes version 0.08, released October, 2005.


=head1 SYNOPSIS 

=head2 Module Synopsis 

Create a small script to use this module. Then run the small script using 
the 'L<-h>' (L<--help>) command line option for usage help. The 'B<nway>' 
command is just such an implementation. Exempli gratia:

 use PTools::Local;                      # PerlTools Local module
 use PTools::Proc::NWay;                 # include this class
 exit( run PTools::Proc::NWay );         # return status to OS


=head2 Command Synopsis 

 nway [<options>] { -K | -R } filename [ - command [ -arg [...]]]

 where <options> include
      -c <num>   - concurrent sessions (*)  default is 8, max is 40
      -L <str>   - specify logfile prefix   default is to use 'CMD_'
      -l <dir>   - log dir for the output   default is /tmp/nway.<PID>
      -m <secs>  - max seconds for a task   default is unlimited time
      -p [<num>] - preview of commands (+)  default is to run commands
      -r         - randomize the task list  default is original order
      -h         - display usage help text  and ignore other options
      -F <char>  - IFS char for data file   default is a colon (':')
      -D [<num>] - enable debugging output  default is no debug output

 where
   { -K | -R }   - specifes whether to keep (-K) or remove (-R) the
		   temporary output logfiles created for each task

      filename   - specifies a file of tasks to perform concurrently
                   use a value of "stdin" to read from STDIN file

   [ - command ] - is a command used to run each of the task lines

   [ -arg [...]] - is a list of opts/args passed to the <command> 

 Note: (*) Default and maximum values for '-c <num>' may be calculated
       for each server based on the number of CPUs. These limits can
       vary depending on the class of the host machine. However, the
       actual maximum value used will be the lesser of the following:
       A) calculated maximum, B) tasks to run, or C) value for 'num'

 Note: (+) The '-p' (--preview) option can be used as '-p <num>' where
       'num' is a number equal to 2 or more. When used in this manner,
       will cause a random (1 .. num) second delay in the preview to
       simulate tasks running with various ending times.


See the L<Options and Arguments|"Options and Arguments"> section,
below, for notes on using the B<long form> of these options. For
example, the following two commands are equivalent.

 nway -K -l /tmp/xyzzy -L ECHO_ filename 

 nway --logdir /tmp/xyzzy --LogPrefix ECHO_ --Keep filename 
    


=head1 DESCRIPTION

This module implements a B<limited concurrency> mechanism whereby a list 
of commands can be run in sequence such that only a few of the commands 
are allowed to run concurrently. This provides a configurable B<throttle> 
to prevent many simultaneous commands from overwhelming a system while 
still allowing a controlled amount of parallel processing.

This document assumes that a script named 'B<nway>' is used to invoke
this module. Much of the discussion and examples herein refer to an
'nway' script.

This concurrency mechanism reqires an input file of tasks to run. There 
is a lot of flexibility in how this file is created and used depending 
on the L<Arguments|"Arguments"> and L<Options|"Options"> specified. A
complete description is included of both the L<Simple Case|"Simple Case">
and of ways to use L<Named Input Fields|"Named Input Fields> in the data
file.

Logging of output can be a bit confusing. There is the output from the main 
Driver module (sent to the 'nway' script's STDOUT), and the output from each 
command that is run by the Driver. Read the L<Output Logging|"Output Logging"> 
section, below, for the full details.

When the list of tasks is completed a summary is generated. This includes
a list of any tasks that failed for any reason. The summary also includes
a count of the number of tasks, the start time and end time, the 'cumulative'
time of all the tasks, and the 'elapsed' time of the 'nway' script. These
last two can be used to determine the effectiveness of running tasks in
parallel vs. running them each serially.


=head2 Constructor

=over 4

=item run

This is the only public interface to this class, and it does not accept 
any parameters. The L<Module Synopsis|module synopsis> above shows a
complete implementation of this class.

=back

=head2 Methods

This class contains no public methods other than those described above.

=head2 Negative Effects of Concurrency Processing

The I<raison d'etre> of 'B<nway>' is to improve the throughput of a 
long list of tasks while limiting the overall impact to the system
on which they are running.

However, given a long list of tasks, not I<every> situation calls for
an 'B<nway>' solution. Tasks that have a B<very> short duration could 
better be run sequentially, unless the logging and error detection 
features provided by 'B<nway>' outweigh the extra overhead incurred.

Take 400 'B<echo xyzzy>' commands. Running them sequentially using Perl's 
'B<system>' function can complete in a total of 2 seconds (for example), 
when output is STDOUT. Running these through 'B<nway>' on the same machine
gives comparatively dismal results. Cumulative times can range between 12 
and 35 seconds, while elapsed times can be between 13 and 15 seconds. Using
various concurrency levels does not have much effect. (Times listed are 
provided as an example only. Actual times can vary greatly, depending on 
the system used and the current system load.) 

Bottom line: This module is not a panacea. It is best to do a little bit of
experimenting before assuming that this module will speed up the overall
completion time for a given list of tasks.

=head2 Options and Arguments

A number of command line options are available to control the throttling 
mechanism and other behaviors of this module. When using the abbreviated 
versions, options can be bundled using POSIX complient syntax. Options 
may not be permuted. Each of the following examples are equivalent. Again, 
this assumes that this module is implemented via a script named 'nway.'

 nway -K -rm600D2 input.dat

 nway -K -m 600 -r --Debug 2 input.dat 

 nway -Keep --randomize --maxtime 600 -D 2 input.dat

=head3 Arguments

One of B<L<-K|-K>> (L<--Keep|--Keep>) or B<L<-R|-R>> (L<--Remove|--Remove>)
and the B<L<filename>> argument are required while all others are optional.
Note that using additional arguments can alter the nature of how the 
B<filename> is parsed and used.

=over 4

=item -K 

=item --Keep 

=item -R 

=item --Remove

You must select one of B<-K> (--Keep) or B<-R> (--Remove) but not both.
When using the B<L<-p|-p_[num]>> (L<--preview|-p_[num]>) option, these
arguments are optional.

This required argument specifies whether to keep (B<-K>) or remove
(B<-R>) the temporary log files created for each task that is run.
See the B<L<-l dir|-l_dir>> (L<--logidr dir|-l_dir>)  option, below, 
for notes on specifiyng the log directory in which to place the 
temporary log files. This argument will effect the the resulting 
output from the B<nway> script.

It is also possible to use output redirection for each task separately. 
See the L<Output Logging|"Output Logging"> section, below for details.

=item filename

This required argument specifies a file of tasks to perform concurrently.
Use a string value of 'B<stdin>' for data to be read from STDIN. See the
L<Configuration Data|Configuration Data> section for possible
formats for this input file.

=item [ - command ]

This optional argument specifies a command to run. 
When used, the command name must be preceeded with a dash ('-').
This allows any arguments to be added to the B<nway> command line,
even when they would not be valid options to this module.

B<Note> that, when this argument is used, the contents of the 
data file are interpreted slightly differently. See the 
L<Configuration Data|"Configuration Data"> section, below for details.
Also see the L<Custom Command Processing|"Custom Command Processing"> 
section for a variation on this usage.

=item [ -arg [...]]

When this optional argument list is used it may contain any arbitrary 
options and/or arguments that are valid for the specified B<command>. 
This list is passed to the B<command> I<before> any B<task list> 
options and/or arguments are added.

=back


=head3 Options

For each option, the long and short names are equivalent, but only one 
should be used at a time.

=over 4

=item -c num

=item --concurrent num

Specify the number of concurrent sessions. The default and maximum
values will vary depending on the current host. Use the B<'L<-h>'> 
(L<--help>) option to see the range on a given machine.

The default and maximum values for 'B<num>' may be calculated for each 
server based on the number of CPUs. These limits can vary depending 
on the class of the host machine. However, the actual maximum value 
used will be the lesser of the following:

 A) calculated maximum, B) tasks to run, or C) value for 'num'


=item -L string

=item --LogPrefix string

Use this option to specify an alternate logfile prefix. The default 
logfile prefix is 'B<CMD_>' for each file. In either case, the logfile 
suffix will be 'nnnnnn', a six-digit number that is the 'nway' internal 
number for each given task.
See the L<Output Logging|"Output Logging"> section, below for details.

=item -l dir

=item --logdir dir

Specify the log dir used to collect the output for each of the 'sessions'
or 'tasks' executed by this module. By default, each session's command
output is redirected into the B</tmp/nway.<PID>> directory, where <PID>
is the process identifier of the parent B<nway> session.

When this option is used and the named B<dir> leaf does B<not> exist, this
module will created it prior to running the first task. Upon completion of 
the final task, if the B<L<-R|-R>> (L<--Remove|--Remove>) option was also 
used, this module will remove the named B<dir> leaf.

If the named B<dir> leaf already B<does> exist, this module will B<not> remove 
the named B<dir> upon completion. The log directory leaf will only be removed 
by this module when it is created by this module. See the 
L<Output Logging|"Output Logging"> section, below for further details.

=item -m secs

=item --maxtime secs

Specify the maximum seconds that a single task is allowed to run.
The default is unlimited time. This global setting can be overridden
on a task by task basis via the L<maxtime|maxtime> field name, shown
below.

Tasks that exceed the specified number of seconds will be killed and
a 'Timeout' error will be generated as the result for those tasks.

=item -p [num]

=item --preview [num]

Preview the command list without actually running the commands.
When previewing tasks, the B<L<-K|-K>> (L<--Keep|-K>) and 
B<L<-R|-R>> (L<--Remove|-R>) arguments are optional. By default, when
the optional B<[num]> is omitted, all commands to be run are previewed.

This option can be used as '-p <num>' where 'num' is a number equal to 1.
When used in this manner, will cause the B<first> task in the list to 
be 'previewd' and then the script will exit. This is useful to ensure
that the various task components are assembled correctly.

This option can also be used as '-p <num>' where 'num' is a number equal to 2 
or more. When used in this manner, will cause a random (1 .. 'num') second 
delay in the preview to simulate tasks running with various ending times. 
This mode is useful for testing the 'B<L<-m secs|-m_secs>>' 
(L<--maxtime secs|-m_secs>) option.

=item -r

=item --randomize

Randomize the task list. In some cases this can improve the throughput of 
the list of commands. Default is to run the commands in the original order. 

An example of using this to imporove throughput could include a situation 
where sorting a list of tasks by user name could cause 'power users' tasks
to clog all available concurrent sessions with long running tasks. In this 
case a random sort would allow shorter running tasks to intermix with longer 
running tasks, allowing more tasks to complete in a given time period.

=item -h

=item --help

Display usage help text and ignore other options.

=item -F char

=item --IFS char

This option is only meaningful when used with a 'field separated' 
input file and 'named fields' as described in the
L<Configuration Data|Configuration Data> section. The default
field separator character, when named fields are used, is the 
colon (':') character.

Note that a 'white space' character, such as a space or tab, may be 
used as a delimiter. In this case, take good care to ensure that only
B<one> of the characters appears between each field in the input.

White space characters can be used singly, as a 'space', a 'tab', or
Perl's special '\s' meta character. In addition multiple white space
characters can be specified using Perl's special '\s+' syntax. When
entering these on the command line, make sure to B<either> quote the
string or add an extra escape character, such as B<\\s> or B<\\s+> 
to ensure results are as intended, B<but> don't do both. A warning
will be printed if an invalid IFS character is detected.

 -F " "        -F "     "       # single space or tab character
 -F \\s        -F "\s"          # single space or tab character
 -F \\s+       -F '\s+'         # one or more space and/or tab chars

No matter what character is used to delimit fields within a record
always use a colon character to delimit field names in the '#FieldNames'
header within a data file.

=cut

   =item --parseifs

   Warning: B<This feature is not yet enabled>. Do not imbed encoded IFS
   characters within a data field.

   If the IFS character, either default or otherwise, is contained I<within>
   a data field of I<any> record make sure that it is encoded as explained 
   below, and that the '--parseifs' option is used when running the script.

=pod

=item -D [num]

=item --Debug [num]

Enable debugging output. When 'B<num>' is used, an increasing amount of 
output is displayed. A value of B<2> or B<3> is generally sufficient. The 
default is no debug output.

=back

=head2 Configuration Data

This class requires input from a data file (or STDIN) that is expected
to be a list of tasks (commands) for this class to run. The tasks that 
are run get assembled from various components, depending on how a script
using this class is invoked, and whether or not the data file contains 
I<named fields>.

=head3 Simple Case

In the simple case, where named fields are B<not> used within the input
file, each entire line is used as one I<'command string and argument list'>. 

However, when the B<[ - command [ -arg [...]]]> form of this script is
used, in the simple case, each line will be used as an I<'argument list'>.
This list is passed to the named B<command> I<after> any options and/or
arguments that are entered on the command line.

=head3 Named Input Fields

This class also allows for named input fields in the data file. If named 
fields are used, they must be used in the manner described in this section.
When output from a command will be lengthy redirection can, and probably 
should, be included in the argument list. This is true either when using 
the simple case or when using named fields. See the 
L<Output Logging|"Output Logging"> section for details.

On a line prior to the first data record in the input file, a line in the 
following format must be added to name each field. Optionally, an IFS
character can be defined as well. The IFS character can be any non-numeric
character, including 'white space' characters such as I<space> and I<tab>.
When using white space characters, you probably want to add quotes, as
shown in this example. When imbedded within a file, this will override any
B<L<-F char|-F_char>> (L<--IFS char|-F_char>) command line option value.

 #FieldNames field1:field2:field3...
 #IFSChar " "

The 'B<#FieldNames>' tag must start in column one and a space must appear 
between this tag and the list of field names. The field names may not 
contain spaces and must always be separated by a colon (':') character,
as shown in the line above, no matter what character is used to delimit 
fields in the data records. See the B<L<-F char|-F_char>> 
(L<--IFS char|-F_char>) command line option,
above.  Field names can appear in any order but, obviously, the order in 
the 'FieldNames' list must match the field order in each data record.

Field names can include one or more of the following. They can be in 'lower' 
case or 'UPPER' case, but not 'Mixed' case. When using named fields, the 
only required field is 'B<taskcmd>' (or 'B<TASKCMD>'). Note that if a field 
is left empty for a given data record global command line settings may apply.

This class also allows for special cases with the 'B<#IFSChar>' header.
White space characters can be used singly, as a 'space', a 'tab', or
Perl's special '\s' meta character. In addition multiple white space
characters can be specified using Perl's special '\s+' syntax. The
IFS character can be quoted using double quotes within the header.

 #IFSChar "     "          # single tab character
 #IFSChar " "              # single space character
 #IFSChar "\s"             # single space or tab character
 #IFSChar "\s+"            # one or more space and/or tab characters

This implies that the double quote character can not be used as a field 
separator within a data file. Any other 'comment' lines, where the first
non-blank character is a '#' character, are ignored, and any empty lines 
are ignored when reading the task list.

When specifying a single white space character, make I<sure> that there is 
only B<one> of them in between each field within a record.

=cut

   B<Warning>: B<This class does not yet support encoded IFS chars>. 

   B<Note>: 
   Use care to ensure that any field separator character (IFS char) contained 
   I<within> a data field is encoded. This will prevent the appearance of 
   an 'extra' field which would effectively corrupt a given record. This class 
   reads data fields with embeded IFS characters when they're properly escaped.
   See the B<escapeIFS> and B<unescapeIFS> methods in the L<SDF::File>.

=pod

=over 4

=item taskcmd

When using named fields, B<taskcmd> contains the command to be run 
and, optionally, any or all command options and arguments.

If used without other field names, this is equivalent to not using 
named fields as the entire line will still be used as one I<'command 
string and argument list'>.

When using named fields, B<taskcmd> is the only required field I<unless> 
the B<[ - command [ -arg [...]]]> form of this script is used.

However, when the B<[ - command [ -arg [...]]]> form of this script is
used, in the case of named fields, each I<argN> field, described next,
is I<appended> to any I<'argument list'> entered on the command line. 
In this case, any B<taskcmd> field named in the task list is ignored.

Output from the command can be redirected using standard Bourne shell 
redirection syntax in either a B<taskcmd> string or, when 'argument' 
fields are used, the final B<argN> argument, discussed next. 
See the L<Output Logging|"Output Logging"> section, below, before 
using output redirection.


=item arg0 [ arg1 ... argN ]

Optionally, command options and arguments can be separated into
one or more unique fields. Each field will be a separate element
of the array passed to the system 'B<exec>' when running a
particular command. Any number of argument fields can be included
but any gap in the numeric sequence will terminate the list.

Valid Example:

 #FieldNames taskcmd:arg0:arg1:arg2

Invalid Example:

 #FieldNames taskcmd:arg0:arg2:arg3

In this second example B<arg2> and B<arg3> fields will be 
I<ignored> as there is no B<arg1> found in the 'B<#FieldNames>' 
list.

=item maxtime

This optional field can be used to limit the total number of seconds 
that a particular command is allowed to run. This field will override 
the 'B<L<-m secs|-m_secs>>' (L<--maxtime secs|-m_secs>) command line 
option which can be used as a global time limit for commands that do 
not have a 'B<maxtime>' entry in the data record.

A value of '0' (zero) indicates unlimited time, even when the 
B<L<-m secs|-m_secs>> (L<--maxtime secs|-m_secs>) option is used, 
while a 'null' (empty) value will use the value specified by the 
B<L<-m secs|-m_secs>>  option, if it was used, or unlimited time if the 
B<L<-m secs|-m_secs>>  option was not used.

=item uid

This optional field can be used to specify both the real and effective 
B<User ID> with which to execute the command. For this to work, this
module must be run with sufficient permissions to execute the B<setuid> 
command.

Also see the B<L<statpath>> field, below.

=item gid

This optional field can be used to specify both the real and effective 
B<Group ID> with which to execute the command. For this to work, this
module must be run with sufficient permissions to execute the B<setgid> 
command.

Also see the B<L<statpath>> field, next.

=item statpath

This optional field can be used to specify the path to a data file from 
which the effective B<User ID> and B<Group ID> will be determined and 
then used to execute the B<taskcmd>. For this to work, this module must
be invoked with sufficient permissions to execute the B<setuid> and 
B<setgid> commands.

In addition, this field can refer to any other named 'B<argN>' input
field by using the symbolic construct 'B<%argN%>', where 'B<N>'
corresponds to the argument number. This brief example assumes that
the command to run was named via a command-line argument.

 #FieldNames arg0:statpath
 #IFSChar "\s+"
 /ClearCase/newview/markd      %arg0%
 /ClearCase/newview/robinson   %arg0%

Also see the B<L<uid>> and B<L<gid>> fields, above. Note that, 
when used, this field superceedes the other two fields.

=back


=head2 Output Logging

As mentioned above, logging of the output generated by this module can be 
confusing. There is the output from the main Driver module (sent to the 
'nway' script's STDOUT), and the output from each command that is run by 
the Driver.


=head3 Options That Effect Output

The various options and inputs that effect output logging include the 
B<L<-l dir|-l_dir>> (L<--logidr dir|-l_dir>) option, the 
B<L<-L string|-L_string>> (L<--LogPrefix|-L_string>) option, the 
B<L<-K|-K>> (L<--Keep|-K>) option, the B<L<-R|-R>> (L<--Remove|-R>)
option, output redirection characters included as arguments in the task 
list and, of course, any change to STDOUT and/or STDERR within a given
task command itself.

By default, when none of the above are used, output of a command run 
for a given task list entry is redirected to a file named as follows.

  /tmp/nway.<PID>/CMD_nnnnnn

  where <PID>  is the nway process ID
  and  nnnnnn is an internal sequence 
  number of the command being run

If the default directory already exists, the 'nway' script will exit with 
an error. This module expects to create a new subdirectory 'leaf,' and 
considers it inappropriate to overwrite any prior log files.
When the B<L<-l dir|-l_dir>> option is used, however, the module will
assume that 'User Knows Best,' and will overwrite any or all files
contained therein.

Using the various options listed above, the format and location of the 
file used for each task's output can be altered. For example,

 nway --logdir /tmp/xyzzy --LogPrefix ECHO_ --Keep filename 

will change the above default values such that output for the command run 
for a given task list entry is redirected to a file named as follows.

  /tmp/xyzzy/ECHO_nnnnnn


=head3 Keep or Remove Log Files

You must select one of B<L<-K|-K>> (L<--Keep|-K>) or
B<L<-R|-R>> (L<--Remove|-R>) but not both [unless using the 
B<L<-p|-p_[num]>> (L<--preview|-p_[num]>) option--since no logging 
is done during preview, these arguments are optional in this case].

When the B<L<-K|-K>> (L<--Keep|-K>) option is used, the temporary log 
files are kept in the B<logdir> after each task completes. When the 
'B<nway>' script completes, the log directory is kept intact. Since the 
output from each session is kept, as each task completes B<only a note>
that includes the task's logfile name is included in the 'nway' output.

When the B<L<-R|-R>> (L<--Remove|-R>) option is used, the temporary log 
files are removed from the B<logdir> as each task completes. When the 
'B<nway>' script completes, the log directory is also removed. Since the 
output from each session is removed, as each task completes B<the entire
contents> of each task's logfile is included in the 'nway' output.

One additional note here. When using the B<L<-l dir|-l_dir>> 
(L<--logdir dir|--logdir_dir>) option and the named B<dir> already exists,
this module will B<not> remove the named B<dir> upon completion. The log 
directory leaf will only be removed by this module when it is created by 
this module.


=head3 Using Shell Redirection

It is also possible to use standard Bourne shell redirection syntax within
each command string or argument list to redirect each command's output as 
desired. When this is done, the resulting output is B<not> copied to the
'nway' script's STDOUT. If you go to all the trouble of specifically 
redirecting output for each and every task to a separate log file, the
assumption is that each log will contain a large amount of data. In this 
case only the file name is added to the 'nway' script's output upon 
completion of each task as a reminder of where to look for the logged data.

Of course, it is always possible for a command to redirect its own output
during execution. In this case this module will not detect the output
redirection and simply report that no output was found for the command.

In any and all cases, if a command fails to complete successfully, an
error message is added to the 'nway' script's STDOUT. When output
redirection is used it is then necessary to examine the specific
log file to determine the exact error that caused the failure.

B<Note>: This functionality may change in a future release.


=head2 NWay Resource Identifier

The 'nway' throttling mechanism runs each task in a given 'slot' or queue 
entry location. Obtaining the number of the particular 'nway' queue entry 
from within a given task is occasionally useful. In this case there are 
two ways to obtain the slot number, which is refered to as an 'NRID.'
As the example just below shows, NRIDs are zero-based numbers.

The first way to obtain the NRID is to use the symbolic construct 'B<%nrid%>',
either in lower or upper case, anywhere in the arguments for a given command.
Prior to execution of each command, the appropriate value will be substituted.
This can be on the command line or in the input file whether using named 
fields or not.

The second way to obtain the NRID is within any script or command that is
run by the 'nway' script. The environment variable 'B<NWAY_RESOURCE_ID>'
will be set to the appropriate value.

Note that the format of the NRID may vary slightly, depending on the
concurrency level used. The value will be prepended with zeros to ensure 
that a consistent number of digits will be used throughout. This might 
become useful if a sort of the results, based on the NRIDs, is desired.

B<For example>, when using a concurrency level of 4 ('B<-c 4>') the NRIDs
will be in the range 'B<0 .. 3>'. When using a concurrency level of 18
('B<-c 18>') NRIDs will be in the range 'B<00 .. 17>'. 

=cut
 [---------- Omit the following note from the man page! -----------]
 Programmer's Note: This is not even close to actually true. POE's
 queue mechanism uses whatever it uses, and the concept of an NRID
 is an afterthought. The NWay::Driver class just keeps an arbitrary 
 array that is used to implement a "slot number" position. It works
 and it's useful, and the description here is designed to be useful
 in communicating the concept to users of 'nway'. But it in no way 
 reflects any of the actual inner workings of either 'nway' or POE!
 [------------ Omit the above note from the man page! -------------]
=pod


=head2 Signal Handling Features

This module recognizes the signals B<HUP>, B<INT>, and B<TERM>. Currently, 
each of these signals will cause the Driver process to flush any remaining
(not yet run) tasks from the list and then wait for all running tasks to 
complete. In addition, the B<INT> signal is propagated to all running tasks, 
which will cause the tasks to exit.


=head2 Custom Command Processing

It is also possible to run the 'nway' script that uses this Module in
the following manner.

 nway [<options>] [{ -K | -R }] Perl::Module [ - command [ -arg [...]]]

This allows a custom B<Perl::Module> to replace the B<Proc::NWay::Session> 
module that processes each task/command. The B<Perl::Module> can appear
anywhere that a normal command can be specified. This includes the task
data input file in either the L<Simple Case|"Simple Case"> or when using
L<Named Input Fields|"Named Input Fields> in the data file. When used in
this manner, the L<-K|-K> and L<-R|-K> arguments are optional.

When using this syntax, the B<Perl::Module> must have at least one set 
of double colons ('::'). This is the mechanism that causes the Driver 
module to alter the normal command processing and load the named module.
Be aware that custom module(s) is(are) loaded at run time so any compile
errors will cause the Driver module to terminate in an error state.
Currently when this happens, any running tasks will be left to fend for 
themselves.

For easiest results, the custom module can subclass B<Proc::NWay::Session> 
and then override any or all of the methods and behaviors in the parent 
class. Unfortunately, a good example of this is not included yet.

I<Note well that using the custom command processing features voids any and 
all warranties for this product.>


=head1 WARNINGS

B<Not every> situation calls for an 'B<nway>' solution. Tasks that have a 
B<very> short duration could better be run sequentially, unless the logging 
and error detection features provided by 'B<nway>' outweigh the overhead 
incurred. See the section
L<Negative Effects of Concurrency Processing|"Negative Effects of Concurrency Processing>,
above.

B<Be sure> to read the L<Output Logging|"Output Logging"> section, above
before using this module. Note that the logging functionality may change
in a future release.

=cut

 B<This class does not yet support encoded IFS chars>. 
 When using a character separated data file with named fields as input, use
 care to ensure that any field separator characters (IFS chars) contained 
 I<within> a data field are encoded. This will prevent the appearance of 
 an 'extra' field which would effectively corrupt a given record. This class 
 reads data fields with embeded IFS characters when they're properly escaped.
 See the B<escapeIFS> and B<unescapeIFS> methods in the L<SDF::File> class.

=pod

B<Since a> 'white space' character, such as space(s) and/or tab(s), may be used
as delimiters in the input file, take good care to ensure that only B<one> of 
the characters appears between each field in the input, B<unless> you are using 
the special '\s+' IFS syntax that allows multiple white space characters. And,
in this case, make sure that no white space characters appear within a 'field.'

However, no matter what character is used to delimit fields within a record,
always use a colon character to delimit field names in the '#FieldNames'
header within the input file.

B<The output> logfiles for each task are created starting with a six-digit
number. If the task list exceeds this, additional digits are added as 
needed, and no output logfiles will be overwritten. However, this will 
cause the Unix 'B<ls>' command to sort the log filenames incorrectly, but 
only when there are one million or more output logfiles in the directory.

B<And finally>, using L<Custom Command Processing|"Custom Command Processing">
features I<voids any and all warranties for this product>, either express or 
implied.


=head1 ARCHITECTURE DIAGRAM

Diagram of the 'NWay' Task Throttling Architecture.

 Parent proc runs the show     session procs     command procs
 ==========================    ==============    ============= 
 ____________  ____________     ____________     _____________
 |          |  |          |     |          |     |           |
 |   NWay   |--|  Driver  |-----| Session  |-----| task 1... |
 |__________|  |__________|\    |__________|     |___________|
      ^                      \  ____________     _____________
 _____^______                  \|          |     |           |
 | DataFile |                   | Session  |-----| ...task n |
 |__________|                   |__________|     |___________|



=head1 DEPENDENCIES

This class depends upon the set of B<POE classes>. This class also 
depends on the B<PerlTools> Architecture, a light framework to facilitate 
the creation of Perl tools. In addition an optional external command 
named B<numcpus> can be used to calculate the default and maximum number 
of concurrent processes that will run.


=head1 SEE ALSO

The B<nway> script is an implementation of this module as shown
in the L<Module Synopsis|Module Synopsis> section, above.

The following modules used by this class directly control the 
session processes (no man pages exist for these). See the modules
PTools::Proc::NWay::Driver, 
PTools::Proc::NWay::Logger, 
PTools::Proc::NWay::Session and
PTools::Proc::NWay::SessionLimits.

The following Perl Object Environment (POE) classes are used. See
L<POE::Kernel>,
L<POE::Filter::Reference>,
L<POE::Session> and
L<POE::Wheel::Run>.

In addition, the following PerlTools utility classes are used. See
L<PTools::Counter>,
L<PTools::Date::Format>,
L<PTools::Debug>,
L<PTools::Options>,
L<PTools::Proc::Backtick>,
L<PTools::SDF::ARRAY>,
L<PTools::SDF::File>,
L<PTools::SDF::SDF>,
L<PTools::SDF::Lock::Advisory>,
L<PTools::SDF::Sort::Random>,
L<PTools::String> and 
L<PTools::Time::Elapsed>.

See also L<PTools::Local> and L<PTools::Global> for information about
using the PerlTools framework.

=head1 AUTHOR

Chris Cobb, E<lt>nospamplease@ccobb.netE<gt>

=head1 COPYRIGHT

Copyright (c) 2005-2007 by Chris Cobb. All rights reserved.
This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
