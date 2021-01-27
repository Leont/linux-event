#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Mojo::IOLoop::Stream;
use Socket;
use AnyEvent;
use Time::HiRes 'time';

my $nr = $ARGV[0] || 1000;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

printf "Loop = %s\n", ref Mojo::IOLoop->singleton->reactor;

my $c = time;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
	my $timer = Mojo::IOLoop->timer(3.6, sub { die } );
	my $handle = Mojo::IOLoop::Stream->new($in);
	$handle->on(read => sub {
		my ($stream, $buf) = @_;
		++$count;
		syswrite $conn[rand @conn][0], $buf, 1;
		Mojo::IOLoop->singleton->reactor->again($timer);
	});
	$handle->start;
	[ $out, $handle ];
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

Mojo::IOLoop->start;
