#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Linux::Epoll;
use Linux::FD 'timerfd';
use Socket;
use Time::HiRes 'time';

my $nr = shift || 1000;
my $num = shift || $nr * 0.01;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

my $loop = Linux::Epoll->new;

my $c = time;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
	my $timer = timerfd('monotonic');
	$timer->set_timeout(3600);
	$loop->add($timer, 'in', sub { die });
	my $reader = $loop->add($in, 'in', sub {
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

my $timeout = Linux::FD::Timer->new('monotonic');
$timeout->set_timeout(1);

my $i = time;

$loop->add($timeout, 'in', sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	exit;
});

1 while $loop->wait($num);
