# -*- Perl -*-
#
# File:  PTools/Proc/NWay/Driver.pm
# Desc:  Driver that controls the task parallelism
# Date:  Wed Sep 22 14:01:28 2004
# Stat:  Prototype, Experimental
#
# Abstract:
#        This module forks children to handle slow tasks
#        It uses POE::Filter::Reference so the child tasks can send back
#        arbitrary Perl data. The constant MAX_CONCURRENT limits the
#        number of forked processes that can run at any given time.
# 

package PTools::Proc::NWay::Driver;
use 5.006;
use strict;
use warnings;

our $PACK    = __PACKAGE__;
our $VERSION = '0.07';
our @ISA     = qw( );

use PTools::Local;                            # Local/Global environment
use PTools::Loader qw( generror );            # Demand load Perl modules
use POE qw( Session Filter::Reference );      # Use POE!
use PTools::Proc::NWay::Session;              # run a session for each task
use PTools::Time::Elapsed;                    # Convert time() to readable
use PTools::String;                           # Misc string functions

my $Local        = "PTools::Local";
my $SessionClass = "PTools::Proc::NWay::Session";
my $ElapsedClass = "PTools::Time::Elapsed";
my($Counter, $Debug, $Opts, $Logger);
my($TaskCount,$TaskObj, $NridList);
my $TaskSequence = 1;
my $MaxSecs;

sub new { bless {}, ref($_[0])||$_[0]  }

sub run                                       # entry point
{   my($class,@args) = @_;

    $| = 1;

    $Opts    = $Local->get('app_optsObj')    || die "No 'app_optsObj' found";
    $Counter = $Local->get('app_counterObj') || die "No 'app_counterObj' found";
    $Debug   = $Local->get('app_debugObj')   || die "No 'app_debugObj' found";
    $Logger  = $Local->get('app_logObj')     || die "No 'app_logObj' found";
    $TaskObj = $Local->get('app_taskObj')    || die "No 'app_taskObj' found";
    $MaxSecs = $Opts->maxseconds()           || 0;

    $TaskCount = $TaskObj->count();

    print "Starting tasks\n\n";

    $class->startDriver();                    # create control session

    $poe_kernel->run();                       # run POE 'til we're done

    print "\nCompleted tasks\n";

    return;                                   # That's All, Folks!
}

sub MAX_CONCURRENT { return $Local->get('app_maxSessions') ||3 }

sub startDriver 
{   my($self) = @_;

    # Create the Driver session. This will manage all the children. 
    # Here we define all of the "POE events" that we will service.

    print "    PREVIEW ONLY (no logging will occur)\n\n"  if $Opts->preview;
    print "    starting driver session ...\n";

    $self = new $self unless (ref($self));

    POE::Session->create
    ( object_states =>
	[ $self => {
	      _start => 'start_processing',
	 start_tasks => 'start_tasks',
	   next_task => 'start_tasks',
	 task_stdout => 'handle_task_stdout',    # a child's stdout (Session)
	  task_error => 'handle_task_stderr',    # a child's stderr (Session)
	   task_done => 'handle_task_done',      # a child is done  (Session)
	task_timeout => 'handle_task_timeout',
	task_cleanup => 'handle_task_cleanup',
	    all_done => 'handle_all_done',
       caught_signal => 'handle_signals',
	            }
	],

	## heap => { },                # Note: $self is used insted of "heap" 
    );

    # Don't store a reference to the session as this can prevent POE
    # from deallocating resources correctly. Use accessors instead:
    #   $session = $poe_kernel->get_active_session();
    #   $sessId  = $session->ID;
    #   $heap    = $session->get_heap();      # Use "$self" instead of "heap"

    return;
}

#-----------------------------------------------------------------------
# Note: POE sends a "_start" event as session is created which,
# due to the above "event to method" mapping, brings us here.

