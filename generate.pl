#! /usr/bin/env perl
use Mojo::Base -strict, -signatures;

use Print::Colored ':all';
use Mojo::File 'path';
use Mojo::Template;
use Mojo::Util qw|decode encode extract_usage getopt|;
use POSIX 'strftime';
use YAML::XS;

chdir $ARGV[0] if $ARGV[0];

getopt
  'a|all'     => \my $all,
  'b|build'   => \my $build,
  'c|commit'  => \my $commit,
  'p|publish' => \my $publish,
  'r|readme'  => \my $readme,
  't|test'    => \my $test,
  'u|update'  => \my $update;

die color_error 'Usage: ' . extract_usage
  unless $all || $build || $commit || $publish || $readme || $test || $update;

my $config = Load path('config.yml')->slurp;
for my $build (keys $config->{releases}->%*) {
  my $release = $config->{releases}{$build};

  $release->{version_string} = join ', ', _all_versions($release);

  $release->{from} ||= $config->{docker}{from};

  $release->{dockerfile} = {
    name => "$build/Dockerfile",
    url  => "$config->{git}{repo}/blob/master/$build/Dockerfile",
  };
  $release->{dockerfile}{link}
    = qq|[$release->{version_string} ($release->{dockerfile}{name})]($release->{dockerfile}{url})|;

  $release->{keyserver} ||= 'ha.pool.sks-keyservers.net';
}

update($config)  if $update  || $all;
build($config)   if $build   || $all;
test($config)    if $test    || $all;
commit($config)  if $commit  || $all;
readme($config)  if $readme  || $all;
publish($config) if $publish || $all;

# build images

sub build ($config) {
  my $image = $config->{docker}{image};

  my %pulled;

  for my $build (sort keys $config->{releases}->%*) {
    my $release = $config->{releases}{$build};
    unless ($pulled{$release->{from}}) {
      my @cmd = (qw|docker image pull|, $release->{from});
      system(@cmd) == 0 or die color_error $!;
      $pulled{$release->{from}} = 1;
    }

    if (_has_stages($release)) {
      for my $stage (_all_stages($release, 1)) {
        my $version = _first_version($release, $stage);
        say <<~"...";
          #
          # $image
          #
          # building image: $build $stage $version
          #
          ...

        my @cmd = qw|docker image build|;
        push @cmd, '--build-arg', 'NOW=' . _now();
        push @cmd, '--target',    $stage;
        for ($release->{versions}{$stage}->@*) {
          push @cmd, '--tag', "$image:$_";
        }
        push @cmd, "$build/";
        $ENV{DOCKER_BUILDKIT} = 1 if $config->{docker}{buildkit};
        system(@cmd) == 0 or die color_error $!;
      }
    } else {
      my $version = _first_version($release);
      say <<~"...";
        #
        # $image
        #
        # building image: $build $version
        #
        ...

      my @cmd = qw|docker image build|;
      push @cmd, '--build-arg', 'NOW=' . _now();
      for ($release->{versions}->@*) {
        push @cmd, '--tag', "$image:$_";
      }
      push @cmd, "$build/";
      $ENV{DOCKER_BUILDKIT} = 1 if $config->{docker}{buildkit};
      system(@cmd) == 0 or die color_error $!;
    }
  }
}

# git commit

sub commit ($config) {
  my $git_version = $config->{git}{version} || _first_version($config->{releases}{main})
    or die color_error 'No git version found.';
  my @cmd = (qw|git commit -am|, qq|Update to version $git_version.|);

  system(@cmd) == 0 or die color_error $!;
}

# publish to Github and Dockerhub

