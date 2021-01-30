package Linux::Event;

use 5.010;
use strict;
use warnings;
use experimental 'smartmatch';

use Carp qw/croak/;
use Hash::Util::FieldHash qw/fieldhash id_2obj/;
use Linux::Epoll;
use Linux::FD qw/signalfd timerfd/;
use Linux::FD::Pid;
use List::Util qw/reduce/;
use List::MoreUtils qw/uniq/;
use Scalar::Util qw/refaddr weaken/;
use Signal::Mask;

use namespace::clean;

my $epoll = Linux::Epoll->new;

my $waitbuffer_size = 16;
my $any_child       = -1;
my $no_child        = 0;

fieldhash my %data_for_fh;

sub add_fh {
	my ($fh, $mode, $cb) = @_;
	weaken $fh;
	my $addr = refaddr($cb);
	my @mode = ref $mode ? sort @$mode : $mode;
	if (!exists $data_for_fh{$fh}) {
		$data_for_fh{$fh}{id}{$addr} = { mode => \@mode, callback => $cb };
		$data_for_fh{$fh}{mode} = \@mode;
		$epoll->add($fh, $mode, $cb);
	}
	else {
		$data_for_fh{$fh}{id}{$addr} = { mode => \@mode, callback => $cb };
		$data_for_fh{$fh}{mode} = [ uniq( map { @{ $_->{mode} } } values %{ $data_for_fh{$fh}{id} } ) ];
		$data_for_fh{$fh}{callback} //= sub {
			my $event = shift;
			for my $callback (values %{ $data_for_fh{$fh}{id} }) {
				$callback->{callback}->($event) if $event ~~ $callback->{mode};
			}
		};
		$epoll->modify($fh, $data_for_fh{$fh}{mode}, $data_for_fh{$fh}{callback});
	}
	return $addr;
}

sub remove_fh {
	my ($fh, $addr) = @_;
	return if not delete $data_for_fh{$fh}{id}{$addr};
	my @values = values %{ $data_for_fh{$fh}{id} };
	if (not @values) {
		$epoll->delete($fh);
		delete $data_for_fh{$fh};
	}
	elsif (@values == 1) {
		$data_for_fh{$fh}{mode} = $values[0]{mode};
		$epoll->modify($fh, $data_for_fh{$fh}{mode}, $values[0]{callback});
		delete $data_for_fh{$fh}{callback};
	}
	else {
		$data_for_fh{$fh}{mode} = [ uniq( map { @{ $_->{mode} } } @values ) ];
		$epoll->modify($fh, $data_for_fh{$fh}{mode}, $data_for_fh{$fh}{callback});
	}
	return 1;
}

my %data_for_timer;

sub add_timer {
	my ($after, $interval, $cb, $keepalive) = @_;
	$keepalive //= defined wantarray;

	my $timer = timerfd('monotonic');
	$timer->blocking(0);
	$timer->set_timeout($after, $interval);

	my $addr     = refaddr $timer;
	my $callback = sub {
		my $data = $data_for_timer{$addr};
		my $arg = $data->[0]->wait;
		if (defined $arg) {
			$cb->($arg);
			remove_timer($addr) if not $data->[2] and not $data->[3];
		}
	};
	$epoll->add($timer, 'in', $callback);
	$data_for_timer{$addr} = [ $timer, $after, $interval, $keepalive ];

	return $addr;
}

sub remove_timer {
	my $addr = shift;
	return if not exists $data_for_timer{$addr};
	my $data = delete $data_for_timer{$addr};
	$epoll->delete($data->[0]);
	return;
}

sub set_timer {
	my ($addr, $after, $interval) = @_;
	my $data  = $data_for_timer{$addr} or croak 'Can\'t find that timer';
	my $timer = $data->[0];
	my $ret   = $timer->set_timeout($after, $interval);
	@{$data}[ 1, 2 ] = ($after, $interval);
	return $ret;
}

my %data_for_signal;

sub add_signal {
	my ($signal, $cb) = @_;
	croak '$signal must be a name or a POSIX::SigSet object' if ref $signal and not $signal->isa('POSIX::SigSet');
	my $signalfd = signalfd($signal);
	$signalfd->blocking(0);
	my $callback = sub {
		my $arg = $data_for_signal{$signal}[0]->receive;
		$cb->($arg) if defined $arg;
	};
	$epoll->add($signalfd, 'in', $callback);
	$Signal::Mask{$signal} = 1;
	$data_for_signal{$signal} = [ $signalfd, $callback ];
	weaken $signalfd;
	return $signal;
}

sub remove_signal {
	my $signal = shift;
	return if not exists $data_for_signal{$signal};
	my $data = delete $data_for_signal{$signal};
	$epoll->delete($data->[0]);
	$Signal::Mask{$signal} = 0;
	return;
}

my %child_handler_for;

sub add_child {
	my ($pid, $cb) = @_;
	$child_handler_for{$pid} = Linux::FD::Pid->new($pid);
	$epoll->add($child_handler_for{$pid}, 'in', sub {
		$cb->($child_handler_for{$pid}->wait);
		$epoll->delete(delete $child_handler_for{$pid});
	});
	return;
}
$Signal::Mask{CHLD} = 1;

sub remove_child {
	my $pid = shift;
	$epoll->delete(delete $child_handler_for{$pid});
	return;
}

my %idle_handlers;

sub add_idle {
	my $cb   = shift;
	my $addr = refaddr $cb;
	$idle_handlers{$addr} = $cb;
	return $addr;
}

sub remove_idle {
	my $addr = shift;
	delete $idle_handlers{$addr};
	return;
}

sub one_shot {
	my $number = shift || 1;
	while (%idle_handlers) {
		while (my (undef, $handler) = each %idle_handlers) {
			my $ret = $epoll->wait($number, 0);
			return $ret if $ret;
			$handler->();
		}
	}
	return $epoll->wait($number);
}

sub maybe_shot {
	my $number = shift || 1;
	return $epoll->wait($number, 0);
}

END {
	undef $epoll;
}

1;    # End of Linux::Event

#ABSTRACT: A Linux specific high performance event loop

__END__

=head1 SYNOPSIS

 XXX

=head1 DESCRIPTION

This module is an expermental event loop for modern versions of Linux (2.6.27 or higher is recommended). It's intended as an alternative back-end for higher level loops such as POE and AnyEvent, but may be used directly too.

=head1 SUBROUTINES/METHODS

=over 4

=item * add_fh($fh, $mode, $callback)

=item * remove_fh($fh)

=item * add_child($pid, $callback)

=item * remove_child($pid)

=item * add_signal($signal, $callback)

=item * remove_signal($signal)

=item * add_timer($after, $interval, $callback)

=item * remove_timer($timerid)

=item * set_timer($timerid, $after, $interval)

=item * add_idle($callback)

=item * remove_idle($callback)

=item * one_shot($max_events = 1)

=item * maybe_shot($max_events = 1)

=back

