#! /usr/bin/env perl
use Mojo::Base -strict, -signatures;

use Mojo::File 'path';
use Mojo::Template;
use Mojo::Util qw|decode encode extract_usage getopt|;
use YAML::XS;

chdir $ARGV[0] if $ARGV[0];

getopt
  'b|build'   => \my $build,
  'c|commit'  => \my $commit,
  'p|publish' => \my $publish,
  'u|update'  => \my $update;

die 'Usage: ' . extract_usage unless $build || $commit || $publish || $update;

my $config = Load path('config.yml')->slurp;
for my $build (keys $config->{releases}->%*) {
  my $release = $config->{releases}->{$build};

  my @versions = $release->{versions}->@*;
  push @versions, $release->{latest} ? 'latest' : $build;
  $release->{version_string} = join ', ', @versions;

  $release->{dockerfile} = {
    name => "$build/Dockerfile",
    url  => "$config->{git}->{repo}/blob/master/$build/Dockerfile",
  };
  $release->{dockerfile}->{link}
    = qq|[$release->{version_string} ($release->{dockerfile}->{name})]($release->{dockerfile}->{url})|;

  $release->{keyserver} ||= 'ha.pool.sks-keyservers.net';
}

update($config)  if $update;
build($config)   if $build;
commit($config)  if $commit;
publish($config) if $publish;

# build images

sub build ($config) {
  my $image = $config->{docker}->{image};

  my @cmd = (qw|docker image pull|, $config->{docker}->{from});
  system(@cmd) == 0 or die $!;

  for my $build (sort keys $config->{releases}->%*) {
    my $release = $config->{releases}->{$build};
    say qq|
#
# $image
#
# building image: $build $release->{versions}->[0]
#
|;

    @cmd = qw|docker image build|;
    for ($release->{versions}->@*) {
      push @cmd, '-t', "$image:$_";
    }
    push @cmd, '-t', $release->{latest} ? "$image:latest" : "$image:$build";
    push @cmd, "$build/";
    system(@cmd) == 0 or die $!;
  }
}

# git commit

sub commit ($config) {
  my ($latest) = grep { $_->{latest} } values $config->{releases}->%*;
  my @cmd
    = (qw|git commit -am|, qq|Update to version $latest->{versions}->[0].|);

  system(@cmd) == 0 or die $!;
}

# publish to Github and Dockerhub

sub publish ($config) {
  my $image = $config->{docker}->{image};

  say qq|
#
# $image:
#
# - publish to Github
#
|;

  my @cmd = qw|git push|;
  system(@cmd) == 0 or die $!;

  if ($image =~ /\//) {
    for my $build (keys $config->{releases}->%*) {
      my $release = $config->{releases}->{$build};
      say qq|
#
# $image
#
# publishing image: $build $release->{versions}->[0]
#
|;

      @cmd = qw|docker image push|;
      for ($release->{versions}->@*) {
        system(@cmd, "$image:$_") == 0 or die $!;
      }
      system(@cmd, $release->{latest} ? "$image:latest" : "$image:$build") == 0
        or die $!;
    }
  } else {
    say '# (not published to Dockerhub)';
  }
}

# update files using templates

sub update ($config) {
  my $mt        = Mojo::Template->new;
  my @templates = $config->{templates}->@*;
  my $from      = $config->{docker}->{from};
  my $warning   = q|#
# this file is generated via docker-builder/update.pl
#
# do not edit it directly
#|;
  my $html_warning
    = '<!-- this file is generated via docker-builder/update.pl, do not edit it directly -->';

  my (%args, $rendered, $tpl);
  for my $build (keys $config->{releases}->%*) {
    my $release = $config->{releases}->{$build};
    say "$build $release->{versions}->[0]";

    my $target = path($build)->make_path;

    for my $template (@templates) {
      $tpl  = decode 'UTF-8', path("templates/$template->{source}")->slurp;
      %args = (
        from         => $from,
        global       => $config->{global},
        release      => $release,
        release_name => $build,
        warning      => $warning
      );
      $rendered = $mt->vars(1)->render("$tpl", \%args);

      $target->child($template->{target})->spurt(encode 'UTF-8', $rendered);
    }
  }

  $tpl = decode 'UTF-8', path('templates/readme.ep')->slurp;
  %args = ($config->{releases}->%*, from => $from, warning => $html_warning);
  $rendered = $mt->vars(1)->render($tpl, \%args);
  path('README.md')->spurt(encode 'UTF-8', $rendered);
}

=head1 SYNOPSIS

  update.pl OPTIONS [PATH]
    -u, --update
    -b, --build
    -c, --commit
    -p, --publish