sub publish ($config) {
  my $image = $config->{docker}{image};

  say <<~"...";
    #
    # $image:
    #
    # publish to Github
    #
    ...

  my @cmd = qw|git push|;
  system(@cmd) == 0 or die color_error $!;

  unless ($image =~ /\//) {
    say '# (not published to Dockerhub)';
    return;
  }

  @cmd = qw|docker image push|;
  for my $build (sort keys $config->{releases}->%*) {
    my $release = $config->{releases}{$build};

    if (_has_stages($release)) {
      for my $stage (_all_stages($release, 1)) {
        my $version = _first_version($release, $stage);
        say <<~"...";
          #
          # $image
          #
          # publishing image: $build $stage $version
          #
          ...

        for (_all_versions($release, $stage)) {
          system(@cmd, "$image:$_") == 0 or die color_error $!;
        }
      }
    } else {
      my $version = _first_version($release);
      say <<~"...";
        #
        # $image
        #
        # publishing image: $build $version
        #
        ...

      for (_all_versions($release)) {
        system(@cmd, "$image:$_") == 0 or die color_error $!;
      }
    }
  }
}

# copy readme to Windows clipboard (WSL)

sub readme ($config) {
  system('cat README.md | clip.exe') == 0 or die color_error 'Windows clipboard not available!';
  say <<~"...";
    #
    # README copied to Windows clipboard
    #
    ...
}

# test

sub test ($config) {
  my $testfile = '.project/test.sh';
  if ($testfile) {
    system($testfile) == 0 or die color_error $!;

    my $continue = prompt_input 'Continue [y]: ', -default => 'y';
    unless ($continue =~ /y/i) {
      say_warn 'Aborted by user.';
      exit;
    }
  } else {
    say color_warn 'No test script available!';
  }
}

# update files using templates

sub update ($config) {
  my $mt        = Mojo::Template->new;
  my @templates = $config->{templates}->@*;
  chomp(my $warning = <<~'...');
    #
    # this file is generated via docker-builder/generate.pl
    #
    # do not edit it directly
    #
    ...
  my $html_warning
    = '<!-- this file is generated via docker-builder/generate.pl, do not edit it directly -->';

  my (%args, $rendered);
  for my $build (sort keys $config->{releases}->%*) {
    my $release = $config->{releases}{$build};
    my $version = _first_version($release);
    my $from    = $release->{from};
    say "$build $version";

    # labels
    my @labels    = ('ARG NOW=not-set');
    my $add_label = sub ($key, $value) {
      $value = qq|"$value"| if $value =~ /\s/;
      push @labels, qq|LABEL org.opencontainers.image.$key=$value|;
    };

    chomp(my $author_name  = `git config --get user.name`);
    chomp(my $author_email = `git config --get user.email`);
    $add_label->(authors => "$author_name <$author_email>");

    $add_label->(licenses => $config->{global}{license});

    $add_label->(version => $version);
    $add_label->(created => '$NOW');

    for my $context (qw|title description|) {
      my $text = $config->{global}{$context};
      $text =~ s/\n//g;
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

    # labels for stages
    for my $stage (_all_stages($release)) {
      @labels = ('ARG NOW=not-set');
      $add_label->(created => '$NOW');
      $add_label->(version => _first_version($release, $stage));
      $args{"labels_$stage"} = join "\n", sort @labels;
    }

    for my $template (@templates) {
      $rendered = $mt->vars(1)->render_file("templates/$template->{source}", \%args);

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

# internal functions

sub _all_stages ($release, $with_base = 0) {
  return () unless _has_stages($release);
  die color_error 'base stage not found' unless $release->{versions}{base};
  my @stages;
  push @stages, 'base' if $with_base;
  push @stages, $_ for grep !/^base$/, sort keys $release->{versions}->%*;
  return @stages;
}

sub _all_versions ($release, $stage = 'base') {
  my @versions;
  if (_has_stages($release)) {
    @versions = $release->{versions}{$stage}->@*;
    for my $stage (_all_stages($release)) {
      push @versions, $release->{versions}{$stage}->@*;
    }
  } else {
    @versions = $release->{versions}->@*;
  }
  return @versions;
}

sub _first_version ($release, $stage = 'base') {
  if (_has_stages($release)) {
    return $release->{versions}{$stage}[0];
  } else {
    return $release->{versions}[0];
  }
}

sub _has_stages ($release) {
  return ref $release->{versions} eq 'HASH';
}

sub _now {
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
}

=head1 SYNOPSIS

  generate.pl OPTIONS [PATH]
    -u, --update
    -b, --build
    -t, --test
    -c, --commit
    -r, --readme
    -p, --publish
    -a, --all

=cut
