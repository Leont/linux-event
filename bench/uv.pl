#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use UV;
use UV::Poll;
use UV::Timer;
use Socket;
use AnyEvent;
use Time::HiRes 'time';

my $nr = $ARGV[0] || 1000;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

my $loop = UV::default_loop;

my $c = time;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
	my $timer = UV::Timer->new;
	$timer->start(3600, sub { die });
	my $handle = UV::Poll->new(fd => fileno $in);
	$handle->start(UV::Poll::UV_READABLE, sub {
		++$count;
		sysread $in, my $buf, 1;
		syswrite $conn[rand @conn][0], $buf, 1;
		$timer->again;
	});
	[ $out, $in, $timer, $handle ];
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $ARGV[1] || $nr * 0.01) {
	syswrite $conn[rand @conn][0], $_, 1;
}

my $i = time;

$SIG{ALRM} = sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	exit;
};
alarm 1;

$loop->run;
