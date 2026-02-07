# Copyright (c) 2009-2012 Zmanda Inc.  All Rights Reserved.
#
# This program is free software ; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation ; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY ; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program ; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#
# Contact information: Carbonite Inc., 756 N Pastoria Ave
# Sunnyvale, CA 94086, USA, or: http://www.zmanda.com

use Test::More tests => 29 ;
use File::Path ;
use Data::Dumper ;
use strict ;
use warnings ;

use lib '@amperldir@' ;
use Installcheck::Config ;
use Amanda::Config qw( :init :getconf ) ;
use Amanda::Changer ;
use Amanda::Device qw( :constants ) ;
use Amanda::Debug qw( debug ) ;
use Amanda::Header ;
use Amanda::Xfer ;
use Amanda::Taper::Scribe qw( get_splitting_args_from_config ) ;
use Amanda::MainLoop ;

# Add these to instantiate a normal Taper::Scan object

use Amanda::Paths ;
use Amanda::Tapelist ;
use Amanda::Storage ;
use Amanda::Taper::Scan ;

# Disable Debug's die() and warn() overrides

Amanda::Debug::disable_die_override() ;

# Put the debug messages somewhere

Amanda::Debug::dbopen("installcheck") ;
Installcheck::log_test_output() ;

# Use some very small vtapes

my $volume_length = 512*1024 ;

# Set up a test configuration. Might as well turn on taper debugging. Allow
# autolabel of empty slots so we don't have to create volume labels in
# reset_taperoot.

my $testconf ;
$testconf = Installcheck::Config->new() ;
$testconf->add_tapetype("TEST-TAPE", [
    "length" => ($volume_length / 1024) . " k",
]) ;
$testconf->add_param('debug_taper','9') ;
$testconf->add_param('autolabel', '"FAKE-%%%" empty') ;
$testconf->write() ;

my $cfg_result = config_init($CONFIG_INIT_EXPLICIT_NAME, 'TESTCONF') ;
if ($cfg_result != $CFGERR_OK) {
    my ($level, @errors) = Amanda::Config::config_errors() ;
    die(join "\n", @errors) ;
}

# The tapelist file

my $tapelistFile = $CONFIG_DIR.'/'.get_config_name() ;
$tapelistFile .= '/'.getconf($CNF_TAPELIST) ;

# Vtape directory structure

my $taperoot = "$Installcheck::TMP/Amanda_Taper_Scribe" ;


# reset_taperoot(num_slots)

# reset_taperoot will set up a clean Vtape directory structure with the
# specified number of slots. No tape labels, let autolabel deal with that.

sub reset_taperoot
{ 
  my ($nslots) = @_ ;

  if (-d $taperoot) { rmtree($taperoot) ; }
  mkpath($taperoot) ;

  for my $slot (1 .. $nslots)
  { mkdir("$taperoot/slot$slot") or die("Could not mkdir: $!") ; }
}

# An accumulator for the sequence of events that transpire during a run. This
# is what's used to check correctness of each test.

our @events ;

sub event(@)
{
  my $evt = [ @_ ] ;
  push @events,$evt ;
}

sub reset_events { @events = () ; }


# Construct a bigint

sub bi { Math::BigInt->new($_[0]) ; }

##
## Mock classes for the Scribe
##

# Mock::Taperscan acts as a hook around a real Taper::Scan::<algo> class. No
# point in mocking the full class when we can use the real thing.

package Mock::Taperscan ;
use Amanda::Device qw( :constants ) ;
use Amanda::MainLoop ;
use Amanda::Debug qw( debug ) ;

# Take advantage of perl's flexibility with some serious class hackery. First,
# claim we're using the real Taper::Scan::<algo> class as our parent. Then
# invoke the real Taper::Scan constructor. When the object comes back. tell
# it it's really a Mock::Taperscan. The net result is we can hook or override
# methods in the real Taper::Scan::<algo> class as needed but we don't have
# to mock when it's not necessary.

