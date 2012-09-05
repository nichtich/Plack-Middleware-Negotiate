use strict;
use warnings;
use v5.10.1;
use Test::More;
use Plack::Builder;
use Plack::Test;
use HTTP::Request::Common;

my $app = sub {
	my $env = shift;
	[200,[],[ 
		join '|', 
			$env->{'negotiate.format'},
			$env->{PATH_INFO},
			$env->{REQUEST_URI} 
	]]; 
};

my $stack = builder {
	enable 'Negotiate',
		formats => {
			xml  => { type => 'application/xml' },
			html => { type => 'text/html' },
		},
		parameter => 'format',
		extension => 'strip';
	$app;
};

test_psgi $stack => sub {
	my $cb = shift;

	my $res = $cb->(GET '/foo.xml');
	is $res->content, 'xml|/foo|/foo', 'stripped extension';

	$res = $cb->(GET '/foo.xml?format=html');
	is $res->content, 'html|/foo.xml|/foo.xml?format=html', 'parameter';

	$res = $cb->(GET '/foo.xml?format=baz');
	is $res->content, 'xml|/foo|/foo?format=baz', 'stripped extension, kept query';
};

done_testing;
