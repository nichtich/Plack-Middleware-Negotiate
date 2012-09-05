use strict;
use warnings;
use v5.10.1;
use Test::More;
use Plack::Builder;
use Plack::Test;
use HTTP::Request::Common;

my $app = sub {
	my $env = shift;
	[200,[],[$env->{'negotiate.format'} // '']] 
};

# no formats specified
my $empty = builder {
	enable 'Negotiate', parameter => 'foo';
	$app;
};

sub check_empty {
	my $cb = shift;
	is $cb->(GET "/foo")->content, '', 'no formats';
	is $cb->(GET "/foo?bar=xml")->content, '', 'no formats';
	is $cb->(GET "/foo.xml")->content, '', 'no formats';
};

test_psgi 
	$empty => \&check_empty;

done_testing;