sub new {
  my $class = shift ;
  my %params = @_ ;

# If no scan algorithm is specified, force traditional.

  if (!exists $params{'algorithm'} || !defined $params{'algorithm'} ||
      $params{'algorithm'} eq '')
  { $params{'algorithm'} = 'traditional' ; }
  my $algo = $params{'algorithm'} ;

# Set up the real Taper::Scan::<algo> class as our parent.

  eval "use parent \"Amanda::Taper::Scan::$algo\"" ;

# Trickery. Create an honest Taper::Scan::$algo object, then tell it it's a
# Mock::Taperscan object. Because of the 'use parent' above, the object will
# think it's a Mock::Taperscan with the Taper::Scan::$algo object as parent.

  my $self = "Amanda::Taper::Scan"->new(@_) ;
  bless $self,$class ;
  my $name = Scalar::Util::blessed($self) ;
  debug("Created a $name $self") ;
  debug("    my ancestors are @Mock::Taperscan::ISA") ;

# If we've been given predefined slots, set the property.

  if (exists $params{'slots'}) { $self->{'slots'} = $params{'slots'} ; }

# Wedge in an extra device property to disable LEOM support, if requested

  my $chg =  $self->{'changer'} ;
  if ($params{'disable_leom'})
  { $chg->{'config'}->{'device_properties'}->{'leom'}->{'values'} = [ 0 ] ; }
  else
  { $chg->{'config'}->{'device_properties'}->{'leom'}->{'values'} = [ 1 ] ; }

  return $self ;
}


sub quit
{
  my $self = shift ;
  $self->SUPER::quit() ;
}

# Hook scan so we can generate some events. When the scan starts, we want
# the 'scan' event. We also hook the result_cb to create the scan-finished
# event. Once we've created our events, invoke the real method, SUPER::scan or
# orig_result_cb as appropriate.

sub scan
{
  my $self = shift ;
  my %params = @_ ;
  my $orig_result_cb = $params{'result_cb'} ;

  my $hook_result_cb = sub
  { my ($error,$reservation,$volume_label,$access_mode,$is_new) = @_ ;
    my $slot = $reservation->{'this_slot'} ; 

    $orig_result_cb->(@_) ;

    my $strtmp = (defined $slot)?$slot:'none' ;
    main::event("scan-finished",main::undef_or_str($error),"slot: $strtmp") ;
  } ;

  main::event("scan") ;

  $params{'result_cb'} = $hook_result_cb ;
  $self->SUPER::scan(%params) ;

  return ;
}


# A mock Feedback class. We need this because a) the Feedback class defined in
# Taper::Scribe is just a bunch of method stubs, and b) we'll use these
# methods to give feedback appropriate to the test and to record events.

package Mock::Feedback ;
use Amanda::Taper::Scribe ;
use parent -norequire, qw( Amanda::Taper::Scribe::Feedback ) ;
use Test::More ;
use Data::Dumper ;
use Installcheck::Config ;
use Amanda::Debug qw( debug ) ;

sub new {
    my $class = shift ;
    my @rq_answers = @_ ;
    return bless {
	rq_answers => [ @rq_answers ],
    }, $class ;
}

sub request_volume_permission {
    my $self = shift ;
    my %params = @_ ;
    my $answer = shift @{$self->{'rq_answers'}} ;
    main::event("request_volume_permission", "answer:", $answer) ;

    $params{'perm_cb'}->(%{$answer}) ;
}

sub scribe_ready {
    my $self = shift ;
    my %params = @_ ;

    main::event("scribe_ready") ;
}

sub scribe_notif_new_tape {
    my $self = shift ;
    my %params = @_ ;

    main::event("scribe_notif_new_tape",
	main::undef_or_str($params{'error'}), $params{'volume_label'}) ;
}

sub scribe_notif_part_done {
    my $self = shift ;
    my %params = @_ ;

    # this omits $duration, as it's not constant
    main::event("scribe_notif_part_done",
	$params{'partnum'}, $params{'fileno'},
	$params{'successful'}, $params{'size'}) ;
}

sub scribe_notif_tape_done {
    my $self = shift ;
    my %params = @_ ;

    main::event("scribe_notif_tape_done",
	$params{'volume_label'}, $params{'num_files'},
	$params{'size'}) ;
    $params{'finished_cb'}->() ;
}

sub scribe_notif_log_info
{ my $self = shift ;
  my %params = @_ ;

  if ((scalar keys %params) < 1)
  { debug("    scribe_notif_log_info invoked with no keys!") ; }
  else
  { foreach my $key (keys %params)
    { my $val = $params{$key} ;
      my $msgStr = sprintf("   scribe_notif_log_info: key '%s' value '%s'",
      			   $key,$val) ;
      debug("$msgStr") ; } }

  return ;
}


