#!/usr/bin/perl

use Mojolicious::Lite -signatures;

use Mojo::Log;

use Capture::Tiny qw(capture);
use Slack::WebHook;

get '/' => sub ($c) {
    my $tag = $c->param('tag');
    my $t   = $c->param('t');

    my $token   = $ENV{TOKEN};
    my $webhook = $ENV{WEBHOOK};
    my $github_token = $ENV{GITHUB_TOKEN};

    my $hook = $webhook ? Slack::WebHook->new( url => $webhook ) : undef;

    my $log = Mojo::Log->new(
        path  => '/tmp/koha-import-github-releases-webhook.log',
        level => 'trace',
    );

    $log->info("INCOMING - TAG:$tag / TOKEN:$t");

    if ( $token eq $t ) {
        $hook->post_ok("APTLY - Received tag $tag") if $hook;
        if ( $tag =~ /\w*_v\d\d\.\d\d\.\d\d\-\d\d/ ) {
            $hook->post_start("APTLY - Importing tag $tag") if $hook;
            my ( $stdout, $stderr, $failed ) = capture {
                system(
                    "./koha-import-github-releases.pl -p /tmp/ -v -t $github_token --mt $tag");
            };
            $hook->post_end("APTLY - Finished importing tag $tag") if $hook && !$failed;

            $hook->post_error("APTLY - Failed importing tag $tag: $stderr")
              if $hook && $failed;;

            $log->info($stdout)  if $stdout;
            $log->error($stderr) if $stderr;

            $c->render(
                text => $failed ? $stderr : $stdout,
                status => $failed ? 400 : 200,
            );
        }
        else {
            $hook->post_error("APTLY - Invalid tag $tag") if $hook;
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
