use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
	module_name         => 'Linux::Event',
	license             => 'perl',
	dist_author         => q{Leon Timmermans <leont@cpan.org>},
	dist_version_from   => 'lib/Linux/Event.pm',
	build_requires      => {
		'Test::More'    => 0,
	},
	requires            => {
		perl            => 5.010,
		'Const::Fast'   => 0,
		'Linux::FD'     => 0, 
		'Linux::Epoll'  => 0.002,
		'POSIX::AtFork' => 0,
		'Signal::Mask'  => 0,
		'namespace::clean' => 0,
	},
	add_to_cleanup      => [ 'Linux-Event-*' ],
	create_makefile_pl => 'traditional',
);

$builder->create_build_script();
