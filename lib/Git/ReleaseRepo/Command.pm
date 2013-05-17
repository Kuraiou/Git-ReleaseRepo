package Git::ReleaseRepo::Command;

use strict;
use warnings;
use Moose;
use App::Cmd::Setup -command;
use YAML::Tiny;
use File::HomeDir;
use File::Spec::Functions qw( catfile catdir );
use Git::Repository;

has config_file => (
    is      => 'ro',
    isa     => 'Str',
    default => sub {
        catfile( File::HomeDir->my_home, '.releaserepo' );
    },
);

has config => (
    is      => 'ro',
    isa     => 'YAML::Tiny',
    lazy    => 1,
    default => sub {
        my ( $self ) = @_;
        if ( -f $self->config_file ) {
            return YAML::Tiny->read( $self->config_file );
        }
        else {
            return YAML::Tiny->new;
        }
    },
);

sub write_config {
    my ( $self ) = @_;
    return $self->config->write( $self->config_file );
}

has repo_name => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub { (keys %{$_[0]->config})[0] },
);

has repo_dir => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub { $_[0]->config->{$_[0]->repo_name}{work_tree} },
);

has git => (
    is      => 'ro',
    isa     => 'Git::Repository',
    lazy    => 1,
    default => sub {
        my $repo_dir = $_[0]->repo_dir;
        return Git::Repository->new(
            work_tree => $_[0]->repo_dir,
            git_dir => catdir( $_[0]->repo_dir, '.git' ),
        );
    },
);

has release_prefix => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        my ( $self ) = @_;
        my $repo = $self->config->[0];
        my $repo_name = [keys %$repo]->[0];
        return $repo->{$repo_name}{release_prefix};
    },
);

sub submodule {
    my ( $self ) = @_;
    my %submodules;
    for my $line ( $self->git->run( 'submodule' ) ) {
        # <status><SHA1 hash> <submodule> (ref name)
        $line =~ m{^.(\S+)\s(\S+)};
        $submodules{ $2 } = $1;
    }
    return wantarray ? %submodules : \%submodules;
}

sub submodule_git {
    my ( $self, $module ) = @_;
    return Git::Repository->new(
        work_tree => catdir( $self->git->work_tree, $module ),
    );
}

sub outdated {
    my ( $self, $ref ) = @_;
    $ref ||= "refs/heads/master";
    my $git = $self->git;
    my %submod_refs = $self->submodule;
    my @outdated;
    for my $submod ( keys %submod_refs ) {
        my $subgit = $self->submodule_git( $submod );
        my %remote = $self->ls_remote( $subgit );
        if ( !exists $remote{ $ref } || $submod_refs{ $submod } ne $remote{$ref} ) {
            push @outdated, $submod;
        }
    }
    return @outdated;
}

sub checkout {
    my ( $self, $commit ) = @_;
    $self->git->run( checkout => $commit );
    $self->git->run( submodule => update => '--init' );
}

sub list_versions {
    my ( $self ) = @_;
    my $prefix = $self->release_prefix;
    my %refs = $self->ls_remote( $self->git );
    my @versions = reverse sort version_sort grep { m{^$prefix} } map { (split "/", $_)[-1] } keys %refs;
    return @versions;
}

sub latest_version {
    my ( $self ) = @_;
    my @versions = $self->list_versions;
    return $versions[0];
}

sub version_sort {
    my @a = split /[.]/, $a;
    my @b = split /[.]/, $b;
    my $format = "%s." . ( "%03i" x ( @a > @b ? @a-1 : @b-1 ) );
    return sprintf( $format, @a ) cmp sprintf( $format, @b );
}

sub ls_remote {
    my ( $self, $git ) = @_;
    my %refs;
    my $cmd = $git->command( 'ls-remote', 'origin' );
    while ( defined( my $line = readline $cmd->stdout ) ) {
        # <SHA1 hash> <symbolic ref>
        my ( $ref_id, $ref_name ) = split /\s+/, $line;
        $refs{ $ref_name } = $ref_id;
    }
    return wantarray ? %refs : \%refs;
}

sub opt_spec {
    return (
        [ 'repo_dir:s' => 'The path to the release repository' ],
    );
}

sub execute {
    my ( $self, $opt, $args ) = @_;
    if ( exists $opt->{repo_dir} ) {
        $self->repo_dir( $opt->{repo_dir} );
    }
    inner();
    $self->write_config;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__
