#!/usr/bin/perl

use Mojolicious::Lite -signatures;

use Mojo::Log;

use Capture::Tiny qw(capture);

get '/' => sub ($c) {
    my $tag = $c->param('tag');
    my $t   = $c->param('t');

    my $token = $ENV{TOKEN};

    my $log = Mojo::Log->new(
        path  => '/tmp/koha-import-github-releases-webhook.log',
        level => 'trace',
    );

    $log->info("INCOMING - TAG:$tag / TOKEN:$t");

    if ( $token eq $t ) {
        if ( $tag =~ /\w*_v\d\d\.\d\d\.\d\d\-\d\d/ ) {
            my ($stdout, $stderr, $exit) = capture {
                system("./koha-import-github-releases.pl -p /tmp/ -v --mt $tag");
            };
            $c->render( text => $stderr || $stdout, status => $stderr ? 400 : 200 );
        }
        else {
            $log->info("ERROR - INVALID TAG:$tag");
            $c->render( text => "Invalid Tag: $tag", status => 400 );
        }
    }
    else {
        $log->info("ERROR - INVALID TOKEN:$t");
        $c->render( text => "Invalid Token: $t", status => 400 );
    }
};

app->start;
