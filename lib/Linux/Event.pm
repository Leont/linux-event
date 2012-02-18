package Linux::Event;

use 5.008;
use strict;
use warnings FATAL => 'all';

use Carp qw/croak/;
use Const::Fast;
use Hash::Util::FieldHash qw/fieldhash id_2obj/;
use Linux::Epoll;
use Linux::Epoll::Util ':all';
use Linux::FD qw/signalfd timerfd/;
use POSIX qw/WNOHANG/;
use POSIX::AtFork qw/pthread_atfork/;
use Scalar::Util qw/refaddr weaken/;
use Signal::Mask;

use namespace::clean;

my $epoll = Linux::Epoll->new;

const my $waitbuffer_size => 16;
const my $any_child       => -1;
const my $no_child        => -1;

fieldhash my %data_for_fh;
fieldhash my %mode_for;

my $reset_mode = sub {
	my $fh = shift;
	$mode_for{$fh} = reduce { our ($a, $b); $a | $b } grep { $_->[0] } values %{ $data_for_fh{$fh} };    ## no critic (Package)
};

my $real_add = sub {
	my ($fh, $mode) = @_;
	$epoll->add(
		$fh, $mode,
		sub {
			my $event = shift;
			for my $callback (values %{ $data_for_fh{$fh} }) {
				$callback->[1]->() if $callback->[0] & $event;
			}
		}
	);
	return;
};

sub add_fh {
	my ($fh, $mode, $cb) = @_;
	weaken $fh;
	my $addr     = refaddr($cb);
	my $modebits = event_names_to_bits($mode);
	if (!$data_for_fh{$fh}) {
		$real_add->($fh, $mode);
		$mode_for{$fh} = $modebits;
	}
	$data_for_fh{$fh}{$addr} = [ $modebits, $cb ];
	$reset_mode->($fh) if $modebits != $mode_for{$fh};
	return $addr;
}

sub remove_fh {
	my ($fh, $addr) = @_;
	return if not delete $data_for_fh{$fh}{$addr};
	if (not keys %{ $data_for_fh{$fh} }) {
		$epoll->remove($fh);
		delete $data_for_fh{$fh};
	}
	return;
}

my %timerfd_for;
my %data_for_timer;

sub add_timer {
	my ($after, $interval, $cb, $keepalive) = @_;
	$keepalive //= defined wantarray;

	my $timer = timerfd('monotonic');
	$timer->blocking(0);
	$timer->set_timeout($after, $interval);

	my $addr     = refaddr($timer);
	my $callback = sub {
		my $arg = $timer->wait;
		if (defined $arg) {
			my $data = $data_for_timer{$addr};
			$cb->($arg);
			remove_timer($addr) if not $data->[2] and not $data->[4];
		}
	};
	$epoll->add($timer, 'in', $callback);
	$data_for_timer{$addr} = [ $timer, $after, $interval, $callback, $keepalive ];
	weaken $timer;

	return $addr;
}

sub remove_timer {
	my $addr = shift;
	return if not exists $timerfd_for{$addr};
	my $data = delete $timerfd_for{$addr};
	$epoll->remove($data->[0]);
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
	croak '$signal must be a number' if ref $signal;
	my $signalfd = signalfd($signal);
	$signalfd->blocking(0);
	my $callback = sub {
		my $arg = $signalfd->receive;
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
	$epoll->remove($data->[0]);
	$Signal::Mask{$signal} = 0;
	return;
}

my $rebuild = sub {
	$epoll = Linux::Epoll->new;
	for my $key (keys %data_for_fh) {
		my $fh   = id_2obj($key);
		my $mode = event_bits_to_names($mode_for{$fh});
		$real_add->($fh, $mode);
	}
	for my $addr (keys %timerfd_for) {
	}
	for my $signame (keys %data_for_signal) {
		my ($signalfd, $callback) = @{ $data_for_signal{$signame} };
		$epoll->add($signalfd, 'in', $callback);
	}
};

my %child_handler_for;

sub add_child {
	my ($pid, $cb) = @_;
	$child_handler_for{$pid} = $cb;
	return;
}

sub remove_child {
	my $pid = shift;
	delete $child_handler_for{$pid};
	return;
}

my $child_handler = sub {
	while ((my $pid = waitpid $any_child, WNOHANG) > $no_child) {
		(delete $child_handler_for{$pid})->() if $child_handler_for{$pid};
	}
	return;
};
add_signal('CHLD', $child_handler);

pthread_atfork(undef, undef, \&CLONE);
fieldhash my %idle_handlers;

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
	while (keys %idle_handlers) {
		for my $handler (values %idle_handlers) {
			my $ret = $epoll->wait($number, 0);
			return $ret if $ret;
			$handler->();
		}
	}
	return $epoll->wait($number);
}

sub CLONE {
	$rebuild->();
	return;
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

=item * one_shot($maxevents = 1)

=back