##
## test DevHandling
##

package main ;

my $scribe ;

# utility function to stringify changer errors (earlier perls' Test::More's
# fail to do this automatically)

sub undef_or_str { (defined $_[0])?"".$_[0]:undef ; }


# sub run_devh($nruns,$taperscan,$feedback)

# Test interaction between DevHandling, Taper::Scan, and Changer.

sub run_devh {
    my ($nruns, $taperscan, $feedback) = @_ ;
    my $devh ;
    reset_events() ;

    reset_taperoot($nruns) ;

# The only reason we're creating a Scribe here is because it's the easiest
# way to create a Taper::Scribe::DevHandling object. Otherwise we'd have to
# specify the package is defined in Scribe.pm, instead of Scribe/DevHandling.pm

    $main::scribe = Amanda::Taper::Scribe->new(
	taperscan => $taperscan,
	feedback => $feedback) ;
    $devh = $main::scribe->{'devhandling'} ;

# Define a set of steps. We're not using the define_steps pattern because
# there's no top-level callback.

    my ($start, $get_volume, $got_volume, $quit) ;

# start will kick off the scan that initialises inventory in the changer, then
# queue up get_volume for execution in the next MainLoop iteration. (This
# gives start() a little time to get going.)

    $start = make_cb(start => sub {
	event("start") ;
	$devh->start() ;
	$get_volume->() ;
    }) ;

# get_volume does exactly that: asks DevHandling for a volume. There's a loop
# here: while (runcount <= $nruns) { get_volume ; got_volume } quit

    my $runcount = 0 ;
    $get_volume = make_cb(get_volume => sub {
	if (++$runcount > $nruns) {
	    $quit->() ;
	    return ;
	}
	event("get_volume") ;
	$devh->get_volume(volume_cb => $got_volume) ;
    }) ;

# Check for success: Did we get the expected result? Queue up an event to
# record the result. Quit on error. Release the reservation if all went well,
# which will create a release event.

    $got_volume = make_cb(got_volume => sub {
	my ($scan_error, $config_denial_message, $error_denial_message,
	    $reservation, $volume_label, $access_mode) = @_ ;

	event("got_volume",
	    undef_or_str($scan_error),
	    $config_denial_message, $error_denial_message,
	    $reservation?("slot: ".$reservation->{'this_slot'}):undef) ;

	if ($scan_error or $config_denial_message or $error_denial_message) {
	    $quit->() ;
	    return ;
	}

	my $finished_cb =
	  sub { my ($error) = @_ ;
		event("release", $error) ;
		if ($error) {
		    $quit->() ;
		} else {
		    $get_volume->() ;
		}
	      } ;
	if (defined $reservation)
	{ $reservation->release(finished_cb => $finished_cb) ; }
	else
	{ $quit->() ; }
    }) ;

# We're done, create a quit event and shut down the main loop.

    $quit = make_cb(quit => sub {
	event("quit") ;
	Amanda::MainLoop::quit() ;
    }) ;

# We've defined all the steps, queue up start() and fire up the main loop.

    $start->() ;
    Amanda::MainLoop::run() ;
}


reset_taperoot(1) ;

# Create the objects we need: Tapelist, Storage, Mock::Taperscan and
# Mock::Feedback at the top level. We'll get a Changer::disk as a side effect
# of creating the Storage object.

my ($tapelist, $message) = Amanda::Tapelist->new("$tapelistFile") ;
if (!defined $tapelist)
{ die("Tapelist creation message is '$message'") ; }

my $changer_name = "chg-disk:$taperoot" ;
my $storage = Amanda::Storage->new(changer_name => $changer_name,
                                   tapelist => $tapelist) ;
if ($storage->isa('Amanda::Changer::Error'))
{ die("Error creating Storage: $storage") ; }

my $chg = $storage->{'chg'} ;
if ($chg->isa("Amanda::Changer::Error"))
{ die("Error creating changer chg-disk: $chg\n") ; }

debug("Successfully created Tapelist, Storage, and Changer.") ;


# For each of the tests that follow, we'll create new Mock::Taperscan and
# Mock::Feedback objects tailored to the test at hand.

my $taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist) ;
my $feedback = Mock::Feedback->new({allow => 1},{allow => 1},{allow => 1}) ;

# Interactions between scan and get_volume when volume permission is granted.

