#! perl

use strict;
use warnings;
use Test::More tests => 21;
use Linux::Event;

use POSIX qw/raise SIGALRM/;
use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use Scalar::Util qw/weaken/;
use Time::HiRes qw/alarm/;

is Linux::Event::maybe_shot(1), 0, 'No events to wait for';

socketpair my $in, my $out, AF_UNIX, SOCK_STREAM, PF_UNSPEC or die 'Failed';
$_->blocking(0) for $in, $out;

my $subnum = 1;
my $sub = sub {
	my $event = shift;
	is $subnum, 1, 'Anonymous closure works';
	ok $event->{in}, '$event->{in} is true' or diag explain $event;
	is sysread($in, my $buffer, 3), 3, 'Read 3 bytes';
};
my $addr = Linux::Event::add_fh($in, 'in', $sub);
ok $addr, 'Can add to the set';
weaken $sub;
ok defined $sub, '$sub is still defined';

syswrite $out, 'foo', 3;
is Linux::Event::maybe_shot(1), 1, 'Finally an event';
is Linux::Event::maybe_shot(1), 0, 'No more events to wait for';

Linux::Event::add_signal('ALRM', sub {
	$subnum = 3;
	syswrite $out, 'bar', 3;
});
raise(SIGALRM);

my $sub2 = sub {
	my $event = shift;
	is $subnum, 3, 'New handler works too';
	$subnum = 4;
	ok $event->{in}, '$event->{in} is true';
	is sysread($in, my $buffer, 3), 3, 'Got 3 more bytes';
};

ok(Linux::Event::modify_fh($in, $addr, [ qw/in prio/ ], $sub2), 'Can modify the set');
weaken $sub2;
ok defined $sub2, '$sub2 is still defined';
is Linux::Event::maybe_shot(2), 1, 'Interrupted event';
is $subnum, 3, 'subnum is 3';
is Linux::Event::maybe_shot(1), 1, 'Yet another event';
is $subnum, 4, 'subnum is 4';

Linux::Event::remove_fh($in, $addr);
ok 1, 'Can delete from set';
ok !defined $sub2, '$sub2 is no longer defined';

syswrite $out, 'baz', 3;
is Linux::Event::maybe_shot(1), 0, 'No events on empty epoll';

{
	my $sub3 = sub { $subnum };
	Linux::Event::add_fh($out, 'out', $sub3);
	weaken $sub3;

	undef $out;
	is $sub3, undef, '$sub3 is no longer defined';
}

done_testing;

