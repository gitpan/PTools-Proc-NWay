# -*- Perl -*-
#
# File:  PTools/Proc/NWay/Session.pm
# Desc:  Session that will control a given "task."
# Date:  Wed Sep 22 14:01:28 2004
# Stat:  Prototype, Experimental
#
# Abstract
#        Start a single session to perform a single task. The total
#        number of concurrent tasks is controled by the Driver.
#
# Note:  Don't call "exit()" here. Excerpt from POE::Wheel::Run man page:
#        Note: Do not call exit() explicitly when executing a subroutine. 
#        POE::Wheel::Run takes special care to avoid object destructors 
#        and END blocks in the child process, and calling exit() will 
#        thwart that. You may see "POE::Kernel's run() method was never 
#        called." or worse.
#
package PTools::Proc::NWay::Session;
use 5.006;
use strict;
use warnings;

our $PACK    = __PACKAGE__;
our $VERSION = '0.06';
our @ISA     = qw( );

use PTools::Local;                            # Local/Global environment
use PTools::Date::Format;                     # $date=time2str("%c",time());
use POE qw( Wheel::Run  Filter::Reference );  # Use POE!

# POE::Filter::Reference, used here in a non-POE child process, lets
# us pass complex Perl data structures back to the parent process.

my $Local = "PTools::Local";
my($Debug,$Opts,$Logger,$Pid);
my $Filter = new POE::Filter::Reference;
my $DateFormat = "PTools::Date::Format";
my $TimeFmtStr = "%Y%m%d.%X";


sub run                                       # main entry point
{   my($class, @taskArgs) = @_;

    $Debug = $Local->get('app_debugObj') || die "No 'app_debugObj' found here";
  # $Debug->warn(0,">>>>> 'process' viewTag='$cmdArgs[0]' >>>>>");

    # Every wheel event is accompanied by the wheel's ID. Here we return
    # our "ID" so the Driver session recognizes us as events are handled.
    # Wheel::Run's Program may be a code reference. Here it's called via
    # a short anonymous sub so we can pass in parameters. (Use a generic
    # array here and let the "runTask" method, below, figure out what it's
    # expecting. This will simplify any changes later on. Oh BTW, params
    # are passed here from the "start_tasks" method in the Driver class.)
    #
    # Note: The events generated here are handled in the Driver session, 
    # and that's where the handler methods are defined. This provides the 
    # communication path from child to parent.

    my $task = POE::Wheel::Run->new
    (   Program      => sub { $class->runTask( @taskArgs ) },
	StdoutFilter => POE::Filter::Reference->new(),
	StdoutEvent  => "task_stdout",    # Note: event renamed in Driver.
	StderrEvent  => "task_error",     # Note: event renamed in Driver.
       	CloseEvent   => "task_done",      # GENERATE HERE! Not in Driver!
    );

    return $task;     # return task object so Driver can track everything
}

#-----------------------------------------------------------------------
# The following subroutines are not POE events! They are class methods
# run w/in a child process. They use POE::Filter::Reference since they
# allow returning data structures, via reference, back to the parent.
#

sub runTask                              # NOW in Child process
{   my($class,$taskName,$taskRec,$nrid) = @_;

    $Opts   = $Local->get('app_optsObj') || die "No 'app_optsObj' found here";
    $Logger = $Local->get('app_logObj')  || die "No 'app_logObj' found here";

    $Pid = $$;                           # task/session PID

    $ENV{"NWAY_RESOURCE_ID"} = $nrid;    # "slot" in which task is running

    # Since we're using POE::Filter::Reference we can pass whatever
    # arbitrary Perl data structure we want back to the parent proc.
    # In this case, it's a hash reference.
    #
    # NOTE: {stat} will equal:  0 = success,  non-0 = error

    my $result = {                       # this script's "return value"
	  taskName => $taskName,
	   taskPid => $Pid,
	  taskNrid => $nrid,
	      stat => "0",               #  0 = success, 1 or -1 = failure
	      mesg => "",                # "" on success or "failure messgae"
    };

  # $class->err2parent( "DEBUG: task='$taskName' pid='$Pid' nrid='$nrid'" );
    #-------------------------------------------------------------------
    # Perform the ClearCase V6 View transformation, but 
    # ONLY if the "-f" cmd-line option was used.

    $result->{mesg} = "starting task";
    $class->out2parent( $result );

    my($stat,$mesg,$startTime,$endTime,$runTime) = (0,"",0,0,0);

    #______________________________________________
    # SET uid and gid to owner of view storage, and
    # CD  into the view storage subdirectory

    ($stat,$mesg) = $class->setUidGid( $taskName, $taskRec )   unless $stat;
  # ($stat,$mesg) = $class->changeDir( $taskName, $taskRec )   unless $stat;

    #______________________________________________
    # RUN the task

    $startTime = time();

    ($stat,$mesg) = $class->processCmd( $nrid, $taskName, $taskRec, $result )
	unless $stat;

    $endTime = time();
    $runTime = $endTime - $startTime;

    #______________________________________________
    # GENERATE a result. This hashref is passed back to
    # the parent process via POE::Filter::Reference.

    $result->{starttime} = $startTime;
    $result->{endtime}   = $endTime;
    $result->{runtime}   = $runTime;

 ## if (! $stat) {                             # DEBUG:
 ##   # my $rand = sprintf("%1.0f", rand(1) );              # random 0 or 1
 ##	my $rand = sprintf("%1.0f", rand(5) );              # random 0 .. 5
 ##	($stat,$mesg) = (-1,"DEBUG: RANDOM ERROR GENERATED") if ( $rand > 3 );
 ## }

    my $date = $DateFormat->time2str( $TimeFmtStr, time() );
    $result->{mesg} = "$date: END of task";
    $result->{stat} = 0;
    $class->out2parent( $result );
    
    if ($stat) { 
	$result->{stat} = $stat;
	$result->{mesg} = $mesg;
	$class->out2parent( $result );
    }
    #-------------------------------------------------------------------

    return;
}

