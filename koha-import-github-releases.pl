#!/usr/bin/perl

use feature 'say';

use Modern::Perl;

use Archive::Extract;
use DateTime;
use File::Path qw(rmtree);
use Getopt::Long::Descriptive;
use JSON qw(from_json);
use LWP::UserAgent;

my ( $opt, $usage ) = describe_options(
    'koha-import-github-releases %o ',
    [ 'path|p=s', "The path to download assets to", { required => 1 } ],
    [
        'date|d=s',
"The date ( in ISO format ) to limit downloading releases to. Defaults to current date."
    ],
    [],
    [ 'verbose|v+', "print extra stuff" ],
    [ 'help|h', "print usage message and exit", { shortcircuit => 1 } ],
);

my $ua = LWP::UserAgent->new;
$ua->show_progress( $opt->verbose ? 1 : 0 );

my $date = $opt->date || DateTime->now->ymd;
say "Using Date: $date\n" if $opt->verbose;

my @urls = (
    'https://api.github.com/repos/bywatersolutions/bywater-koha/releases',
    'https://api.github.com/repos/bywatersolutions/bywater-koha-future/releases',
);

foreach my $url (@urls) {
    my $response = $ua->get($url)->decoded_content;

    my $data = from_json($response);
    foreach my $d (@$data) {
        next unless $d->{created_at} =~ /^$date/;

        my $tag_name = $d->{tag_name};
        say "$tag_name:" if $opt->verbose;
        my ( $shortname, $version, $mark ) = split( /-/, $tag_name );
        say "  Shortnamme: $shortname" if $opt->verbose > 1;
        say "  Version: $version"      if $opt->verbose > 1;
        say "  Mark: $mark"            if $opt->verbose > 1;

        my ( $major, $minor, $patch ) = split( /\./, $version );
        $major =~ s/^.//;    # Remove leading 'v'
        say "    Major Version: $major" if $opt->verbose > 2;
        say "    Minor Version: $minor" if $opt->verbose > 2;
        say "    Patch Version: $patch" if $opt->verbose > 2;

        my $asset                = $d->{assets}->[0];
        my $name                 = $asset->{name};
        my $browser_download_url = $asset->{browser_download_url};

        say "  Tag: $tag_name"                   if $opt->verbose;
        say "  Asset Name: $name"                if $opt->verbose;
        say "  Asset URL: $browser_download_url" if $opt->verbose;

        my $file_path = $opt->path . '/' . $name;

        say "Downloading $name..." if $opt->verbose;
        $response = $ua->get($browser_download_url);
        say "Finished downloading $name" if $opt->verbose;

        open my $fh, '>', $file_path or die "Failed opening $file_path";
        print $fh $response->content;
        close $fh;

        my $ae       = Archive::Extract->new( archive => $file_path );
        my $data_dir = $file_path . ".data";
        my $ok       = $ae->extract( to => $data_dir ) or die $ae->error;

        if ($ok) {    # Import the file into aptly
            my $major_minor = "$major.$minor";
            my $is_new = create_repo( $major_minor, $shortname, $opt->verbose );
            my $deb_file = "$data_dir/koha-common_$major.$minor.$patch~$shortname~$mark-1_all.deb";
            add_or_update_package( $is_new, $major_minor, $shortname, $deb_file, $opt->verbose );
        }

        say "Deleting $name" if $opt->verbose;
        unlink $file_path;
        rmtree( $data_dir, $opt->verbose );
        say q{};
    }
}

=head2 add_or_update_package

Adds or updates the package for the given repo

my $is_new = 1; # Bool, true if repo is new and empty
my $version = 'v19.05';
my $shortname = 'bywater'; # or 'clic', 'masscat', etc
my $deb_file = '/path/to/koha-common.db';
my $created = add_or_update_package( $version, $shortname, $deb_file );

Returns true of the repo was created, false if the repo already exists.

=cut

sub add_or_update_package {
    my ( $is_new, $version, $shortname, $deb_file, $verbose ) = @_;

    my @output;

    @output = qx( aptly repo remove $version-$shortname koha-common )
      unless $is_new;
    if ( $verbose > 3 && @output ) {
        say
          for ( "Removing koha-common from repo $version-$shortname: ",
            @output );
    }
    @output = qx( aptly repo add $version-$shortname $deb_file );
    if ( $verbose > 3 ) {
        say for ( "Adding file $deb_file to $version-$shortname: ", @output );
    }

    @output = qx( aptly publish repo -distribution=$version-$shortname -component=main $version-$shortname )
      if $is_new;

    if ( $verbose > 3 && $is_new ) {
        say for ( "Publishing $version-$shortname: ", @output );
    }
    @output = qx( aptly publish update $version-$shortname );
    if ( $verbose > 3 ) {
        say for ( "Updating $version-$shortname: ", @output );
    }
}

=head2 create_repo

Creates the given repo if necessary.
The repo name will be a combination $version-$shorname
The distribution will be $version-$shortname
The component will be main

my $version = 'v19.05';
my $shortname = 'bywater'; # or 'clic', 'masscat', etc
my $created = create_repo( $version, $shortname );

Returns true of the repo was created, false if the repo already exists.

=cut

sub create_repo {
    my ( $version, $shortname, $verbose ) = @_;

    my @output = qx( aptly repo list | grep $version-$shortname );

    if (@output) {
        return 0;    # Repo exists
    }
    else {
        @output = qx( aptly repo create -distribution=$version-$shortname -component=main $version-$shortname );
        if ( $verbose > 3 ) {
            say for ( "Creating new repo $version-$shortname: ", @output );
        }
        return 1;    # Repo was newly created
    }
}
