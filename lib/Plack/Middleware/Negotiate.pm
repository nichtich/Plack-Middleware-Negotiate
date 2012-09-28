package Plack::Middleware::Negotiate;
#ABSTRACT: Apply HTTP content negotiation as Plack middleware
use strict;
use warnings;
use v5.10.1;
use parent 'Plack::Middleware';

use Plack::Util::Accessor qw(formats parameter extension);
use Plack::Request;
use HTTP::Negotiate qw(choose);
use Carp qw(croak);

use Log::Contextual::WarnLogger;
use Log::Contextual qw(:log), 
    -default_logger => Log::Contextual::WarnLogger->new({ 
        env_prefix => 'PLACK_MIDDLEWARE_NEGOTIATE' });

sub prepare_app {
    my $self = shift;

    croak __PACKAGE__ . ' requires formats'
        unless $self->{formats} and %{$self->{formats}};

    $self->{formats}->{_} //= { };

    unless ($self->{formats}->{_}->{type}) {
        foreach (grep { $_ ne '_' } keys %{$self->{formats}}) {
            croak __PACKAGE__ . " format requires type: $_"
                unless $self->{formats}->{$_}->{type};
        }
    }

    $self->app( sub {
        [ 406, ['Content-Type'=>'text/plain'], ['Not Acceptable']];
    } ) unless $self->app;
}

sub call {
    my ($self, $env) = @_;

    my $orig_path = $env->{PATH_INFO};

    my $format = $self->negotiate($env);
    $env->{'negotiate.format'} = $format;

    my $app;
    $app = $self->{formats}->{$format}->{app} if $format and $self->{formats}->{$format};
    $app //= $self->app;

    Plack::Util::response_cb( $app->($env), sub {
        my $res = shift;
        $self->add_headers( $res->[1], $env->{'negotiate.format'} );
        $env->{PATH_INFO} = $orig_path;
        $res;
    });
}

sub add_headers {
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
}

sub negotiate {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    if (defined $self->parameter) {
        my $format = $req->param($self->parameter);
        if ( ($format // '_') ne '_' and $self->{formats}->{$format}) {
            log_trace { "format $format chosen based on query parameter" };
            return $format;
        }
    }

    if ($self->extension and $req->path =~ /\.([^.]+)$/ 
            and $self->formats->{$1}) {
        my $format = $1;
        $env->{PATH_INFO} =~ s/\.$format$//
            if $self->extension eq 'strip';
        log_trace { "format $format chosen based on extension" };
        return $format;
    }

    my $format = choose($self->variants, $req->headers);
    log_trace { "format $format chosen based on HTTP content negotiation" };
    return $format;
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

=encoding utf8

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
        $app; # neither html nor xml requested
    };

=head1 DESCRIPTION

Plack::Middleware::Negotiate applies HTTP content negotiation to a L<PSGI>
request. The PSGI environment key C<negotiate.format> is set to the chosen
format name. In addition to normal content negotiation one may enable explicit
format selection with a path extension or query parameter. The middleware takes
care for rewriting and restoring PATH_INFO if it is configured to detect and
strip a format extension. The PSGI response is enriched with corresponding HTTP
headers Content-Type and Content-Language unless these headers already exist.

If used as pure application, this middleware returns a HTTP status code 406 if
no format could be negotiated.

=head1 METHODS

=method new ( formats => { ... } [ %argument ] )

Creates a new negotiation middleware with a given set of formats. The argument
C<parameter> can be added to support explicit format selection with a query
parameter. The argument C<extension> can be used to support explicit format
selection with a virtual file extension. Use C<< format => 'strip' >> to strip
a known format name from the request path and C<< format => 'keep' >> to keep
it. Each format can be defined with C<type>, C<quality> (defaults to 1),
C<encoding>, C<charset>, and C<language>. The special format name C<_>
(underscore) is reserved to define default values for all formats.

Formats can also be used to directly route the request to a PSGI application:

    my $app = Plack::Middleware::Negotiate->new(
        formats => {
            json => { 
                type => 'application/json',
                app  => $json_app,
            },
            html => {
                type => 'text/html',
                app  => $html_app,
            }
        }
    );

=method negotiate ( $env )

Chooses a format based on a PSGI request. The request is first checked for
explicit format selection via C<parameter> and C<extionsion> (if configured)
and then passed to L<HTTP::Negotiate>. Returns the format name. May modify the
PSGI request environment keys PATH_INFO and SCRIPT_NAME if format was selected
by extension set to C<strip>.

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

=head1 LOGGING AND DEBUGGUNG

Plack::Middleware::Negotiate uses C<Log::Contextual> to emit a logging message
during content negotiation on logging level <trace>. Just set:

    $ENV{PLACK_MIDDLEWARE_NEGOTIATE_TRACE} = 1;

=head1 LIMITATIONS

The Content-Encoding HTTP response header is not automatically set on a
response and content negotiation based on size is not supported. Feel free to
comment on whether and how this middleware should support both.

=head1 SEE ALSO

L<HTTP::Negotiate>, L<HTTP::Headers::ActionPack::ContentNegotiation>

=cut
