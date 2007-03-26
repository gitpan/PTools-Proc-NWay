# -*- Perl -*-
#
# File:  PTools/Proc/NWay/Logger.pm
# Desc:  Facilitate output logging for the various NWay processes
# Date:  Wed Feb 02 17:03:35 2005
# Stat:  Prototype, Experimental
#
# Synopsis:
#        use Proc::NWay::Logger;
#
#        # Manage log subdir
#        $logObj = new Proc::NWay::Logger;
#        $logObj->removeLogDir if $logObj->willRemoveLogDir;
#
#        # Manage session/task logging
#        $logFile = $logObj->genLogFileName( $taskName );
#        $logData = $logObj->getLogData;
#        $logObj->removeLogFile if $logObj->willRemoveFile;
#
package PTools::Proc::NWay::Logger;
use 5.006;
use strict;
use warnings;

our $PACK    = __PACKAGE__;
our $VERSION = '0.04';
our @ISA     = qw( );

use PTools::Local;                            # Local/Global environment
use PTools::Debug;                            # simple "debug output" class
use PTools::Options;                          # simple i/f to Getopt::Long

my($Debug, $Opts);
my $LogDirDflt;

sub set    { $_[0]->{$_[1]}=$_[2]         }   # Note that the 'param' method
sub get    { return( $_[0]->{$_[1]}||"" ) }   #    combines 'set' and 'get'
sub param  { $_[2] ? $_[0]->{$_[1]}=$_[2] : return( $_[0]->{$_[1]}||"" )  }
sub setErr { return( $_[0]->{STATUS}=$_[1]||0, $_[0]->{ERROR}=$_[2]||"" ) }
sub status { return( $_[0]->{STATUS}||0, $_[0]->{ERROR}||"" )             }
sub stat   { ( wantarray ? ($_[0]->{ERROR}||"") : ($_[0]->{STATUS} ||0) ) }
sub err    { return($_[0]->{ERROR}||"")   }

sub logDir         { return($_[0]->{logDir}         ||"" ) }
sub logFile        { return($_[0]->{logFile}        ||"" ) }
sub createdLogDir  { return($_[0]->{createdLogDir}  ||"" ) }
sub willRemoveDir  { return($_[0]->{willRemoveDir}  ||"" ) }
sub willRemoveFile { return($_[0]->{willRemoveFile} ||"" ) }

*logdir            = \&logDir;
*logfile           = \&logFile;
*willRemoveLogDir  = \&willRemoveDir;
*willRemoveLogFile = \&willRemoveFile;

sub new
{   my($class,$debug,$opts) = @_;

    bless my $self  = {}, ref($_[0])||$_[0];

    $Debug = $debug;
    $Opts  = $opts;

    my $basename = PTools::Local->getBasename();
    $self->set('basename', $basename);

    $LogDirDflt = "/tmp/${basename}.$$";

    $opts and $self->verifyLogDir();

    return( $self ) unless wantarray;
    return( $self, $self->status);
}

#-----------------------------------------------------------------------
# Manage Session/Task logging
#-----------------------------------------------------------------------

sub getLogData
{   my($self) = @_;

    $self->setErr(0,"");

    my $logFile = $self->logFile;
    my(@logData)= ();

    if (! $logFile) {
	$self->setErr( -1, "Error: No 'logFile' found in 'getLogData' of '$PACK'");
        return @logData;      # empty list here
    }

    local(*IN);
    if (open(IN, "<$logFile")) {
	(@logData) = <IN>;
        close(IN) or
	    $self->setErr(-1, "Error: Can't close '$logFile' in 'getLogData' of '$PACK': $!");
    } else {
	$self->setErr(-1, "Error: Can't read '$logFile' in 'getLogData' of '$PACK': $!");
    }
    return @logData;
}

sub genLogFileName
{   my($self,$taskName) = @_;

    $self->setErr(0,"");

    my $logFile = $self->logFile;
    return $logFile if $logFile;

    my $logDir = $self->logDir;

    if (! $logDir ) {
	$self->setErr( -1, "Error: No 'logDir' found in 'genLogFileName' of '$PACK'");
	return "";
    }
    $self->set('logFile', "$logDir/$taskName");

    return $self->logFile;
}