run_devh(3, $taperscan, $feedback) ;
$taperscan->quit() ;

is_deeply([ @events ], [
      [ 'start' ],
      # scan starts *before* get_volume
      [ 'scan' ],

      [ 'get_volume' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 }, ],
      [ 'scan-finished', undef, "slot: 1" ],
      [ 'got_volume', undef, undef, undef, "slot: 1" ],
      [ 'release', undef ],

      [ 'get_volume' ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scan-finished', undef, "slot: 2" ],
      [ 'got_volume', undef, undef, undef, "slot: 2" ],
      [ 'release', undef ],

      [ 'get_volume' ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scan-finished', undef, "slot: 3" ],
      [ 'got_volume', undef, undef, undef, "slot: 3" ],
      [ 'release', undef ],

      [ 'quit' ],
    ], "correct event sequence for basic run of DevHandling")
    or diag(Dumper([@events])) ;


# Test what happens when volume permission is denied.

$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
				  storage => $storage,
				  tapelist => $tapelist) ;
$feedback = Mock::Feedback->new({cause => 'config', message => 'no-can-do'}) ;

run_devh(1, $taperscan,$feedback) ;
$taperscan->quit() ;

is_deeply([ @events ], [
      [ 'start' ],
      [ 'scan' ],

      [ 'get_volume' ],
      [ 'request_volume_permission', 'answer:',
        { cause => 'config', message => 'no-can-do' } ],
      [ 'scan-finished', undef, "slot: 1" ],
      [ 'got_volume', undef, 'no-can-do', undef, undef ],

      [ 'quit' ],
    ], "correct event sequence for a run without permission")
    or diag(Dumper([@events])) ;


# To force a changer error, turn off autolabel. Otherwise the scan algorithm
# will find some unlabelled slot and declare it acceptable.

my $autolabel_save = $chg->{'autolabel'} ;
$chg->{'autolabel'} = undef ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist,
				     slots => [ { slot => 'bogus' } ]) ;
$feedback = Mock::Feedback->new({allow => 1}) ;
run_devh(1, $taperscan, $feedback) ;
$taperscan->quit() ;

is_deeply([ @events ], [
      [ 'start' ],
      [ 'scan' ],

      [ 'get_volume' ],
      [ 'request_volume_permission', 'answer:', { allow => 1} ],
      [ 'scan-finished', "Slot bogus not found", "slot: none" ],
      [ 'got_volume', 'Slot bogus not found', undef, undef, undef ],

      [ 'quit' ],
    ], "correct event sequence for a run with a changer error")
    or diag(Dumper([@events])) ;


$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist,
				     slots => [ { slot => 'bogus' } ]) ;
$feedback = Mock::Feedback->new({ cause => 'config',
				  message => 'not this time' }) ;
run_devh(1, $taperscan, $feedback) ;
$taperscan->quit() ;

is_deeply([ @events ], [
      [ 'start' ],
      [ 'scan' ],

      [ 'get_volume' ],
      [ 'request_volume_permission', 'answer:',
        {cause => 'config', message =>'not this time'} ],
      [ 'scan-finished', "Slot bogus not found", "slot: none" ],
      [ 'got_volume', 'Slot bogus not found', 'not this time', undef, undef ],

      [ 'quit' ],
    ], "correct event sequence for a run with no permission"
       ." AND a changer config denial")
    or diag(Dumper([@events])) ;


$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist,
				     slots => [ { slot => 'bogus' } ]) ;
$feedback = Mock::Feedback->new({ cause => 'error',
				  message => 'frobnicator exploded!' }) ;
run_devh(1, $taperscan, $feedback) ;
$taperscan->quit() ;

is_deeply([ @events ], [
      [ 'start' ],
      [ 'scan' ],

      [ 'get_volume' ],
      [ 'request_volume_permission', 'answer:',
        {cause => 'error', message => "frobnicator exploded!"} ],
      [ 'scan-finished', "Slot bogus not found", "slot: none" ],
      [ 'got_volume', 'Slot bogus not found', undef,
        "frobnicator exploded!", undef ],

      [ 'quit' ],
    ], "correct event sequence for a run with no permission"
       ." AND a changer error")
    or diag(Dumper([@events])) ;


##
## test Scribe
##

