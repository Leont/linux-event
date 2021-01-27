#! /usr/bin/env perl

# ugly code, don't look at it

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Fcntl qw/F_SETOWN F_SETSIG F_GETFL F_SETFL O_NONBLOCK O_ASYNC/;
use IPC::Signal 'sig_num';
use Signal::Unsafe;
use POSIX::RT::Timer;
use Signal::Mask;
use Socket;
use Time::HiRes 'time';
use POSIX qw/sigsuspend SIGUSR1 SIGUSR2 SIGALRM SIGPOLL/;

my $nr = $ARGV[0] || 1000;

$| = 1;

print "name $ENV{PERL_ANYEVENT_MODEL}\n";
print "sockets ", $nr * 2, "\n";

my $count;

my $c = time;

$Signal::Mask{IO} = 1;
$Signal::Mask{USR2} = 1;
$SIG{POLL} = sub { die "HERE" };
my %handle_for;
my %timer_for;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, 0 or die "Can't open socketpair: $!";
	my $timer = POSIX::RT::Timer->new(clock => 'monotonic', value => 3600, signal => SIGUSR1);

	fcntl $in, F_SETOWN, 0+$$ or die;
	fcntl $in, F_SETSIG, 0+sig_num('USR2') or die "Couldn't SETSIG: $!";
	my $flags = fcntl $in, F_GETFL, 0 or die;
	$flags |= O_NONBLOCK|O_ASYNC;
	fcntl $in, F_SETFL, $flags or die;
	$handle_for{fileno $in} = $in;
	$timer_for{fileno $in} = $timer;

	$out;
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $ARGV[1] || $nr * 0.01) {
	syswrite $conn[rand @conn], $_, 1;
}

$SIG{POLL} = sub { die "HERE" };
my $mask = POSIX::SigSet->new();

my $timeout = POSIX::RT::Timer->new(clock => 'monotonic', signal => SIGALRM, value => 1);

$Signal::Unsafe{USR2} = sub {
	my ($signo, $info, undef) = @_;
	++$count;
	my $fd = $info->{fd};
	my $in = $handle_for{$fd};
	sysread $in, my $buf, 1;
	syswrite $conn[rand @conn], $buf, 1;
	$timer_for{$fd}->set_timeout(3600);
};

my $continue = 1;
my $i = time;

$SIG{ALRM} = sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	$continue = 0;
};
sigsuspend($mask) while $continue;