sub setUidGid
{   my($class,$taskName,$taskRec) = @_;

    my $uid = $taskRec->{uid} || $taskRec->{UID};
    my $gid = $taskRec->{gid} || $taskRec->{GID};
    my $path= $taskRec->{statpath} || $taskRec->{STATPATH};

    # Allows for symbolic reference to another "argN" field name,
    # when the 'statpath' field =~ /%argN%/
    #
    $path = $taskRec->{$1}  if ($path and $path =~ m#^\%(arg\d+)\%$#i);

    return unless ($uid or $gid or $path);      # no harm, no foul

    if ($path) {
	my(@stat)   = CORE::stat( $path );
	($uid,$gid) = @stat[4,5];
	($uid and $gid) or return (-1,"CORE::stat failed: $!");

	$class->err2parent( "DEBUG: uid='$uid' gid='$gid' from path='$path'" );
    }

    # $class->err2parent( "DEBUG: uid='$uid' gid='$gid' ($path)" );

    ($),$() = ($gid,$gid)  if $gid;     # set eff/real Gid
    ($>,$<) = ($uid,$uid)  if $uid;     # set eff/real Uid

    if ( $gid and $( != $gid ) {
	return( -1, "Can't set Gid to $gid" );
    } elsif ( $uid and $< != $uid ) {
	return( -1, "Can't set Uid to $uid" );
    }
    return(0,"");
}

sub changeDir
{   my($class,$taskName,$taskRec) = @_;

    # $class->err2parent( "DEBUG: cwd='$path'" );

    my $path = ($taskRec->{cwd} || $taskRec->{CWD});

    return(0,"") unless $path;

    chdir $path  or return( -1, "Can't cd to $path");

    return(0,"");
}

sub processCmd
{   my($class,$nrid, $taskName,$taskRec,$result) = @_;

    #--------------------------------------------------------
    # The "$taskCmd" to run can be specified in various ways.
    # .  the "- command" argument when running the script
    # .  the entire 'line' of a data file entry (cmd + args)
    # .  the named 'taskcmd' field of a data file entry
    #
    # When the "- command" argument style was used, the
    # 'line' entry of a data file becomes its arguments.
    #
    # Note well: Any extra arguments entered on the command 
    # line are prepended PRIOR to the data file arguments.
    #--------------------------------------------------------

    my($taskCmd,@taskCmdArgs);
    my($reOUT,$reERR) = (0,0);      # STDOUT/STDERR redirection used??

    ## Pattern match to detect output redirection:
    ## ORIG: ## if ($taskCmd =~ m#\>\s*([^\s]*)\s*2\>\s*((&\s*1)|([^\s]*))#) {
    ##
    ## This new pattern match allows for either or both in 1 or 2 fields
    ## NEW: ($1 = ">" or ">>") ($2 = filename) ($3 = "2>") ($4 = filename)
    ##
    my $outputRedirect = "(>?>\\s*([^\\s]*))?\\s*(2>\\s*(&\\s*1|[^\\s]*))?";

    if ($Opts->command) {
	$taskCmd = $Opts->command;                  # set the command, and
	push( @taskCmdArgs, @{ $Opts->args() } );   # INIT arg list, if any

	if ($taskRec->{line}) {                     # 'line' always lower case
	    push( @taskCmdArgs, $taskRec->{line});  # ADD TO the arg list
	}
	($reOUT,$reERR) = ($2,$4) if ($taskCmd =~ m#$outputRedirect#);
	($reOUT,$reERR) = ($2,$4) 
	    if ($taskRec->{line} and $taskRec->{line} =~ m#$outputRedirect#);

    } elsif ($taskRec->{line}) {                    # 'line' always lower case
	$taskCmd = $taskRec->{line};

	($reOUT,$reERR) = ($2,$4) if ($taskCmd =~ m#$outputRedirect#);

    } else {
	$taskCmd = $taskRec->{taskcmd} || $taskRec->{TASKCMD};

	($reOUT,$reERR) = ($2,$4) if ($taskCmd =~ m#$outputRedirect#);
    }

    $taskCmd || return(-1,"No 'taskcmd' found");
    
    # NOTE: a 'line' entry in the data file is mutually exclusive with
    # any 'argN' entries, as this means there are no "named fields".
    # Any "@taskCmdArgs" collected from "$taskRec->{line}", above, are
    # guaranteed not to clash with the following loop.

    if ($taskRec->{"arg0"} || $taskRec->{"ARG0"}) {
	my($idx,$arg) = (0,"");

	while ( $arg = ($taskRec->{"arg$idx"} || $taskRec->{"ARG$idx"}) ) {
	    last unless defined $arg;
	    push @taskCmdArgs, $arg;

	    # Detect if STDOUT/STDERR redirection used
	    #
	    if ($arg =~ m#$outputRedirect#) {
		$reOUT ||= $2;
		$reERR ||= $4; 
	    }
	    $idx++;
	}
    }
    unshift @taskCmdArgs, $taskCmd;

    #___________________________________________________________________
    # Perform any necessary substitution for "%nrid%" construct

    foreach (@taskCmdArgs) {  s#%nrid%#$nrid#ig  }

    #___________________________________________________________________
    # If output redirection was NOT specified in the command
    # or arg list, then send output to the default log file.

    my $logFile = $Logger->genLogFileName( $taskName );

    push @taskCmdArgs, "> $logFile" if (! $reOUT);

    if (! $reERR) {
	push @taskCmdArgs, "2>$logFile"  if ($reOUT); 
	push @taskCmdArgs, "2>&1"    unless ($reOUT); 
    }

    #___________________________________________________________________
    # Are we Previewing?? If so, just display what we WOULD do.
    # Also, if '-p <n>' was used where <n> is greater than 1,
    # simulate an arbitrary amount of "work time." Don't do this
    # when <n> equals 0, as this is the value for '-p' w/out any
    # <n>, and also as this wouldn't give any meaningful delay.
    # (Note: if '-p 1' was used, that's handled in the Driver.)

    my $date    = $DateFormat->time2str( $TimeFmtStr, time() );
    my $preview = $Opts->preview();

    if (defined $preview) {
	$class->err2parent( "$date: PREVIEW '@taskCmdArgs'" );

	if ($preview > 1) {                         # don't do for just "-p"
	    srand( time() ^ ($$ + ($$ << 15)) );
	    my $rand = sprintf("%1.0f", rand( $preview ) + 1 );   # 1 .. n

	    $class->err2parent("DELAY $taskName for '$rand' seconds");
	    sleep( $rand );
	}

	return( 0, "" );
    }
    #___________________________________________________________________
    # Special case log entry when output redirection was detected
    # ... NOT.
    #
    # my $logFile = $Logger->genLogFileName( $taskName );
    # $class->logHeader( $logFile,$reOUT,$reERR ) if ($reOUT or $reERR);

    #___________________________________________________________________
    # Okay ... put our nickel in, and turn the crank ...

  # $class->err2parent( "$date: RUN '@taskCmdArgs'" );   # DEBUG

    $result->{mesg} = "$date: RUN '@taskCmdArgs'";
    $class->out2parent( $result );

    my($stat, $shellStatus) = $class->runCmd( @taskCmdArgs );

    $class->logResult( $taskName, $shellStatus, $result, $reOUT );

    $shellStatus and return( 1, "task failed (stat=$shellStatus)");

    return(0,"");
}

# FIX: redirect cmd to log?
# This part is still hack/hack/cludge. Figure out a better strategy.

sub logHeader                                 # NOT currently used.
{   my($class,$logFile,$reOUT,$reERR) = @_;

    return if defined $Opts->preview;

    local(*LOG);
    if (open(LOG, ">$logFile")) {
	if ($reOUT or $reERR) {       # FIX: notice if ">" or ">>" here
	    print LOG "#" x 72 ."\n";
	    print LOG "# Note: STDOUT > to $reOUT\n"  if $reOUT;
	    print LOG "# Note: STDERR > to $reERR\n"  if $reERR;
	    print LOG "#" x 72 ."\n";
	}
	close(LOG) || $class->err2parent("OUCH: can't close '$logFile': $!");
    }
    return;
}

sub logResult
{   my($class,$taskName,$shellStatus,$result,$reOUT) = @_;

    ## $class->err2parent("-" x 40)  if $shellStatus;

    if ($Logger->willRemoveLogFile) {
	$result->{mesg} = join("", $Logger->getLogData() );
	chomp $result->{mesg};
	if (! $result->{mesg}) {
	    ($result->{mesg} ||= "[See file $reOUT]")  if   $reOUT;
	    ($result->{mesg} ||= "[No output found]")  if ! $reOUT;
	} else {
	    $result->{mesg} = "[". $result->{mesg} ."]";
	}
	#$class->out2parent( $result );

	$class->out2parent( $result )          if ! $shellStatus;
	$class->err2parent( $result->{mesg} )  if   $shellStatus;

    } else {
	my $logFile = $Logger->logFile;
	$result->{mesg} = "[See file $reOUT]"    if   $reOUT;
	$result->{mesg} = "[See file $logFile]"  if ! $reOUT;

	$class->out2parent( $result );
    }

    if ($shellStatus) {
	my $date = $DateFormat->time2str( $TimeFmtStr, time() );
	$class->err2parent( "$date: Error: '$taskName' ($shellStatus)" );
    }

    ## $class->err2parent("-" x 40)  if $shellStatus;

    #___________________________________________________________________
    # If the user did NOT use the "-l <dir>" option then
    # we'll attempt to remove the temp logdir when all done.
    # So, after we've reported the results, remove the file.

    $Logger->removeLogFile if $Logger->willRemoveLogFile;
    #___________________________________________________________________

    return;
}

sub runCmd
{   my($self,$cmd,@args) = @_;

    # Run a command using Perl's "open()" via the pipe ("|") character.
    # Note: It's not appropriate in this script to simply run a child
    # using Perl's `backtick` operator. Here we must explicitly open
    # the system command pipe and test for multiple failure modes.

    my($result,$stat,$sig,$shellStatus) = ("",0,0,"0");
    local(*CMD);

    # FIX: allow redirection into a log file
    #      for both OUT and ERR (separately??)

  # if (! (my $chpid = open(CMD, "exec $cmd @args 2>&1 |")) ) {

    if (! (my $chpid = open(CMD, "exec $cmd @args |")) ) {
        ($stat,$result) = (-1, "fork failed: $!");
	$self->err2parent("=" x 20 ."ERROR: $result");

    } else {
        my(@result) = <CMD>;             # ensure the pipe is emptied here
        $result = (@result ? join("",@result) : "");
        chomp($result);

        if (! close(CMD) ) {
            if ($!) {
                $stat = -1;
                $result and $result .= "\n";
                $result .= "Error: command close() failed: $!";
		$self->err2parent("=" x 20 ."ERROR: $result");
            }
            if ($?) {
                ($stat,$sig,$shellStatus) = $self->rcAnalysis( $? );
            }
        }
    }

    ## $self->err2parent("=" x 20 ." STAT: $shellStatus");

    return( $stat, $shellStatus, $!, $? );
}

sub rcAnalysis
{   my($self,$rc) = @_;
    #
    # Modified somewhat from the example in "Programming Perl", 2ed.,
    # by Larry Wall, et. al, Chap 3, pg. 230 ("system" function call)
    # This now works on HP-UX systems (thanks to Doug Robinson ;-)
    # Returned "$stat" will mimic what the various shells are doing.
    #
    my($stat,$sig,$shellStatus);          # $shellStatus used in log files.

    $rc = $? unless (defined $rc);

    $rc &= 0xffff;

    if ($rc == 0) {
        ($stat,$sig,$shellStatus) = (0,0,"0");
    } elsif ($rc & 0xff) {
        $rc &= 0xff;
        ($stat,$sig,$shellStatus) = ($rc,$rc,"signal $rc");
        if ($rc & 0x80) {
            $rc &= ~0x80;
            $sig = $rc;
            $shellStatus = "signal $sig (core dumped)";
        }
    } else {
       $rc >>= 8;
       ($stat,$sig,$shellStatus) = ($rc,0,$rc); # no signal, just exit status
    }
  # 0 and print "DEBUG: rcAnalysis is returning ($stat,$sig,$shellStatus)\n";
    # Note: $shellStatus is the closest value as the Shell's $?
    return($stat,$sig,$shellStatus);
}

sub out2parent
{   my($class,$hashRef) = @_;
    # Strange syntax needed here to pass reference to parent process,
    # but this allows us to pass complex data structures. However,
    # the parent must be designed to expect what we actually send.
    print STDOUT @{ $Filter->put( [ $hashRef ] ) };
}

sub err2parent
{   my($class,$string) = @_;
    # Simple syntax used here to pass string to parent process,
    # but the text must end with a newline character.
    print STDERR "($Pid) $string";
    print STDERR "\n" unless $string =~ m#\n$#;
}
#_________________________
1; # Required by require()
