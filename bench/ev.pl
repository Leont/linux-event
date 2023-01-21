#! /usr/bin/env perl

# ulimit -n 500000
# $0 <fds> <active>

use strict;
use EV;
use Socket;
use Time::HiRes 'time';

my $nr = $ARGV[0] || 1000;

$| = 1;

print "sockets ", $nr * 2, "\n";

my $count = 1;

my $c = time;

my @conn; @conn = map {
   socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die "$!";
   my $self; $self = {
      w => $out,
      rw => EV::io($in, EV::READ, sub {
               ++$count;
               sysread $in, my $buf, 1;
               syswrite $conn[rand @conn]{w}, $buf, 1;
               $self->{to} = EV::timer(3.6, 0, sub { die });
            }),
      to => EV::timer(3.600, 0, sub { die }),
   };
   $self
} 1 .. $nr;

$c = (time - $c) / $nr * 1e6;

printf "create %.2f us\n", $c;

for (1 .. $ARGV[1] || $nr * 0.01) {
   syswrite $conn[rand @conn]{w}, $_, 1;
}

my $i = time;

my $stop = EV::timer(1, 0, sub {
   $i = (time - $i) / $count * 1e6;
   printf "request %.2f us\n", $i;
   exit;
});

EV::run;
