#!perl

use Test::More tests => 1;

BEGIN {
    use_ok( 'Linux::Event' ) || print "Bail out!
";
}

diag( "Testing Linux::Event $Linux::Event::VERSION, Perl $], $^X" );
