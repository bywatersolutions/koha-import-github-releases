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
    [ 'date|d=s', "The date ( in ISO format ) to limit downloading releases to. Defaults to current date." ],
    [ 'match-version|mv=s', "Match this version, e.g. v19.11.08-05" ],
    [ 'match-tagname|mt=s', "Match this tag name, e.g. clic-v19.11.08-05" ],
    [ 'repo|r=s', "Specify the repo to be created and used, best used with --match-version or --match-tagname" ],
    [],
    [ 'verbose|v+', "print extra stuff" ],
    [ 'help|h', "print usage message and exit", { shortcircuit => 1 } ],
);

print($usage->text), exit if $opt->help;

my $ua = LWP::UserAgent->new;
$ua->show_progress( $opt->verbose ? 1 : 0 );

my $date = $opt->date;
say "Using Date: $date\n" if $date && $opt->verbose;

my $repo = $opt->repo;

my @urls = (
    'https://api.github.com/repos/bywatersolutions/bywater-koha/releases',
    'https://api.github.com/repos/bywatersolutions/bywater-koha-future/releases',
);

foreach my $url (@urls) {
    my $response = $ua->get($url)->decoded_content;

    my $data = from_json($response);
    foreach my $d (@$data) {
	if ( $date ) {
            next unless $d->{published_at} =~ /^$date/;
	}

        my $tag_name = $d->{tag_name};
        say "$tag_name:" if $opt->verbose;
        my ( $shortname, $version_mark ) = split( /_/, $tag_name );
        my ( $version, $mark ) = split( /-/, $version_mark );

	if ( $opt->match_version ) {
	    if ( "$version-$mark" eq $opt->match_version ) {
                say "VERSION MATCH FOUND for " . $opt->match_version if $opt->verbose > 1;
	    } else {
                say "$version-$mark does not match " . $opt->match_version . ": SKIPPING";
                next;
            }
	}
	if ( $opt->match_tagname ) {
	    if ( $tag_name eq $opt->match_tagname ) {
                say "TAG MATCH FOUND for " . $opt->match_tagname if $opt->verbose > 1;
	    } else {
                say "$tag_name does not match " . $opt->match_tagname . ": SKIPPING";
                next;
            }
	}

        say "  Shortnamme: $shortname" if $opt->verbose > 1;
        say "  Version: $version"      if $opt->verbose > 1;
        say "  Mark: $mark"            if $opt->verbose > 1;

        my ( $major, $minor, $patch ) = split( /\./, $version );
        $major =~ s/^.//;    # Remove leading 'v'
        say "    Major Version: $major" if $opt->verbose > 2;
        say "    Minor Version: $minor" if $opt->verbose > 2;
        say "    Patch Version: $patch" if $opt->verbose > 2;

        #TODO: The koha-common deb is now attached as a separate asset
        #if we downloaded and used that we wouldn't have to unzip a big archive
        my $asset;
        $asset = $d->{assets}->[0] if $d->{assets}->[0]->{name} =~ /^.*zip/;
        $asset = $d->{assets}->[1] if $d->{assets}->[1]->{name} =~ /^.*zip/;

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
            my $is_new = create_repo( $major_minor, $shortname, $repo, $opt->verbose );
            my $deb_file = "$data_dir/koha-common_$major.$minor.$patch~$shortname~$mark-1_all.deb";
            add_or_update_package( $is_new, $major_minor, $shortname, $deb_file, $repo, $opt->verbose );
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
    my ( $is_new, $version, $shortname, $deb_file, $repo, $verbose ) = @_;

    $repo ||= "$version-$shortname";

    my @output;

    @output = qx( aptly repo remove $repo koha-common )
      unless $is_new;
    if ( $verbose > 3 && @output ) {
        say
          for ( "Removing koha-common from repo $repo: ",
            @output );
    }
    @output = qx( aptly repo add $repo $deb_file );
    if ( $verbose > 3 ) {
        say for ( "Adding file $deb_file to $repo: ", @output );
    }

    @output = qx( aptly -architectures=amd64 publish repo -distribution=$repo -component=main $repo )
      if $is_new;

    if ( $verbose > 3 && $is_new ) {
        say for ( "Publishing $repo: ", @output );
    }
    @output = qx( aptly publish update $repo );
    if ( $verbose > 3 ) {
        say for ( "Updating $repo: ", @output );
    }
}

=head2 create_repo

Creates the given repo if necessary.
The repo name will be a combination $version-$shorname
The distribution will be $version-$shortname
The component will be main

my $version = 'v19.05';
my $shortname = 'bywater'; # or 'clic', 'masscat', etc
my $created = create_repo( $version, $shortname, $repo, $verbose );

Returns true of the repo was created, false if the repo already exists.

=cut

sub create_repo {
    my ( $version, $shortname, $repo, $verbose ) = @_;

    $repo ||= "$version-$shortname";

    my @output = qx( aptly repo list | grep "\\[$repo\\]" );

    if (@output) {
        return 0;    # Repo exists
    }
    else {
        @output = qx( aptly -architectures=amd64 repo create -distribution=$repo -component=main $repo );
        if ( $verbose > 3 ) {
            say for ( "Creating new repo $repo: ", @output );
        }
        return 1;    # Repo was newly created
    }
}
