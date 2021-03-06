#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;
use utf8;

use FindBin;
use lib "$FindBin::RealBin/lib";
use YAML qw(LoadFile);
use Path::Class qw(dir file);
use Elasticsearch();
use Elasticsearch::Bulk();
use Encode qw(decode_utf8);
use ES::Util qw(run $Opts sha_for);
use Getopt::Long;

chdir($FindBin::RealBin) or die $!;

our $URL_Base = '/guide';
our $Conf     = LoadFile('conf.yaml');
our $e        = Elasticsearch->new( nodes => $ENV{ES_HOST} );

GetOptions( $Opts, 'force', 'verbose' );

if ( !$Opts->{force} and sha_for("HEAD") eq sha_for('_index') ) {
    say "Up to date";
    exit;
}

say "Indexing docs";
index_docs();
run qw(git branch -f _index HEAD);

#===================================
sub index_docs {
#===================================
    my $dir = $Conf->{paths}{build}
        or die "Missing <paths.build> from config";
    $dir = dir($dir);

    my $index = "docs_" . time();
    $e->indices->delete( index => $index, ignore => 404 );
    $e->indices->create(
        index => $index,
        body  => {
            settings => index_settings(),
            mappings => mappings()
        }
    );

    my @docs;
    for my $book ( books( @{ $Conf->{contents} } ) ) {
        say "Indexing book: $book->{title}";
        my @docs = load_docs( $dir, $book->{prefix}, $book->{abbr},
            $book->{single} );
        my $b = Elasticsearch::Bulk->new(
            es        => $e,
            index     => $index,
            type      => 'doc',
            max_count => 0,
            max_size  => 0
        );
        $b->index(@docs);
        my $result = $b->flush;

        die join "\n", "Error indexing $book->{title}:",
            map { $_->{error} } @{ $result->{errors} }
            if $result->{errors};
    }

    my @actions = { add => { alias => 'docs', index => $index } };
    my $aliases = $e->indices->get_aliases( index => 'docs', ignore => 404 )
        || {};

    my $current;
    if ( ($current) = keys %$aliases ) {
        push @actions, { remove => { alias => 'docs', index => $current } };
    }

    $e->indices->update_aliases( body => { actions => \@actions } );
    $e->indices->delete( index => $current )
        if $current;
}

#===================================
sub load_docs {
#===================================
    my ( $dir, $prefix, $abbr, $single ) = @_;
    my $length_dir = length($dir);
    my $book_dir = $dir->subdir( $prefix, 'current' );

    my @docs;
    for my $file ( $book_dir->children ) {
        next if $file->is_dir;

        my $name = $file->basename;
        next
            if ( $name eq 'index.html' and !$single )
            || $name eq 'sense_widget.html'
            || $name !~ s/\.html$//;

        my $url = $URL_Base . substr( $file, $length_dir );

        for my $page ( load_file($file) ) {
            push @docs,
                {
                _id     => $url . $page->[0],
                _source => {
                    book  => $prefix,
                    title => $page->[1] . ' » ' . $abbr,
                    text  => $page->[2],
                    url   => $url . $page->[0],
                    path  => "/$prefix/$name",
                }
                };
        }

    }
    return @docs;
}

#===================================
sub load_file {
#===================================
    my $file = shift;
    my $text;
    eval { $text = run qw(xsltproc resources/html_to_text.xsl), $file; 1 }
        or die "Couldn't parse text in $file: $@";

    $text = decode_utf8($text);
    my ( undef, @parts ) = split /\s*^====+\s*/m, $text;

    my ( @sections, $page_title, $page );

    while (@parts) {
        my ( $id, $title ) = _parse_title( shift @parts );
        my $body = shift @parts;
        if ($page_title) {
            $title .= ' » ' . $page_title;
            $page  .= "\n\n$body";
        }
        else {
            $page_title = $title;
            $page       = $body;
        }
        next unless $id;
        push @sections, [ $id, $title, $body ];
    }
    $sections[0][0] = '';
    return @sections;
}

#===================================
sub _parse_title {
#===================================
    my $text = shift;
    $text =~ /(?:(^#\S+)?\s+)?(.+)/ or return ( undef, $text );
    return ( $1, $2 );
}

#===================================
sub books {
#===================================
    my @books;
    while ( my $next = shift @_ ) {
        if ( $next->{sections} ) {
            push @books, books( @{ $next->{sections} } );
        }
        else {
            push @books, $next;
        }
    }
    return @books;
}

#===================================
sub index_settings {
#===================================
    return {
        number_of_shards => 1,
        analysis         => {
            analyzer => {
                content => {
                    type      => 'custom',
                    tokenizer => 'standard',
                    filter    => [
                        'code',           'lowercase',
                        'keyword_repeat', 'english',
                        'unique_stem'
                    ],
                },
                shingles => {
                    type      => 'custom',
                    tokenizer => 'standard',
                    filter    => [ 'code', 'lowercase', 'shingles' ]
                },
                ngrams => {
                    type      => 'custom',
                    tokenizer => 'standard',
                    filter    => [ 'code', 'lowercase', 'stop', 'ngrams' ]
                },
                ngrams_search => {
                    type      => 'custom',
                    tokenizer => 'standard',
                    filter    => [ 'code', 'lowercase' ]
                },
            },
            filter => {
                english => {
                    type => 'stemmer',
                    name => 'english',
                },
                ngrams => {
                    type     => 'edge_ngram',
                    min_gram => 1,
                    max_gram => 20
                },
                shingles => {
                    type            => 'shingle',
                    output_unigrams => 0,
                },
                unique_stem => {
                    type                  => 'unique',
                    only_on_same_position => 1,
                },
                code => {
                    type => "pattern_capture",
                    patterns =>
                        [ '(\p{Ll}+|\p{Lu}\p{Ll}+|\p{Lu}+)', '(\d+)' ],
                }
            }
        }
    };
}

#===================================
sub mappings {
#===================================
    return {
        doc => {
            properties => {
                book => {
                    type   => 'string',
                    fields => {
                        raw => { type => 'string', index => 'not_analyzed' }
                    }
                },
                title => {
                    type     => 'string',
                    analyzer => 'content',
                    fields   => {
                        shingles => {
                            type     => 'string',
                            analyzer => 'shingles',
                        },
                        ngrams => {
                            type            => 'string',
                            index_analyzer  => 'ngrams',
                            search_analyzer => 'ngrams_search'
                        }
                    }
                },
                text => {
                    type     => 'string',
                    analyzer => 'content',
                    fields   => {
                        shingles => {
                            type     => 'string',
                            analyzer => 'shingles'
                        },
                        ngrams => {
                            type            => 'string',
                            index_analyzer  => 'ngrams',
                            search_analyzer => 'ngrams_search'
                        }
                    }
                },
                path => {
                    type  => 'string',
                    index => 'not_analyzed',
                }
            }
        }
    };
}

#===================================
sub usage {
#===================================
    say <<USAGE;

    Index all generated HTML docs in the build directory

        $0 [opts]

        Opts:
          --force           Reindex the docs even if already up to date
          --verbose

USAGE
}