sub run_scribe_xfer_async {
    my ($data_length, $scribe, %params) = @_ ;
    my $xfer ;

    my $finished_cb = $params{'finished_cb'} ;
    my $steps = define_steps
	cb_ref => \$finished_cb ;

    step start_scribe => sub {
	if ($params{'start_scribe'}) {
	    $scribe->start(%{ $params{'start_scribe'} },
			finished_cb => $steps->{'get_xdt'}) ;
	} else {
	    $steps->{'get_xdt'}->() ;
	}
    } ;

    step get_xdt => sub {
	my ($err) = @_ ;
	die $err if $err ;

	# set up a transfer
	my $xdt = $scribe->get_xfer_dest(
	    allow_split => 1,
	    max_memory => 1024 * 64,
	    part_size =>
	      (defined $params{'part_size'})?$params{'part_size'}:(1024*128),
            part_cache_type => $params{'part_cache_type'} || 'memory',
	    disk_cache_dirname => undef) ;

        die "$err" if $err ;

	my $hdr = Amanda::Header->new() ;
	$hdr->{type} = $Amanda::Header::F_DUMPFILE ;
	$hdr->{datestamp} = "20010203040506" ;
	$hdr->{dumplevel} = 0 ;
	$hdr->{compressed} = 1 ;
	$hdr->{name} = "localhost" ;
	$hdr->{disk} = "/home" ;
	$hdr->{program} = "INSTALLCHECK" ;

        $xfer = Amanda::Xfer->new([
            Amanda::Xfer::Source::Random->new($data_length, 0x5EED5),
            $xdt,
        ]) ;

        $xfer->start(sub {
            $scribe->handle_xmsg(@_) ;
        }) ;

        $scribe->start_dump(
	    xfer => $xfer,
            dump_header => $hdr,
            dump_cb => $steps->{'dump_cb'}) ;
    } ;

    step dump_cb => sub {
	my %params = @_ ;

	main::event("dump_cb",
	    $params{'result'},
	    [ map { "$_" } @{$params{'device_errors'}} ],
	    $params{'config_denial_message'},
	    $params{'size'}) ;

	$finished_cb->() ;
    } ;
}

sub run_scribe_xfer {
    my ($data_length, $scribe, %params) = @_ ;
    $params{'finished_cb'} = \&Amanda::MainLoop::quit ;
    run_scribe_xfer_async($data_length, $scribe, %params) ;
    Amanda::MainLoop::run() ;
}


# We can't invoke Taper::Scan->quit until after Taper::Scribe->quit releases
# the reservation held in the scribe. That means doing it in finished_cb.

sub quit_scribe
{
  my ($scribe) = @_ ;
  my $taperscan = $scribe->{'taperscan'} ;

  my $finished_cb = make_cb(
      finished_cb => sub
      { my ($error) = @_ ;
	die "$error" if $error ;
	$taperscan->quit() ;
	Amanda::MainLoop::quit() ;
      } ) ;

  $scribe->quit(finished_cb => $finished_cb) ;

  Amanda::MainLoop::run() ;
}


# Restore autolabel for the Scribe tests.

$chg->{'autolabel'} = $autolabel_save ;


# write less than a tape full, without LEOM

reset_taperoot(1) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist,
				     disable_leom => 1) ;
$feedback = Mock::Feedback->new({allow => 1}) ;

$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer(1024*200,$main::scribe,
	    part_size => 96*1024,
	    start_scribe => { write_timestamp => "20010203040506" }) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-001' ],
      [ 'scribe_ready' ],
      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(98304) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(98304) ],
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(8192) ],
      [ 'dump_cb', 'DONE', [], undef, bi(204800) ],
    ], "correct event sequence for a multipart scribe of less than"
       ." a whole volume, without LEOM")
    or diag(Dumper([@events])) ;

# pick up where we left off, writing just a tiny bit more, and then quit

reset_events() ;
run_scribe_xfer(1024*30,$main::scribe) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scribe_ready' ],
      [ 'scribe_notif_part_done', bi(1), bi(4), 1, bi(30720) ],
      [ 'dump_cb', 'DONE', [], undef, bi(30720) ],
      [ 'scribe_notif_tape_done', 'FAKE-001', bi(4), bi(235520) ],
    ], "correct event sequence for a subsequent single-part scribe,"
       ." still on the same volume")
    or diag(Dumper([@events])) ;


# write less than a tape full, *with* LEOM (should look the same as above)