sub start_processing
{   my($self, $kernel) = @_[ OBJECT, KERNEL ];

    # Allow other sessions to post events to us:
    $kernel->alias_set("driver");

    # Set up signal handlers to allow clean interrupts
    print "    configuring signal watcher ...\n";
    $kernel->sig( "HUP",  "caught_signal" );
    $kernel->sig( "INT",  "caught_signal" );
    $kernel->sig( "TERM", "caught_signal" );
    $kernel->sig( "CHLD", "child_exited"  );  # caught but ignored, for now...
    
  ### Added a sigCHLD event...even though we ignore it for now,  ###
  ### it's presence will cause POE to reap child procs as they   ###
  ### terminate. This can still cause 'unhandled' child deaths   ###
  ### which show up after this Driver class is done processing.  ###
  ### FIX: set up a CHLD signal handler such that this Driver    ###
  ### session will not quit until the last child proc is reaped. ###

    ## my $taskObj    = $Local->get('app_taskObj') || die "No 'app_taskObj' found";
    if ($Opts->preview and $Opts->preview == 1) {
	$TaskObj->delete(1, $TaskObj->param);
    }
    my $taskCount  = $TaskObj->count();
    my $taskFile   = $Opts->filename();
    my $logDir     = $Opts->logdir();
    my $tasks;

    $taskFile = "STDIN" if $taskFile eq "-";
    print "    read task list from $taskFile\n";
    $tasks = PTools::String->plural( $taskCount, "task", "s");
    print "    will run $taskCount $tasks ";

    if ($Opts->preview and $Opts->preview == 1) {
	print "(previewing FIRST TASK ONLY)\n";
	$Local->set('app_maxSessions', 1);
    } elsif ($Opts->randomize()) {
	print "in random order\n" 
    } else {
	print "in original order\n" 
    }

    $tasks = PTools::String->plural( MAX_CONCURRENT, "task", "s");
    print "    will run ", MAX_CONCURRENT, " $tasks concurrently\n";
    print "    default maxtime set to $MaxSecs seconds\n"  if $MaxSecs;
    print "    writing command output to dir $logDir\n"  unless $Opts->preview;

    # Initialize structure and formatter for "nrid" such that we 
    # can keep track of which "task" runs within which "slot"
    # (aka: NWay Resource ID). This is useful info to some!
    #
    $self->initNridList( MAX_CONCURRENT );

    if (my $debug = $Opts->Debug()) {
	print "    writing debug messages at level $debug\n";
    }
    print "\n";

    $kernel->yield( "start_tasks" );

    return;
}

#-----------------------------------------------------------------------
# Start as many tasks as needed so that the number of tasks is no more
# than MAX_CONCURRENT. Every wheel event is accompanied by the wheel's ID.
# This function saves each wheel by its ID so it can be referred to when
# its events are handled.
#