sub removeLogFile
{   my($self) = @_;

    $self->setErr(0,"");

    return if $Opts->preview;                # "should" not get here on preview
    return unless $self->willRemoveFile;

    my $logFile = $self->logFile;

    if (! $logFile ) {
	$self->setErr( -1, "Error: No 'logFile' found in 'removeLogFile' of '$PACK'");
	return;
    }
    unlink $logFile 
	or $self->setErr(-1, "Error: Failed to unlink '$logFile': $!");

    return;
}

#-----------------------------------------------------------------------
# Manage log subdirectory
#-----------------------------------------------------------------------

sub verifyLogDir
{   my($self) = @_;

    $self->setErr(0,"");

  # my $logDir = $Opts->logdir || ( $LogDirDflt ."_". time() );

    my $logDir = $Opts->logdir || $LogDirDflt;
    $self->set('logDir', $logDir);

    #-----------------------------------------------------------
    # Handles the following cases. Note that, when user specifies
    # '-l <logdir>, if this module does not create the subdir leaf 
    # it will not remove it either. Even when '-R' was used. In
    # this case only the logfiles will be removed.
    #
    #  $logDir
    # -----------------
    # . Exists
    #   -  isa Dir       (ok if "-l <dir>" used, err otherwise)
    #   -  not Dir       (err)
    #   -  not readable  (err)
    #   -  not writable  (err)
    # . Doesn't Exist    (ok if can create it, err otherwise)
    #-----------------------------------------------------------

    $self->set('willRemoveDir',  "1")  if $Opts->Remove;
    $self->set('willRemoveFile', "1")  if $Opts->Remove;

    local(*DIR);
    if (opendir( DIR, $logDir )) {
	closedir( DIR ) || die "Error: Can't closedir '$logDir': $!";

	if (! -w $logDir) {
	    $self->setErr( -1, "Error: Log dir '$logDir' not writable");

	} elsif (! $Opts->logdir) {
	    $self->setErr( -1, "Error: Log dir '$logDir' exists; remove/rename or use '-l <dir>'");
	} else {
	    # If the directory exists AND user specified it via "-l <dir>"
	    # then let's just assume that they know what they're doing.
	    # Don't bother to check to see if the directory has entries.
	    # If it overwrites existing log file, or any existing files
	    # are not over-writable, then "oh well."
	}
	$self->set('createdLogDir', "0");
	$self->set('willRemoveDir', "0");   # Note: EVEN with '$Opts->Remove' 

    } else {
	if ($! =~ m#No such file or directory#) {
	    $self->createLogDir( $logDir );

	} elsif ($! =~ m#Not a directory#) {
	    $self->setErr( -1, "Error: Log dir '$logDir' not a directory");
	} elsif ($! =~ m#permission denied#) {
	    $self->setErr( -1, "Error: Log dir '$logDir' not readable");
	} else {
	    $self->setErr( -1, "Error: Log dir '$logDir': $! ");
	}
    }
    return;
}

sub createLogDir
{   my($self,$logDir) = @_;

    $self->setErr(0,"");

    return if $Opts->preview;

    if (mkdir $logDir) {
	$self->set('createdLogDir', "1");
    } else {
	$self->setErr(-1,"Error: Can't create logdir '$logDir': $!");
    }
    return;
}

sub removeLogDir
{   my($self,$logDir) = @_;

    $self->setErr(0,"");

    return if $Opts->preview;                # "should" not get here on preview
    return unless $self->willRemoveDir;

    $logDir ||= $self->get('logDir');

    if (! $logDir) {
	$self->setErr(-1,"Error: No 'LogDir' found in 'removeLogDir' method of '$PACK'");
    } elsif (rmdir $logDir) {
	$self->set('createdLogDir', "");
	$self->set('willRemoveDir', "");
    } else {
	$self->setErr(-1,"Error: Can't remove logdir '$logDir': $!");
    }
    return;
}

sub dump {
    my($self)= @_;
    my($pack,$file,$line)=caller();
    my $text  = "DEBUG: ($PACK\:\:dump)\n  self='$self'\n";
       $text .= "CALLER $pack at line $line\n  ($file)\n";
    my $value;
    foreach my $param (sort keys %$self) {
	$value = $self->{$param};
	$value = $self->zeroStr( $value, "" );  # handles value of "0"
	$text .= " $param = $value\n";
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
