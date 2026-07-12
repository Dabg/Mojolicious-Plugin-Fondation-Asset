package Mojolicious::Plugin::Fondation::Asset;

# ABSTRACT: AssetPack wrapper -- generate via command, load pre-built def at runtime

use Mojo::Base 'Mojolicious::Plugin', -signatures;


=head1 SYNOPSIS

  # myapp.pl asset generate          Generate assets/assetpack.def + process
  # myapp.pl asset generate -y       Force overwrite

=head1 DESCRIPTION

This plugin wraps L<Mojolicious::Plugin::AssetPack>. Asset definitions are
collected from all Fondation plugins via the C<asset generate> command,
which merges them into C<assets/assetpack.def> and processes the bundles.

During the merge, C<< << >> (fetch) directives for remote URLs (C<https?://>)
are normalized to single C<< < >>. This prevents AssetPack from marking
remote assets as Null (which would exclude them from rendering in development
mode). Local assets keep their original C<< < >> operator.

At runtime (C<fondation_finalyze>), AssetPack is loaded only if the merged
C<assetpack.def> exists. If missing, a warning is logged and startup
continues -- run C<asset generate> first. If the def exists, AssetPack is
loaded, plugin public directories are registered as store paths, and
C<process()> is called to register all asset topics. This second
C<process()> call skips already-cached external files.

=head1 CONFIGURATION

  # myapp.conf
  {
      Fondation => {
          dependencies => ['Fondation::Asset'],
      },
  }

The plugin registers its CLI command namespace (C<asset generate>) in
C<register()> and sets up AssetPack at runtime in C<fondation_finalyze>.

=head1 COMMANDS

=head2 asset generate

Scans all Fondation plugins for C<share/assets/assetpack.def>, merges them,
writes C<assets/assetpack.def>, and processes assets through AssetPack.

Options: C<-y> (overwrite without prompt).

=head1 RUNTIME

On startup (C<fondation_finalyze>), if C<assets/assetpack.def> exists,
AssetPack is loaded, plugin public directories are registered, and
C<process()> is called to register all asset topics for template helpers.
External files already cached by C<asset generate> are not re-downloaded.

If the def is missing, a warning is logged and startup continues -- run
C<asset generate> first.

=cut

sub fondation_meta {
    return {
        dependencies => [],
        after        => ['Fondation::OpenAPI'],
        defaults     => {
            fondation_init    => [
                ['asset', 'generate', '-y'],
            ],
            fondation_upgrade => [
                ['asset', 'generate', '-y'],
            ],
            fondation_clean   => ['assets/'],
        },
    };
}

sub register ($self, $app, $conf = {}) {
    $app->defaults('asset.config' => $conf);

    push @{$app->commands->namespaces},
        'Mojolicious::Plugin::Fondation::Asset::Command';

    return $self;
}

sub fondation_finalyze ($self, $app, $long_name) {
    my $def_file = $app->home->child('assets', 'assetpack.def');

    unless (-f $def_file) {
        $self->log->warn(
            "No assetpack.def found at $def_file. "
            . "Run 'asset generate' first."
        );
        return;
    }

    # Load AssetPack -- it auto-discovers assetpack.def from assets/
    $app->plugin('AssetPack' => {
        pipes => [qw(Fetch Sass Css Combine)],
    });

    # Register local public/ and plugin public dirs for asset resolution
    my $asset = $app->asset;
    push @{ $asset->store->paths }, $app->home->child('public');

    for my $long (@{ $app->manager->load_order }) {
        my $entry    = $app->manager->registry->{$long};
        my $public_dir = $entry->{public_dir};
        if ($public_dir) {
            push @{ $asset->store->paths }, $public_dir->to_string;
        }
    }

    # Process assets to register topics (skips already-cached external files).
    # Skip during 'fondation refresh' — the clean phase will remove assets/,
    # then 'asset generate -y' in the init phase will rebuild from scratch.
    if (grep { $_ eq 'refresh' } @ARGV) {
        $self->log->debug("Skipping AssetPack process during fondation refresh");
        return;
    }

    $asset->process();

    $self->log->debug("AssetPack loaded from $def_file");
}

1;