sub start_tasks
{   my($self, $kernel) = @_[ OBJECT, KERNEL ];

    my($task,$taskId,$taskPid,$taskName,$taskCmd,$taskArgs);

    # This is the control mechanism used to throttle the number of
    # concurrently running task processes. Note that "MAX_CONCURRENT" 
    # is actually a class method. This gives us the ability to switch 
    # to a "single threaded" dispatch queue if/when the need arises.
    # (Note that we must wait to decrement the $TaskCount until after 
    # the task completes. See the "handle_task_done" method, below.)

    ##  my $taskObj = $Local->get('app_taskObj') || die "No 'app_taskObj' found";

    my $logPrefix = $Opts->LogPrefix ||"CMD_";    # cmd-line superceedes

    my @taskIdList  = $self->getTaskIdList();
    my $taskIdCount = $#taskIdList + 1;
    my $maxSecs     = "";                      # allows override for MaxSecs

    while ( $taskIdCount < MAX_CONCURRENT ) {

	my($taskRec) = $TaskObj->delete( 0, 1 );

	last unless ref( $taskRec );

	$taskName  = $logPrefix . sprintf("%6.6d", $TaskSequence++ ); 

	$taskCmd   = $Opts->command;          # cmd-line superceedes
	$taskCmd ||= $taskRec->{line};        # no named fields used
	$taskCmd ||= ($taskRec->{taskcmd}  || $taskRec->{TASKCMD});

	$taskCmd  || die "No 'taskCmd' found here";

	# Note: Asscoiate an NRID with this "$taskName" here
	# where NRID is an internal NWay Resource ID that
	# corresponds to WHICH "task slot" within the given
	# number of available concurrent slots in which a 
	# given task will run. Very useful in some cases!
	#
	my $nrid = $self->mapTask2Nrid( $taskName );

	$maxSecs  = $taskRec->{maxtime};  #  have to allow for '0' here.
	$maxSecs  = $taskRec->{MAXTIME}
	    unless (defined $maxSecs and length($maxSecs));

        #---------------------------------------------------------------
	# Okay, START a new child process to handle a task

	my $session = $SessionClass;

	if ($taskCmd =~ m#\w+\:\:\w+#) {     # [ - Some::Module [ args ]]
	    $session = $taskCmd;
	    Loader->use( $session ) unless (exists $INC{$session});
	}

	$task = $session->run( $taskName, $taskRec, $nrid );

	print "STDERR: ((((((((((( FAILED TO INIT $taskName )))))))))))\n" 
	    unless $task;

	$taskId = $task->ID;
	$taskPid= $task->PID;

	## print "\n";
        print "    Driver: started task=$taskId, session=$taskPid, name=$taskName";
	if (defined $maxSecs and length( $maxSecs )) {   # found in input file?
	    print ", maxtime='$maxSecs'";

	} elsif ($MaxSecs) {                     # timer set with "-m <secs>"?
	    print ", maxtime='$MaxSecs'";

   ###	} else {
   ###	    print ", maxtime='0'";
	}
	print "\n";

	# FIX: handle this here? or in the session?                   # FIX.
	##print "    Driver: $taskName: $taskCmd $taskArgs\n"  if $taskArgs;
	##print "    Driver: $taskName: $taskCmd\n"        unless $taskArgs;

        #---------------------------------------------------------------
	# Finally, stash a few things so we can track the progress.
	# NOTE: The "pid" here is for the task session's process.

	$self->mapTaskId2Task       ( $taskId,     $task       );
       	$self->mapTaskPid2TaskId    ( $taskPid,    $taskId     );
       	$self->mapTaskId2TaskName   ( $taskId,     $taskName   );
	$self->mapTaskId2TaskStatus ( $taskId,     1           );  # "running"
	$self->mapTaskId2TaskRec    ( $taskId,     $taskRec    );
	$self->mapTaskId2MaxTime    ( $taskId,     ($maxSecs || $MaxSecs) );
	$self->incrCount4TaskName   ( $taskName );
	$self->mapTaskId2Nrid       ( $taskId,     $nrid       );

	# Note: collect the new count AFTER "mapTaskId2Task" or we
	# won't get a correct count.

      	@taskIdList  = $self->getTaskIdList();
	$taskIdCount = $#taskIdList + 1;

	##print "++++++++ taskIdCount = '$taskIdCount'\n";

	#if ($Opts->emulate) {
	#    $self->mapServerPid2TaskId( $emulatePid, $taskId );
	#    $self->mapTaskId2ServerPid( $taskId, $emulatePid );  # USE THIS ONE
	#}
        #---------------------------------------------------------------
	# Was a timer value set, either for this task or globally?

	if (defined $maxSecs and length( $maxSecs )) {   # found in input file?

	    # Note: the '-m' override can be zero: meaning unlimited time.
	    $self->setTaskTimer( $taskId, $maxSecs )  if $maxSecs;

	} elsif ($MaxSecs) {            # timer set with "-m <secs>"?
	    $self->setTaskTimer( $taskId, $MaxSecs );
	}
    }
    return;
}


sub handle_task_stdout
{   my($self, $kernel, $result) = @_[ OBJECT, KERNEL, ARG0 ];

    return unless (ref $result eq "HASH");

    my $taskName   = $result->{taskName}   ||"";          # running task
    my $taskPid    = $result->{taskPid}    ||"";          # reformat task PID
    my $stat       = $result->{stat}       || 0;          # 0 or non-zero
    my $nrid       = $result->{taskNrid}   || 0;          # nway resource ID
    my $message    = $result->{mesg}       ||"";          # status text

    my $taskId     = $self->getTaskId4TaskPid( $taskPid );

    print "    Task($taskId): $message (session=$taskPid, task=$taskName, nrid=$nrid)\n";

    if ( $stat ) {
	$self->mapTaskId2TaskStatus( $taskId,   $stat    );
	$self->mapTaskName2Failure ( $taskName, $message );

	## Warn: ONLY the "Session" module should generate
	## the "task_done" event. Or problems WILL occur.
	##
	## $kernel->yield("task_done", $taskId);

    } else {
	$self->delTaskStatus4TaskId( $taskId );      # Okay, all's well so far
    }

    $self->mapTaskId2Result( $taskId, $result );

    return;
}