reset_taperoot(1) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist) ;
$feedback = Mock::Feedback->new({allow => 1}) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer(1024*200, $main::scribe,
	    part_size => 96*1024,
	    start_scribe => { write_timestamp => "20010203040506" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-002' ],
      [ 'scribe_ready' ],
      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(98304) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(98304) ],
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(8192) ],
      [ 'dump_cb', 'DONE', [], undef, bi(204800) ],
      [ 'scribe_notif_tape_done', 'FAKE-002', bi(3), bi(204800) ],
    ], "correct event sequence for a multipart scribe of less than"
       ." a whole volume, with LEOM")
    or diag(Dumper([@events])) ;


# start over again and try a multivolume write
#
# NOTE: the part size and volume size are such that the VFS driver produces
# ENOSPC while writing the fourth file header, rather than while writing
# data.  This is a much less common error path, so it's good to test it.

reset_taperoot(2) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist,
				     disable_leom => 1) ;
$feedback = Mock::Feedback->new({ allow => 1 }, { allow => 1}) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer($volume_length + $volume_length / 4, $main::scribe,
	    start_scribe => { write_timestamp => "20010203040506" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-003' ],
      [ 'scribe_ready' ],

      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(4), bi(0), 0, bi(0) ],

      [ 'scribe_notif_tape_done', 'FAKE-003', bi(3), bi(393216) ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scan-finished', undef, 'slot: 2' ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-004' ],

      [ 'scribe_notif_part_done', bi(4), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(5), bi(2), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(6), bi(3), 1, bi(0) ],

      [ 'dump_cb', 'DONE', [], undef, bi(655360) ],
      [ 'scribe_notif_tape_done', 'FAKE-004', bi(3), bi(262144) ],
    ], "correct event sequence for a multipart scribe of more than"
       ." a whole volume, without LEOM")
    or print (Dumper([@events])) ;


# same test, but with LEOM support

reset_taperoot(2) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
                                     storage => $storage,
                                     tapelist => $tapelist) ;
$feedback = Mock::Feedback->new({ allow => 1 }, { allow => 1}) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer(1024*520, $main::scribe,
	    start_scribe => { write_timestamp => "20010203040506" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-005' ],
      [ 'scribe_ready' ],

      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(131072) ],
      # LEOM comes earlier than PEOM did
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(32768) ],

      [ 'scribe_notif_tape_done', 'FAKE-005', bi(3), bi(294912) ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scan-finished', undef, 'slot: 2' ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-006' ],

      [ 'scribe_notif_part_done', bi(4), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(5), bi(2), 1, bi(106496) ],

      [ 'dump_cb', 'DONE', [], undef, bi(532480) ],
      [ 'scribe_notif_tape_done', 'FAKE-006', bi(2), bi(237568) ],
    ], "correct event sequence for a multipart scribe of more than"
       ." a whole volume, with LEOM")
    or print (Dumper([@events])) ;


# now a multivolume write where the second volume gives a changer error

reset_taperoot(1) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
			      storage => $storage,
			      tapelist => $tapelist,
			      slots => [ { slot => '1'}, {slot => 'bogus'} ],
			      disable_leom => 1) ;
$feedback = Mock::Feedback->new({ allow => 1 }, { allow => 1}) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;
reset_events() ;
run_scribe_xfer($volume_length + $volume_length / 4, $main::scribe,
	    start_scribe => { write_timestamp => "20010203040507" }) ;
quit_scribe($main::scribe) ;

my $experr = 'Slot bogus not found' ;
is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-007' ],
      [ 'scribe_ready' ],

      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(4), bi(0), 0, bi(0) ],

      [ 'scribe_notif_tape_done', 'FAKE-007', bi(3), bi(393216) ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', $experr, undef ],
      [ 'scan-finished', $experr, 'slot: none' ],

      [ 'dump_cb', 'PARTIAL', [$experr], undef, bi(393216) ],
      # (no scribe_notif_tape_done)
    ], "correct event sequence for a multivolume scribe with no second vol,"
       ." without LEOM")
    or print (Dumper([@events])) ;

# repeat with LEOM

reset_taperoot(1) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
			    storage => $storage,
			    tapelist => $tapelist,
			    slots => [ { slot => '1'}, {slot => 'bogus'} ] ) ;
