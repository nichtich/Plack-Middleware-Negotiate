package Plack::Middleware::Negotiate;
#ABSTRACT: Apply HTTP content negotiation as PSGI Middleware
use strict;
use warnings;
use v5.10.1;

use parent 'Plack::Middleware';

use Plack::Util::Accessor qw(formats parameter extension);
use Plack::Request;
use HTTP::Negotiate qw(choose);

#use Log::Contextual::WarnLogger;
#use Log::Contextual qw(:log), -default_logger 
#    => Log::Contextual::WarnLogger->new({ env_prefix => 'PLACK_APP_NEGOTIATE' });

sub prepare_app {
    my $self = shift;

    $self->{formats} //= { }; 
    $self->{formats}->{_} //= { };

	# TODO: validate formats
}

sub call {
    my ($self, $env) = @_;

    $env->{'negotiate.format'} = $self->negotiate($env);

    my $res = $self->app->($env);

    Plack::Util::response_cb($res, sub {
        my $res = shift;

		$self->set_headers( $res->[1], $env->{'negotiate.format'} );

        $res;
    });
}

sub set_headers {
	my ($self, $headers, $name) = @_;

    my $format = $self->about($name) || return;
	my $fields = { @$headers };

	if (!$fields->{'Content-Type'}) {
		my $type = $format->{type};
		$type .= "; charset=". $format->{charset}
			if $format->{charset};
		push @$headers, 'Content-Type' => $type;
	}

	push @$headers, 'Content-Language' => $format->{language}
		if $format->{language} and !$fields->{'Content-Language'};

	# TODO: Content-Encoding (?)
}

sub negotiate {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    return unless %{$self->{formats}};

    if (defined $self->parameter) {
        my $format = $req->param($self->parameter);
        return $format if defined $format
			and $format ne '_' and $self->{formats}->{$format};
    }

    if ($self->extension and $req->path =~ /\.([^.]+)$/ 
            and $self->formats->{$1}) {
        my $format = $1;
        if ($self->extension eq 'strip') {
            $env->{PATH_INFO}   =~ s/\.$format$//;
			no warnings; # $2 undefined
			$env->{REQUEST_URI} =~ s/^([^?]*)\.$format(\?.+)?$/$1$2/;
        }
        return $format;
    }

    return choose($self->variants, $req->headers);
}

sub about {
    my ($self, $name) = @_;

	return unless defined $name and $name ne '_';

    my $default = $self->{formats}->{_};
    my $format  = $self->{formats}->{$name} || return;

    return {
        quality  => $format->{quality} // $default->{quality} // 1,
        type     => $format->{type} // $default->{type},
        encoding => $format->{encoding} // $default->{encoding},
        charset  => $format->{charset} // $default->{charset},
        language => $format->{language} // $default->{language},
    };
}

sub variants {
    my $self = shift;
    return [ 
        map { 
            my $format = $self->about($_);
            [ 
                $_, 
                $format->{quality},
                $format->{type}, 
                $format->{encoding},
                $format->{charset},
                $format->{language},
                0 
        ] } 
        grep { $_ ne '_' } keys %{$self->{formats}}
    ];
}

1;

=head1 SYNOPSIS

    builder {
        enable 'Negotiate',
            formats => {
                xml  => { 
                    type    => 'application/xml',
                    charset => 'utf-8',
                },
                html => { type => 'text/html', language => 'en' },
                _    => { size => 0 }  # default values for all formats           
            },
            parameter => 'format', # e.g. http://example.org/foo?format=xml
            extension => 'strip';  # e.g. http://example.org/foo.xml
        $app;
    };

=head1 DESCRIPTION

Plack::Middleware::Negotiate applies HTTP content negotiation, and sets the
L<PSGI> environment key C<negotiate.format> to the negotiated format name. It
further adds HTTP headers Content-Type and Content-Language unless they already
exist in the PSGI response. In addition to normal content negotiation one may
enable explicit format selection with a path extension or query parameter.

=method negotiate ( $env )

Returns the negotiated format name for a given PSGI request. May return undef
if no format was found. May modify the request if extension is set to C<strip>.

=method about ( $format )

If the format was specified, this method returns a hash with C<quality>,
C<type>, C<encoding>, C<charset>, and C<language>. Missing values are set to
the default.

=method variants ()

Returns a list of content variants to be used in L<HTTP::Negotiate>. The return
value is an array reference of array references, each with seven elements:
format name, source quality, type, encoding, charset, language, and size. The
size is always zero.

=method add_headers ( \@headers, $format )

Add apropriate HTTP response headers for a format unless the headers are
already given.

=cut