# Catch and display information from the child's STDERR.  This was
# useful for debugging since the child's warnings and errors were not
# being displayed otherwise.

sub handle_task_stderr
{   my $result = $_[ARG0];        # $result is a simple string here

    # The following errors indicate fatal problems:
    # .  ???

    print "    STDERR: $result\n";
}


# A task has completed. Delete the child wheel, and try to start a new
# task to take its place, unless we have processed all other tasks.

sub handle_task_done
{   my($self, $kernel, $taskId ) = @_[ OBJECT, KERNEL, ARG0 ];

    my $task     = $self->getTask4TaskId( $taskId );
    my $taskName = $self->getTaskName4TaskId( $taskId );
    my $timeout  = $self->timeoutErr4TaskName( $taskName );   # is "1" or "0"

    my $nrid     = $self->delNrid4TaskId( $taskId );

    print "ERROR: *************** NO TASK FOR '$taskId' ***********\n"
	unless $taskName;

    return unless $taskName;


    # Note: $taskStatus values:  0 = success,  non-0 = error 
    #
    my $taskStatus = $self->getTaskStatus4TaskId( $taskId );


    if ( $taskStatus != 0 ) {                        # ouch, error 

	my $count    = $self->getCount4TaskName( $taskName );
	my $attempts = PTools::String->plural( $count, "attempt", "s" );
	my $failure  = "";

	# Note: failed message is slightly different than in skip, below.

	$timeout and $failure = "Timeout failure";
	$timeout  or $failure = "Failure";

	## print "\n";
	print "    Driver: Error: after $count $attempts: $failure for '$taskName'\n";
	$Counter->incr('error');

	$self->mapTaskName2Failure( $taskName, "error occurred after $count $attempts")
	    unless $self->getFailure4TaskName( $taskName );
    }

    #-------------------------------------------------------------------
    # Report the stats from the run

    my $result = $self->getResult4TaskId( $taskId );
    my $runSecs;

    if (ref($result)) {
	my $runTime;

	$timeout and $runSecs = $self->getMaxTime4TaskId( $taskId );
	$timeout  or $runSecs = $result->{runtime} ||0;

	$runTime = $ElapsedClass->granular( $runSecs );

	print "    Driver: taskId='$taskId' name='$taskName' nrid='$nrid' runTime='$runTime'";
	$timeout and print " (TIMEOUT)\n";
	$timeout  or print "\n";
    }

    #-------------------------------------------------------------------
    # Do a little cleanup here which allows POE to do additional cleanup.
    # Make sure that the following deletes "task," which is a POE Wheel.
    #
    # Note: This can be an event or an object method. Is there
    # any problem with doing this? or any benefit??

    $self->cleanup4TaskId( $taskId );                 # Object method

    ### $kernel->yield( "task_cleanup", $taskId );    # POE event
    #-------------------------------------------------------------------
    # Are we done yet? or do we still have task(s) to process?
    # Decrement the $TaskCount here after the task completes so
    # 'start_tasks' does not start too many concurrent tasks.

    $TaskCount--;

    $Counter->incr('total');
    $Counter->accumulate( $runSecs );

    # WARN: Cleanup NRIDs after each task completes!!
    $self->delNrid4TaskId( $taskId );          # unmap attr here
    $self->delTask4Nrid( $nrid );              # clean $NridList here

    if ( $TaskCount ) {
	$Debug->warn(5, "Driver is yielding to 'next_task'");
	$kernel->yield("next_task");

    } else {
	$Debug->warn(5, "Driver is yielding to 'all_done'");
	$kernel->yield( "all_done" );
    }

    $Debug->warn(5, "EXIT TASK DONE: $taskName  TaskCount='$TaskCount'");
    $Debug->warn(5, "-" x 65 );

    return;
}

