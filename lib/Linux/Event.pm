package Linux::Event;

use 5.010;
use strict;
use warnings FATAL => 'all';
use experimental 'smartmatch';

use Carp qw/croak/;
use Hash::Util::FieldHash qw/fieldhash id_2obj/;
use Linux::Epoll;
use Linux::FD qw/signalfd timerfd/;
use Linux::FD::Pid;
use List::Util qw/reduce/;
use List::MoreUtils qw/uniq/;
use POSIX qw/WNOHANG/;
use Scalar::Util qw/refaddr weaken/;
use Signal::Mask;

use namespace::clean;

my $epoll = Linux::Epoll->new;

my $waitbuffer_size = 16;
my $any_child       = -1;
my $no_child        = 0;

fieldhash my %data_for_fh;
fieldhash my %mode_for;
fieldhash my %callback_for;

my $reset_mode = sub {
	my $fh = shift;
	$mode_for{$fh} = [ uniq( map { @{ $_->[0] } } values %{ $data_for_fh{$fh} } ) ];
	$epoll->modify($fh, $mode_for{$fh}, $callback_for{$fh});
	return;
};

my $real_add = sub {
	my ($fh, $mode) = @_;
	my %data;
	$callback_for{$fh} = sub {
		my $event = shift;
		for my $callback (values %data) {
			$callback->[1]->($event) if $event ~~ $callback->[0];
		}
	};
	$epoll->add($fh, $mode, $callback_for{$fh});
	return \%data;
};

sub add_fh {
	my ($fh, $mode, $cb) = @_;
	weaken $fh;
	my $addr = refaddr($cb);
	my @mode = ref $mode ? sort @$mode : $mode;
	if (!exists $data_for_fh{$fh}) {
		$data_for_fh{$fh} = $real_add->($fh, \@mode);
		$data_for_fh{$fh}{$addr} = [ \@mode, $cb ];
		weaken $data_for_fh{$fh};
		$mode_for{$fh} = \@mode;
	}
	else {
		$data_for_fh{$fh}{$addr} = [ \@mode, $cb ];
		$reset_mode->($fh) unless join(',', @$mode) eq join(',', @{ $mode_for{$fh} });
	}
	return $addr;
}

sub modify_fh {
	my ($fh, $addr, $mode, $cb) = @_;
	$mode = ref $mode ? $mode : [ $mode ];
	if (! exists $data_for_fh{$fh} || ! exists $data_for_fh{$fh}{$addr}) {
		croak "Can't modify $addr: no such entry";
	}
	$data_for_fh{$fh}{$addr} = [ $mode, $cb ];
	$reset_mode->($fh) unless join(',', @$mode) eq join(',', @{ $mode_for{$fh} });
	return $addr;
}

sub remove_fh {
	my ($fh, $addr) = @_;
	return if not delete $data_for_fh{$fh}{$addr};
	if (not keys %{ $data_for_fh{$fh} }) {
		$epoll->delete($fh);
		delete $data_for_fh{$fh};
		delete $mode_for{$fh};
		delete $callback_for{$fh};
	}
	return;
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
	croak '$signal must be a name or a POSIX::SigSet object' if ref $signal and not $signal->isa('POSIX::SigSet');
	my $signalfd = signalfd($signal);
	$signalfd->blocking(0);
	my $callback = sub {
		my $arg = $data_for_signal{$signal}->receive;
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

my %child_handler_for;

sub add_child {
	my ($pid, $cb) = @_;
	$child_handler_for{$pid} //= Linux::FD::Pid->new($pid);
	add_fh($child_handler_for{$pid}, sub {
		waitpid $pid, WNOHANG;
		$cb->();
	});
	return;
}
$Signal::Mask{CHLD} = 1;

sub remove_child {
	my $pid = shift;
	delete $child_handler_for{$pid};
	return;
}

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

=item * one_shot($maxevents = 1)

=back