$feedback = Mock::Feedback->new({ allow => 1 }, { allow => 1}) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer($volume_length + $volume_length / 4, $main::scribe,
	    start_scribe => { write_timestamp => "20010203040507" }) ;
quit_scribe($main::scribe) ;

$experr = 'Slot bogus not found' ;
is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-008' ],
      [ 'scribe_ready' ],

      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(131072) ],
      # LEOM comes long before PEOM
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(32768) ],

      [ 'scribe_notif_tape_done', 'FAKE-008', bi(3), bi(294912) ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', $experr, undef ],
      [ 'scan-finished', $experr, 'slot: none' ],

      [ 'dump_cb', 'PARTIAL', [$experr], undef, bi(294912) ],
      # (no scribe_notif_tape_done)
    ], "correct event sequence for a multivolume scribe with no second vol,"
       ." with LEOM")
    or print (Dumper([@events])) ;


# now a multivolume write where the second volume does not have permission

reset_taperoot(2) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
			    storage => $storage,
			    tapelist => $tapelist) ;
$feedback = Mock::Feedback->new({ allow => 1 },
				{ cause => 'config', message => 'sorry!' }) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;
reset_events() ;
run_scribe_xfer($volume_length + $volume_length / 4, $main::scribe,
	    start_scribe => { write_timestamp => "20010203040507" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-009' ],
      [ 'scribe_ready' ],

      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(2), bi(2), 1, bi(131072) ],
      [ 'scribe_notif_part_done', bi(3), bi(3), 1, bi(32768) ],

      [ 'scribe_notif_tape_done', 'FAKE-009', bi(3), bi(294912) ],
      [ 'scan' ],
      [ 'request_volume_permission', 'answer:',
        { cause => 'config', message => "sorry!" } ],
      [ 'scan-finished', undef, 'slot: 2' ],

      [ 'dump_cb', 'PARTIAL', [], "sorry!", bi(294912) ],
    ], "correct event sequence for a multivolume scribe with next vol denied")
    or print (Dumper([@events])) ;


# a non-splitting xfer on a single volume

reset_taperoot(2) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
			    storage => $storage,
			    tapelist => $tapelist,
			    disable_leom => 1) ;
$feedback = Mock::Feedback->new({ allow => 1 }) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;

reset_events() ;
run_scribe_xfer(1024*300, $main::scribe,
		part_size => 0, part_cache_type => 'none',
		start_scribe => { write_timestamp => "20010203040506" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-010' ],
      [ 'scribe_ready' ],
      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(307200) ],
      [ 'dump_cb', 'DONE', [], undef, bi(307200) ],
      [ 'scribe_notif_tape_done', 'FAKE-010', bi(1), bi(307200) ],
    ], "correct event sequence for a non-splitting scribe of less than"
       ." a whole volume, without LEOM")
    or diag(Dumper([@events])) ;


reset_taperoot(2) ;
$taperscan = Mock::Taperscan->new(algorithm => 'oldest',
			    storage => $storage,
			    tapelist => $tapelist) ;
$feedback = Mock::Feedback->new({ allow => 1 }) ;
$main::scribe = Amanda::Taper::Scribe->new(taperscan => $taperscan,
					   feedback => $feedback) ;
reset_events() ;
run_scribe_xfer(1024*300, $main::scribe,
		part_size => 0, part_cache_type => 'none',
		start_scribe => { write_timestamp => "20010203040506" }) ;
quit_scribe($main::scribe) ;

is_deeply([ @events ], [
      [ 'scan' ],
      [ 'scan-finished', undef, 'slot: 1' ],
      [ 'request_volume_permission', 'answer:', { allow => 1 } ],
      [ 'scribe_notif_new_tape', undef, 'FAKE-011' ],
      [ 'scribe_ready' ],
      [ 'scribe_notif_part_done', bi(1), bi(1), 1, bi(307200) ],
      [ 'dump_cb', 'DONE', [], undef, bi(307200) ],
      [ 'scribe_notif_tape_done', 'FAKE-011', bi(1), bi(307200) ],
    ], "correct event sequence for a non-splitting scribe of less than"
       ." a whole volume, with LEOM")
    or diag(Dumper([@events])) ;

# DirectTCP support is tested through the taper installcheck

# test get_splitting_args_from_config thoroughly
my $maxint64 = Math::BigInt->new("9223372036854775808") ;