sub setTaskTimer
{   my($self, $taskId, $maxSecs) = @_;      # object method, not a POE event

    $self->removeTaskTimer( $taskId );

    my $task       = $self->getTask4TaskId( $taskId );
    my $taskPid    = $task->PID;
    my $taskName   = $self->getTaskName4TaskId( $taskId );

    my $event      = "task_timeout";
    my(@eventArgs) = ( $taskPid );
    my $delay      = $maxSecs;          # e.g.: 3600 secs = 60 mins
    my $alarmTime  = time() + $delay;

    # Here we create a callback (postback?) that will, in $delay seconds,
    # generate the named event and pass "@eventArgs" as ARG0, ARG1, etc.
    # Note that "in $delay seconds" really means "at $alarmTime" here.

    my($alarmId) = $poe_kernel->alarm_set( $event, $alarmTime, @eventArgs );

    if ($alarmId) {
	$self->mapTaskId2AlarmId( $taskId, $alarmId );
    } else {
        $! and print "ERROR: error in 'setTimer' method of '$PACK': $!\n";
    }

    $Debug->warn(4, "Set alarm for task='$taskId' delay='$delay' event='$event' args='@eventArgs'");

    return;
}

sub removeTaskTimer
{   my($self, $taskId) = @_;                # object method, not a POE event

    # Note: this method is also called from 'cleanup4TaskId' method.
    # Make sure changes here don't break the cleanup process.

    my $alarmId = $self->delAlarmId4TaskId( $taskId );

    return unless $alarmId;

    my(@stat) = $poe_kernel->alarm_remove( $alarmId );

    $Debug->warn(4, "Del alarm for task='$taskId'");

    return;
}

sub handle_task_timeout
{   my($self, $kernel, $taskPid) = @_[ OBJECT, KERNEL, ARG0 ];

    my $taskId    = $self->getTaskId4TaskPid ( $taskPid );
    my $task      = $self->getTask4TaskId    ( $taskId  );
    my $taskName  = $self->getTaskName4TaskId( $taskId  );
    my $taskRec   = $self->getTaskRec4TaskId ( $taskId  );

    # Have we already cleaned up for this alarm?? If so, ignore it!
    # (An alarm may fire for a task after we have processed a
    # success/fail event for that same task.)
    #
    # Also, no need to set an error here. We pass a "timeout"
    # argument to the "task_done" event handler instead.

    return unless $self->getAlarmId4TaskId( $taskId );

    my $maxSecs = $taskRec->{maxtime} || $MaxSecs;
    my $seconds = PTools::String->plural( $maxSecs, "second", "s" );

    $self->mapTaskId2TaskStatus( $taskId, -1 );
    $self->mapTaskName2Failure ( $taskName, "Timeout: task exceeded $maxSecs $seconds");

    $task->kill();      # KILL THE CHILD SESSION HERE.

    ## Warn: ONLY the "Session" module should generate
    ## the "task_done" event. Or problems WILL occur.
    ## And the "timeout" flag is handled differently now.
    ##
    ## $kernel->yield("task_done", $taskId, "timeout");

    return;
}
#-----------------------------------------------------------------------

sub handle_all_done
{   my($self, $kernel) = @_[ OBJECT, KERNEL ];

    my(@failedList) = $self->getTaskFailedList();

    if ( @failedList ) {
	print "\n";
	print "=" x 72 ."\n";
	print "Error: Failed to complete the following tasks:\n";
	print "=" x 72 ."\n";

	foreach my $taskName (@failedList) {
	    my $reason = $self->delFailure4TaskName( $taskName );
	    print "    $taskName\n\t($reason)\n";
	    ###$Counter->incr('skip');
	}
    }
    print "\n";
    print "=" x 72 ."\n";

    if (! defined $Opts->preview) {
	my $logDir = $Logger->logdir;

	if ($Logger->willRemoveLogDir) {
	    print "    removing logdir $logDir\n";
	    $Logger->removeLogDir;
	    my($stat,$err) = $Logger->status;
	    $stat and print " $err\n";
	} else {
	    print "    keeping logdir $logDir\n";
	}
    }
    print "    stopping driver session\n";
    $kernel->alias_remove("driver");

    0 and print $self->dump('expand');     # DEBUG: ensure cleanup is complete

    # HACK: FIX the Counter class to allow a cumulative time
    #
    my $cumulativeSecs = $Counter->value('cumulative');
    $cumulativeSecs = $ElapsedClass->granular( $cumulativeSecs );
    $Counter->reset('cumulative', $cumulativeSecs);

    return;
}

