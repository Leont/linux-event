#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Socket;
use IO::Async::Loop;
use IO::Async::OS;
use IO::Async::Stream;
use IO::Async::Signal;
use IO::Async::Timer::Countdown;
use Time::HiRes 'time';

my $nr = $ARGV[0] || 1000;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

my $loop = IO::Async::Loop->new;

printf "Loop = %s\n", ref $loop;

my $c = time;

my @conn; @conn = map {
	my ($in, $out) = IO::Async::OS->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
	my $timer = IO::Async::Timer::Countdown->new(delay => 3600, on_expire => sub { die });
	$loop->add($timer);
	my $stream = IO::Async::Stream->new(read_handle => $in, on_read => sub {
		my ($self, $bufref, $eof) = @_;
		++$count;
		my $index = int rand @conn;
		syswrite $conn[$index], $$bufref, 1 or die $index;
		$$bufref = '';
		$timer->reset;
	});
	$loop->add($stream);
	$out;
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $ARGV[1] || $nr * 0.01) {
	syswrite $conn[rand @conn], $_, 1;
}

my $i = time;

$SIG{ALRM} = sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	exit;
};
alarm 2;

$loop->run;