is_deeply(
    { get_splitting_args_from_config(
    ) },
    { allow_split => 0 },
    "default is only allow_split set to 0") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 0,
	dle_split_diskbuffer => $Installcheck::TMP,
	dle_fallback_splitsize => 100,
    ) },
    { allow_split => 0, part_size => 0, part_cache_type => 'none' },
    "tape_splitsize = 0 indicates no splitting") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_allow_split => 0,
	part_size => 100,
	part_cache_dir => "/tmp",
    ) },
    { allow_split => 0 },
    "default if dle_allow_split is false, no splitting") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 200,
	dle_fallback_splitsize => 150,
    ) },
    { allow_split => 1, part_cache_type => 'memory',
      part_size => 200, part_cache_max_size => 150 },
    "when cache_inform is available, tape_splitsize is used, not fallback") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 200,
    ) },
    { allow_split => 1, part_size => 200,
      part_cache_type => 'memory', part_cache_max_size => 1024*1024*10, },
    "no split_diskbuffer and no fallback_splitsize, fall back to default (10M)") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 200,
	dle_split_diskbuffer => "$Installcheck::TMP/does!not!exist!",
	dle_fallback_splitsize => 150,
    ) },
    { allow_split => 1, part_size => 200,
      part_cache_type => 'memory', part_cache_max_size => 150 },
    "invalid split_diskbuffer => fall back (silently)") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 200,
	dle_split_diskbuffer => "$Installcheck::TMP/does!not!exist!",
    ) },
    { allow_split => 1,
      part_size => 200, part_cache_type => 'memory',
      part_cache_max_size => 1024*1024*10 },
    ".. even to the default fallback (10M)") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => $maxint64,
	dle_split_diskbuffer => "$Installcheck::TMP",
	dle_fallback_splitsize => 250,
    ) },
    { allow_split => 1,
      part_size => $maxint64, part_cache_type => 'memory',
      part_cache_max_size => 250,
      warning => "falling back to memory buffer for splitting: " .
		 "insufficient space in disk cache directory" },
    "not enough space in split_diskbuffer => fall back (with warning)") ;

is_deeply(
    { get_splitting_args_from_config(
	can_cache_inform => 0,
	dle_tape_splitsize => 200,
	dle_split_diskbuffer => "$Installcheck::TMP",
	dle_fallback_splitsize => 150,
    ) },
    { allow_split => 1, part_size => 200,
    	    part_cache_type => 'disk',
	    part_cache_dir => "$Installcheck::TMP" },
    "if split_diskbuffer exists and splitsize is nonzero, use it") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_tape_splitsize => 0,
	dle_split_diskbuffer => "$Installcheck::TMP",
	dle_fallback_splitsize => 250,
    ) },
    { allow_split => 0, part_size => 0, part_cache_type => 'none' },
    ".. but if splitsize is zero, no splitting") ;

is_deeply(
    { get_splitting_args_from_config(
	dle_split_diskbuffer => "$Installcheck::TMP",
	dle_fallback_splitsize => 250,
    ) },
    { allow_split => 0, part_size => 0, part_cache_type => 'none' },
    ".. and if splitsize is missing, no splitting") ;

is_deeply(
    { get_splitting_args_from_config(
	part_size => 300,
	part_cache_type => 'none',
    ) },
    { allow_split => 1, part_size => 300, part_cache_type => 'none' },
    "part_* parameters handled correctly when missing") ;

is_deeply(
    { get_splitting_args_from_config(
	part_size => 300,
	part_cache_type => 'disk',
	part_cache_dir => $Installcheck::TMP,
	part_cache_max_size => 250,
    ) },
    { allow_split => 1, part_size => 300, part_cache_type => 'disk',
      part_cache_dir => $Installcheck::TMP, part_cache_max_size => 250, },
    "part_* parameters handled correctly when specified") ;

is_deeply(
    { get_splitting_args_from_config(
	part_size => 300,
	part_cache_type => 'disk',
	part_cache_dir => "$Installcheck::TMP/does!not!exist!",
	part_cache_max_size => 250,
    ) },
    { allow_split => 1, part_size => 300, part_cache_type => 'none',
      part_cache_max_size => 250,
      warning => "part-cache-dir '$Installcheck::TMP/does!not!exist!"
	       . " does not exist; using part cache type 'none'"},
    "part_* parameters handled correctly when specified") ;


$storage->quit() ;
$chg->quit() ;
rmtree($taperoot) ;