sub handle_signals
{   my($self, $kernel, $sig) = @_[ OBJECT, KERNEL, ARG0 ];

    # Note: this is a POE event and NOT a "real" Perl signal 
    # handling subroutine. As such, we don't have to be so
    # very careful about not creating new variables here.

    # For now HUP,INT,TERM will simply flush all remaining jobs 
    # from the $TaskObj. Eventually we may want to change this
    # behavior to allow for greater flexibility:
    #
    #  HUP: flush queue, wait for children, then exit
    #  INT: flush queue, wait for children, then exit 
    #      (all children will see SIGINT before we do)
    # TERM: flush queue, wait for children, then exit

    print "    ". "=" x 50 ."\n"; 
    print "    Driver: caught signal SIG$sig\n";

    if ($sig =~ m#^(HUP|INT|TERM)$#) {
	my $remaining = $TaskObj->count;
	my $tasks     = PTools::String->plural( $remaining, "task", "s");

	if ($remaining > 0) {
	    print "    Driver: Warning: flushing $remaining $tasks from queue...\n";
	    $Counter->incr('warn');
	    $TaskObj->delete(0, $remaining);

	} else {
	    print "    Driver: no tasks left in queue...\n";
	}
    }

    if ($sig =~ m#^(INT)$#) {
	print "    Driver: Warning: running tasks will terminate...\n";
	$Counter->incr('warn');
    }
    print "    ". "=" x 50 ."\n"; 

    $kernel->sig_handled;
    return;
}
#-----------------------------------------------------------------------
#  The following methods are to simplify the many attribute mappings
#  maintained in $self. The object that this class creates is a hash
#  reference and is used instead of the POE "heap" in this package.
#  WARN: Use care adding attribute names that have a leading "_" char!
#-----------------------------------------------------------------------

# Attribute mappings can include the following items:
#
# .  Task        -  the object POE creates when starting a Session (Task)
# .  TaskRec     -  the hashRef containing arguments for a Session (Task)
# .  TaskId      -  the object POE creates when starting a Session (Task)
# .  TaskStatus  -  the result determined by parsing log file entries
# .  TaskName    -  the identifier for a particular task that is run
# .  Failure     -  a message string resulting from a failed reformat

sub incrDelay4TaskName      { $_[0]->{_tasknamedelay}       ->{$_[1]} ++      }
sub incrCount4TaskName      { $_[0]->{_tasknamecount}       ->{$_[1]} ++      }

sub mapTaskId2TaskRec       { $_[0]->{_taskid2taskrec}      ->{$_[1]} = $_[2] }
sub mapTaskId2AlarmId       { $_[0]->{_taskid2alarmid}      ->{$_[1]} = $_[2] }
sub mapTaskId2Task          { $_[0]->{_taskid2task}         ->{$_[1]} = $_[2] }
sub mapTaskId2Result        { $_[0]->{_taskid2result}       ->{$_[1]} = $_[2] }
##b mapServerPid2TaskId     { $_[0]->{_serverpid2taskid}    ->{$_[1]} = $_[2] }
##b mapTaskId2ServerPid     { $_[0]->{_taskid2serverpid}    ->{$_[1]} = $_[2] }
sub mapTaskPid2TaskId       { $_[0]->{_taskpid2taskid}      ->{$_[1]} = $_[2] }
sub mapTaskId2TaskStatus    { $_[0]->{_taskid2taskstatus}   ->{$_[1]} = $_[2] }
sub mapTaskId2TaskName      { $_[0]->{_taskid2taskname}     ->{$_[1]} = $_[2] }
sub mapTaskName2Failure     { $_[0]->{_taskname2failure}    ->{$_[1]} = $_[2] }
sub mapTaskId2MaxTime       { $_[0]->{_taskid2maxtime}      ->{$_[1]} = $_[2] }
sub mapTaskId2Nrid          { $_[0]->{_taskid2nrid}         ->{$_[1]} = $_[2] }

sub getTaskIdList           { sort keys %{ $_[0]->{_taskid2task} }     }
sub getTaskFailedList       { sort keys %{ $_[0]->{_taskname2failure} }}

