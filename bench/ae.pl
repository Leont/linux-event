#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use EV;
use Socket;
use AnyEvent;
use Time::HiRes 'time';

my $nr = $ARGV[0] || 1000;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count;

printf "Loop = %s\n", AnyEvent::detect;

my $c = time;

my @conn; @conn = map {
   socketpair my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
   my $self; $self = {
      r => $a,
      w => $b,
      rw => AnyEvent->io (fh => $a, poll => "r", cb => sub {
               ++$count;
               sysread $a, my $buf, 1;
               syswrite $conn[rand @conn]{w}, $buf, 1;
               $self->{to} = AnyEvent->timer (after => 3600, cb => sub { die });
            }),
      to => AnyEvent->timer (after => 3600, cb => sub { die }),
   };
   $self
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $ARGV[1] || $nr * 0.01) {
   syswrite $conn[rand @conn]{w}, $_, 1;
}

my $i = time;

my $stop = AnyEvent->timer (after => 1, cb => sub {
   $i = (time - $i) / $count * 1e6;
   printf "request %.2f us\n", $i;
   exit;
});

AnyEvent->condvar->wait;
