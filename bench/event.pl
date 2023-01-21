#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use Linux::Event;
use Socket;
use AnyEvent;
use Time::HiRes 'time';

my $nr = shift || 1000;
my $num = shift || $nr * 0.01;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

my $c = time;

my @conn; @conn = map {
	socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
	my $timer = Linux::Event::add_timer(3.6, 0, sub { die } );
	Linux::Event::add_fh($in, 'in', sub {
		my ($stream, $buf) = @_;
		++$count;
		sysread $in, my $buf, 1;
		syswrite $conn[rand @conn], $buf, 1;
		Linux::Event::set_timer($timer, 3.6, 0);
	});
	$out;
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $num) {
	syswrite $conn[rand @conn], $_, 1;
}

my $i = time;

$SIG{ALRM} = sub {
	$i = (time - $i) / $count * 1e6;
	printf "request %.2f us\n", $i;
	exit;
};
alarm 1;

1 while Linux::Event::one_shot($num);