sub getTaskRec4TaskId       { $_[0]->{_taskid2taskrec}      ->{$_[1]} ||"" }
sub getAlarmId4TaskId       { $_[0]->{_taskid2alarmid}      ->{$_[1]} ||"" }
sub getDelay4TaskName       { $_[0]->{_tasknamedelay}       ->{$_[1]} ||"" }
sub getCount4TaskName       { $_[0]->{_tasknamecount}       ->{$_[1]} ||"" }
sub getTask4TaskId          { $_[0]->{_taskid2task}         ->{$_[1]} ||"" }
sub getResult4TaskId        { $_[0]->{_taskid2result}       ->{$_[1]} ||"" }
##b getTaskId4ServerPid     { $_[0]->{_serverpid2taskid}    ->{$_[1]} ||"" }
##b getServerPid4TaskId     { $_[0]->{_taskid2serverpid}    ->{$_[1]} ||"" }
sub getTaskId4TaskPid       { $_[0]->{_taskpid2taskid}      ->{$_[1]} ||"" }
sub getTaskStatus4TaskId    { $_[0]->{_taskid2taskstatus}   ->{$_[1]} ||0  }
sub getTaskName4TaskId      { $_[0]->{_taskid2taskname}     ->{$_[1]} ||"" }
sub getFailure4TaskName     { $_[0]->{_taskname2failure}    ->{$_[1]} ||"" }
sub getMaxTime4TaskId       { $_[0]->{_taskid2maxtime}      ->{$_[1]} ||0  }
sub getNrid4TaskId          { $_[0]->{_taskid2nrid}         ->{$_[1]} ||0  }

