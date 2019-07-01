#! /usr/bin/env perl
use Mojo::Base -strict, -signatures;

use Mojo::File 'path';
use Mojo::Template;
use Mojo::Util qw|decode encode extract_usage getopt|;
use POSIX 'strftime';
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
  my $release = $config->{releases}{$build};

  $release->{version_string} = join ', ', $release->{versions}->@*;

  $release->{from} ||= $config->{docker}{from};

  $release->{dockerfile} = {
    name => "$build/Dockerfile",
    url  => "$config->{git}{repo}/blob/master/$build/Dockerfile",
  };
  $release->{dockerfile}{link}
    = qq|[$release->{version_string} ($release->{dockerfile}{name})]($release->{dockerfile}{url})|;

  $release->{keyserver} ||= 'ha.pool.sks-keyservers.net';
}

update($config)  if $update;
build($config)   if $build;
commit($config)  if $commit;
publish($config) if $publish;

# build images

sub build ($config) {
  my $image = $config->{docker}{image};

  my %pulled;

  for my $build (sort keys $config->{releases}->%*) {
    my $release = $config->{releases}{$build};
    unless ($pulled{$release->{from}}) {
      my @cmd = (qw|docker image pull|, $release->{from});
      system(@cmd) == 0 or die $!;
      $pulled{$release->{from}} = 1;
    }

    say qq|
#
# $image
#
# building image: $build $release->{versions}[0]
#
|;

    my @cmd = qw|docker image build|;
    for ($release->{versions}->@*) {
      push @cmd, '-t', "$image:$_";
    }
    push @cmd, "$build/";
    system(@cmd) == 0 or die $!;
  }
}

# git commit

sub commit ($config) {
  my $git_version
    = $config->{git}{version} || $config->{releases}{main}{versions}[0]
    or die 'No git version found.';
  my @cmd = (qw|git commit -am|, qq|Update to version $git_version.|);

  system(@cmd) == 0 or die $!;
}

# publish to Github and Dockerhub

sub publish ($config) {
  my $image = $config->{docker}{image};

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
      my $release = $config->{releases}{$build};
      say qq|
#
# $image
#
# publishing image: $build $release->{versions}[0]
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
  my $warning   = q|#
# this file is generated via docker-builder/generate.pl
#
# do not edit it directly
#|;
  my $html_warning
    = '<!-- this file is generated via docker-builder/generate.pl, do not edit it directly -->';

  my (%args, $rendered);
  for my $build (keys $config->{releases}->%*) {
    my $release = $config->{releases}{$build};
    my $version = $release->{versions}[0];
    my $from    = $release->{from};
    say "$build $version";

    # labels
    my @labels;
    my $add_label = sub ($key, $value) {
      $value = qq|"$value"| if $value =~ /\s/;
      push @labels, qq|LABEL org.opencontainers.image.$key=$value|;
    };

    chomp(my $author_name  = `git config --get user.name`);
    chomp(my $author_email = `git config --get user.email`);
    $add_label->(authors => "$author_name <$author_email>");

    $add_label->(licenses => $config->{global}{license});

    $add_label->(version => $version);
    $add_label->(created => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime));

    for my $context (qw|title description|) {
      my $text = $config->{global}{$context};
      $text =~ s/\[(.*?)\]\(.*?\)/$1/g;
      $add_label->($context => $text);
    }

    $add_label->(source        => $release->{dockerfile}{url});
    $add_label->(url           => $config->{git}{repo});
    $add_label->(documentation => "$config->{git}{repo}/blob/master/README.md");

    my $target = path($build)->make_path;
    %args = (
      from         => $from,
      global       => $config->{global},
      labels       => join("\n", sort @labels),
      release      => $release,
      release_name => $build,
      warning      => $warning
    );

    for my $template (@templates) {
      $rendered
        = $mt->vars(1)->render_file("templates/$template->{source}", \%args);

      $target->child($template->{target})->spurt(encode 'UTF-8', $rendered);
    }
  }

  %args = (
    $config->{releases}->%*,
    global  => $config->{global},
    warning => $html_warning
  );
  $args{from} = $config->{docker}{from} if $config->{docker}{from};
  $rendered = $mt->vars(1)->render_file('templates/readme.ep', \%args);
  path('README.md')->spurt(encode 'UTF-8', $rendered);
}

=head1 SYNOPSIS

  generate.pl OPTIONS [PATH]
    -u, --update
    -b, --build
    -c, --commit
    -p, --publish

=cut
