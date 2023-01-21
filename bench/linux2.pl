#! /usr/bin/env perl

# ugly code, don't look at it

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Linux::Epoll;
use POSIX::RT::Timer;
use Signal::Mask;
use Socket;
use Time::HiRes 'time';
use POSIX qw/SIGUSR1 SIGUSR2/;

my $nr = shift || 1000;
my $num = shift || $nr * 0.01;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

my $loop = Linux::Epoll->new;

my $c = time;

$Signal::Mask{USR1} = 1;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
	my $timer = POSIX::RT::Timer->new(clock => 'monotonic', value => 3600, signal => SIGUSR1);
	my $reader = $loop->add($in, [ 'in' ], sub {
		++$count;
		sysread $in, my $buf, 1;
		syswrite $conn[rand @conn], $buf, 1;
		$timer->set_timeout(3600);
	});
	$out;
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $num) {
	syswrite $conn[rand @conn], $_, 1;
}

my $i = time;

my $timeout = POSIX::RT::Timer->new(clock => 'monotonic', signal => SIGUSR2, value => 1);
$SIG{USR2} = sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	exit;
};

my $mask = POSIX::SigSet->new();

1 while $loop->wait($num, undef, $mask);