sub timeoutErr4TaskName
{   my($self,$taskName) = @_;   
    return( $self->getFailure4TaskName( $taskName ) =~ m#Timeout# ? 1 : 0);
}

sub delTaskRec4TaskId       { delete $_[0]->{_taskid2taskrec}      ->{$_[1]} }
sub delAlarmId4TaskId       { delete $_[0]->{_taskid2alarmid}      ->{$_[1]} }
sub delDelay4TaskName       { delete $_[0]->{_tasknamedelay}       ->{$_[1]} }
sub delCount4TaskName       { delete $_[0]->{_tasknamecount}       ->{$_[1]} }
sub delTask4TaskId          { delete $_[0]->{_taskid2task}         ->{$_[1]} }
sub delResult4TaskId        { delete $_[0]->{_taskid2result}       ->{$_[1]} }
##b delTaskId4ServerPid     { delete $_[0]->{_serverpid2taskid}    ->{$_[1]} }
##b delServerPid4TaskId     { delete $_[0]->{_taskid2serverpid}    ->{$_[1]} }
sub delTaskId4TaskPid       { delete $_[0]->{_taskpid2taskid}      ->{$_[1]} }
sub delTaskStatus4TaskId    { delete $_[0]->{_taskid2taskstatus}   ->{$_[1]} }
sub delTaskName4TaskId      { delete $_[0]->{_taskid2taskname}     ->{$_[1]} }
sub delFailure4TaskName     { delete $_[0]->{_taskname2failure}    ->{$_[1]} }
sub delMaxTime4TaskId       { delete $_[0]->{_taskid2maxtime}      ->{$_[1]} }
sub delNrid4TaskId          { delete $_[0]->{_taskid2nrid}         ->{$_[1]} }

#______________________
# Do we want to do this as an event handler? or an object method??
# Allow for both/either, for now.  THIS WILL REMAIN AN EVENT.
#
sub handle_task_cleanup
{   my($self, $taskId) = @_[ OBJECT, ARG0 ];
    return $self->cleanup4TaskId( $taskId );
}

sub cleanup4TaskId
{   my($self,$taskId) = @_;

    my $task       = $self->getTask4TaskId( $taskId )  if $taskId;
    my $taskPid    = $task->PID                        if $task;

    return unless $taskId and $taskPid;

 ## print "-" x 72 ."\n";
 ## print "TASK CLEANUP: taskId='$taskId'  taskPid='$taskPid'\n";

    my $taskName   = $self->getTaskName4TaskId( $taskId );
 ## my $serverPid  = $self->getServerPid4TaskId( $taskId );

 ## Note: After deleting the "$task" ref, when $task falls out of scope 
 ## POE will do the necessary cleanup on the wheel's resources.

 ## Don't remove the following as we use this value to remove the
 ## internal timer in the call to "removeTaskTimer", just below.
 ## $self->delAlarmId4TaskId    ( $taskId     )  if $taskId;

    $self->delTaskRec4TaskId    ( $taskId     )  if $taskId;
    $self->delDelay4TaskName    ( $taskName   )  if $taskName;
    $self->delCount4TaskName    ( $taskName   )  if $taskName;
    $self->delTask4TaskId       ( $taskId     )  if $taskId;
    $self->delTask4TaskId       ( $taskId     )  if $taskId;
    $self->delResult4TaskId     ( $taskId     )  if $taskId;
 ## $self->delTaskId4ServerPid  ( $serverPid  )  if $serverPid;
 ## $self->delServerPid4TaskId  ( $taskId     )  if $taskId;
    $self->delTaskId4TaskPid    ( $taskPid    )  if $taskPid;
    $self->delTaskStatus4TaskId ( $taskId     )  if $taskId;
    $self->delTaskName4TaskId   ( $taskId     )  if $taskId;
    $self->delMaxTime4TaskId    ( $taskId     )  if $taskId;
    $self->delNrid4TaskId       ( $taskId     )  if $taskId;

 ## Don't remove the following as we use this to report failures
 ## (the report step completes the cleanup of this remaining map):
 ## $self->delFailure4TaskName  ( $taskName   )  if $taskName;

 ## The following will delete the alarm mapped to this taskId.
    $self->removeTaskTimer( $taskId );

 ## print "CLEANUP DONE: taskId='$taskId'  taskPid='$taskPid'\n";
 ## print "-" x 72 ."\n";

    return $task;
}

#-----------------------------------------------------------------------
# NWAY_RESOURCE_ID (aka: NRID, nrid)
# Here we keep track of which "task" runs within which NWay "slot".
# The zero-based "slot number" corresponds to the position within
# the NWay Queue in which a given task is currently running. This
# is merely a guaranteed unique number within the currently running
# pool of active tasks (a sort of "PID" for this given queue).

my $FmtString;

sub initNridList
{   my($self,$max_concurrent) = @_;

    # Initialize a format string using the
    # ORIGINAL value for MAX_CONCURRENT

    my $digits = length( $max_concurrent );
  # $digits = 2 if ($digits == 1);
    $FmtString = "%". $digits .".". $digits ."d";

    return;
}

sub mapTask2Nrid
{   my($self,$task) = @_;

    # Find the next available resource "slot" within 
    # the CURRENT value for MAX_CONCURRENT

    my($idx,$fts) = (0,0);
    foreach $idx (0 .. MAX_CONCURRENT - 1) {
        $fts = $idx;  ## sprintf( $FmtString, $idx );
        last if ! defined $NridList->[ $idx ];
    }
    die "Logic Error: no available NRID locations"
        if (defined $NridList->[ $fts ]);

    die "Logic Error: available NRID locations exceeded"
        if ($fts > MAX_CONCURRENT);

    $NridList->[ $fts ] = $task;

    return sprintf( $FmtString, $fts );
}

sub delTask4Nrid
{   my($self,$nrid) = @_;
    $NridList->[ $nrid ] = undef;
}
#-----------------------------------------------------------------------

sub dump {
    my($self,$expand)= @_;
    my($pack,$file,$line)=caller();
    my $text .= "_" x 25 ."\n";
       $text .= "DEBUG: ($PACK\:\:dump)\n  self='$self'\n";
       $text .= "CALLER $pack at line $line\n  ($file)\n";
    my($value1,$value2);
    foreach my $param (sort keys %$self) {
	$value1 = $self->{$param};
	$value1 = $self->zeroStr( $value1, "" );  # handles value of "0"
	$text .= " $param = $value1\n";

	next unless (($expand) and (ref($value1) eq "HASH"));

        foreach my $key ( sort keys %$value1 ) {
	    $value2 = $value1->{$key};
	    $value2 = $self->zeroStr( $value2, "" );  # handles value of "0"
	    $text .= "     $key = $value2\n";
        }
    }
    $text .= "_" x 25 ."\n";
    return($text);
}

sub zeroStr
{   my($self,$value,$undef) = @_;
    return $undef unless defined $value;
    return "0"    if (length($value) and ! $value);
    return $value;
}
#_________________________
1; # Required by require()
