#!/usr/bin/perl -Tw

# Sample script for mirroring kernel.org via rsync
#
# This script is designed to run as the recipient of a mail from the
# kernel-mirrors address as well as periodically (e.g. every 6 hours)
# from cron.
#
# This script *should* be safe to run setuid if needed.


# --- History ---
# Original version: hpa
# 4 November 2003 (Jim Avera): Modified so it actaully works.  :)
#   Note: I tested this by interactively running the script as a non-root 
#   user: Rsync runs successfully, and the $log_file and @excludes 
#   features seem to work.  I did not try to test the concurrent-request
#   locking mechanisms.  Maybe somebody else can check out that part.

use strict;

use Fcntl qw(:DEFAULT :flock);
use FileHandle;

# Remove this after customizing the rest of this script
die "$0: Please edit customization options\n";

#
# Environment variables.  The PATH should include rsync.
#
$ENV{'PATH'}           = '/bin:/usr/bin';

my $rsync_user = undef;
# Enable these if you need a username/password on the target host
# ===> LKAMS sites should set these up to match the information given
# when you submitted your registration form.
# $ENV{'RSYNC_PASSWORD'} = 'XXXXXXXX';
# $rsync_user = 'username';

# Set this to the host to mirror from.
# ===> LKAMS sites should set this up to match the information given
# when you submitted your registration form.
my $rsync_host = 'rsync.kernel.org';

#
# Uncomment as appropriate to exclude .gz or .bz2 files
#
my @excludes = ();
@excludes = ('*.gz',  '*.gz.sign');
#@excludes = ('*.bz2', '*.bz2.sign');

my %pub;

#
# Real location of (/pub)/linux and (/pub)/software
# --> FIX THIS TO MATCH YOUR REAL LOCATION <--
#
$pub{'linux'}    = '/home/ftp/pub/mirrors/kernel.org/linux';
$pub{'software'} = '/home/ftp/pub/mirrors/kernel.org/software';

# Uncomment this and set it to the real location if you want to
# also mirror /pub/dist
# $pub{'dist'} = '/home/ftp/pub/mirrors/kernel.org/dist';

# 
# This program requires write access to two lock files.
# --> FIX THESE TO POINT TO THE REAL LOCK FILES <--
#
my $lock_file_1 = '/var/lock/rsync/LOCK-rsync-kernel.org';
my $lock_file_2 = '/var/lock/rsync/LOCK-rsync-kernel.org:crit';

# Set this to where you want logging to go.
#my $log_file = "/dev/tty";
my $log_file = '/dev/null';

# Umask for log and lock files
my $umask = 0022;

sub drain_input() {
    my($drain);
    while( read(STDIN,$drain,65536) ) { }
}

sub do_rsync() {
    my(@exclude_list, $ex, $rv);
    
    @exclude_list = ();
    foreach $ex (@excludes) {
	push(@exclude_list, '--exclude', $ex);
    }

    my $rsync_string = defined($rsync_user)
	? $rsync_user.'@'.$rsync_host : $rsync_host;

    my %from_loc = ( 'linux'    => '/pub/linux/',
  		     'software' => '/pub/software/',
		     'dist'     => '/dist/' );

    my $module;
    foreach $module ( keys(%from_loc) ) {
	if ( defined($pub{$module}) ) {
	    print "\n--- BEGIN RSYNC ($module) ---\n";
	    print `date`, "\n";

	    my $from_where = $from_loc{$module};

	    my @cmd = ('rsync', '-rlHtSvz', '--delete', '--timeout=1800',
		       @exclude_list,
		       "rsync://${rsync_string}${from_where}",
		       $pub{$module});
	    my $rv = system(@cmd);
	    
	    print join(" ",@cmd),"\n" if ( $rv != 0 );
	    if ( $rv & 0xFF ) {
		print "rsync exited with signal ", ($rv & 0xFF), "\n";
	    } elsif ( $rv ) {
		print "rsync exited with exit ", ($rv >> 8), "\n";
	    }
	}
    }

    print "\n--- END RSYNC ---\n";
    print `date`, "\n";
}

#
# Avoid email sender getting SIGPIPE
#
if ( -p STDIN ) {
    drain_input();
}

#
# Set umask, and redirect output to the log file
#
umask($umask);
open(LOGFILE, ">> $log_file") or die "Can not open log_file $log_file: $!";
select LOGFILE;  $| = 1;        # Make unbuffered
close(STDOUT);
close(STDERR);
open(STDERR, ">>&LOGFILE");
select STDERR;  $| = 1;
open(STDOUT, ">>&LOGFILE");
select STDOUT;  $| = 1;

#
# Enter critical section
#
open(CRITICAL, "> $lock_file_2") || die "$0: Cannot open lock file $lock_file_2\n";
if ( flock(CRITICAL, LOCK_EX) == -1 ) {
    die "$0: Cannot lock $lock_file_2\n";
}

#
# Check to see if someone else is already doing this
#
open(ROCK, "+> $lock_file_1") || die "$0: Cannot open lock file $lock_file_1\n";
autoflush ROCK 1;
if ( !flock(ROCK, LOCK_EX|LOCK_NB) ) {
    #
    # rsync process already active.  Mark that they have
    # to start over.
    #
    seek ROCK, 0, 0;
    print ROCK "1\n";
    flock(ROCK, LOCK_UN);
    close(ROCK);
    flock(CRITICAL, LOCK_UN);
    close(CRITICAL);
    exit 0;
}
    
#
# No other rsync process.  We're "it".  Note check at end if another
# poll request came in.
#
my $flag;
do
{
    seek ROCK, 0, 0;
    print ROCK "0\n";
    flock(CRITICAL, LOCK_UN); # Drop critical section lock

    do_rsync();

    flock(CRITICAL, LOCK_EX); # Get critical section lock
    seek ROCK, 0, 0;
    $flag = scalar <ROCK>;
    chomp $flag;
} while ( $flag );
    
close(ROCK);
flock(CRITICAL, LOCK_UN);
close(CRITICAL);

exit 0;
