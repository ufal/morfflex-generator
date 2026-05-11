#!/usr/bin/perl

# This file is part of MorfFlex <https://github.com/ufal/morfflex-generator>.
#
# Copyright 2026 Institute of Formal and Applied Linguistics, Faculty of
# Mathematics and Physics, Charles University in Prague, Czech Republic.
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use warnings;
use strict;
use open qw{:std :utf8};
use utf8;

use Storable qw(dclone);
use Unicode::Collate;
my $uc = Unicode::Collate->new();

my @addinfo = (
  [':', {}], # Categories
  [';', {E=>1,G=>1,H=>1,K=>1,L=>1,m=>1,o=>1,R=>1,S=>1,U=>1,Y=>1}], # Terms
  [',', {a=>1,e=>1,h=>1,i=>1,l=>1,n=>1,s=>1,t=>1,v=>1,x=>1}], # Styles
);
use constant CATEGORY_DELIMITER => ':';
use constant TERM_DELIMITER => ';';
use constant STYLE_DELIMITER => ',';

@ARGV >= 9 or die "Usage: $0 taglist_file dist_file exp_file end_file dtypes_file dictionary_file neg_prefix grad_prefix gradneg_prefix [join_on_forms]\n";
my $taglist_file = shift @ARGV;
my $dist_file = shift @ARGV;
my $exp_file = shift @ARGV;
my $end_file = shift @ARGV;
my $dtypes_file = shift @ARGV;
my $dictionary_file = shift @ARGV;
my $neg_prefix = shift @ARGV;
my $grad_prefix = shift @ARGV;
my $gradneg_prefix = shift @ARGV;
my $join_on_forms = @ARGV ? shift @ARGV : 0;

# Error logging
my %stderr_lines;
sub print_stderr_uniq($) { my ($line) = @_; return if exists $stderr_lines{$line}; $stderr_lines{$line} = 1; print STDERR $line; }

# Tag wildcard expand
sub expand_wildcard {
  my ($wildcard) = @_;
  return ($wildcard) unless $wildcard =~ /\[/;
  die "Missing ] in the tag wildcard $wildcard" unless $wildcard =~ /^([^[]*)\[([^]]*)\](.*)$/;
  my ($prefix, $suffix_wildcard, @middle, @results) = ($1, $3, split(//, $2));
  foreach my $suffix (expand_wildcard($suffix_wildcard)) {
    foreach my $middle (@middle) {
      push @results, $prefix . $middle . $suffix;
    }
  }
  return @results;
}

# 1) read allowed tags from $taglist_file, every line contains tag wildcard.
my %tagmap;
open (my $tagmap, "<", $taglist_file) or die "Cannot open file $taglist_file: $!";
while (<$tagmap>) {
  chomp;
  foreach my $tag (expand_wildcard($_)) {
    $tagmap{$tag} = 1;
  }
}
close $tagmap;
sub tagcheck($$) {
  my ($tag, $negatiable) = @_;

  my $tagA = $tag; $tagA =~ s/@/A/;
  my $tagA2 = $tagA; $tagA2 =~ s/#/2/;
  if ($tagA2 eq $tag) {
    die "Unknown tag $tag" if not exists $tagmap{$tag};
    return;
  }
  die "Unknown tag $tag (filled as $tagA2)" if not exists $tagmap{$tagA2};
  if ($tagA =~ /#/) {
    my $tagA3 = $tagA; $tagA3 =~ s/#/3/;
    die "Unknown tag $tag (filled as $tagA3)" if not exists $tagmap{$tagA3};
  }
  if ($tag =~ /@/ && $negatiable) {
    my $tagN = $tag; $tagN =~ s/@/N/;
    my $tagN2 = $tagN; $tagN2 =~ s/#/2/;
    die "Unknown tag $tag (filled as $tagN2)" if not exists $tagmap{$tagN2};
    if ($tagN =~ /#/) {
      my $tagN3 = $tagN; $tagN3 =~ s/#/3/;
      die "Unknown tag $tag (filled as $tagN3)" if not exists $tagmap{$tagN3};
    }
  }
}

# 2) read derivations from $dist_file.
# Line can be commented with #. Otherwise, the line is in format
#   pat rootadd,derivedPat,lemmaBase,lemmaAdd,refLemmaBase,refLemmaAdd,dir
# where pat is ascii string
#       rootAdd is string, 0 represents empty string
#       derivedPat is ascii string
#       lemmaBase is r?\d+, which takes original lemma (or root if r is present)
#         and removes specified number of characters from the end
#       lemmaAdd is appended to lemmaBase, 0 represents empty string
#       refLemmaBase is r?\d+, which takes original lemma (or root if r is present)
#         and removes specified number of characters from the end
#       refLemmaAdd is appended to lemmaBase, 0 represents empty string
# We ignore dir.
my %dist;
open (my $dist, "<", $dist_file) or die "Cannot open file $dist_file: $!";
while (<$dist>) {
  chomp;
  next if /^#/;
  /^(\w+)\s+(\w+),(\w+),(r?)(\d+),([\w+@]+),(r?)(\d+),([\w+@]+),[-*]$/ or die "Bad line '$_' in $dist_file";
  my ($pat, $rootAdd, $derivedPat, $lemmaBase, $lemmaRemove, $lemmaAdd, $refLemmaBase, $refLemmaRemove, $refLemmaAdd) =
    ($1, $2 eq '0' ? '' : $2, $3, $4, $5, $6 eq '0' ? '' : $6, $7, $8, $9 eq '0' ? '' : $9);
  push @{$dist{$pat}}, {rootAdd=>$rootAdd, derivedPat=>$derivedPat, lemmaBase=>$lemmaBase, lemmaRemove=>$lemmaRemove, lemmaAdd=>$lemmaAdd,
                        refLemmaBase=>$refLemmaBase, refLemmaRemove=>$refLemmaRemove, refLemmaAdd=>$refLemmaAdd};
}
close $dist;

# 3) read categories from $exp_file.
# The file contains descriptions of categories, terms and styles.
# We only read categories, which end by a line ">STYLE" or ">SEM".
# The file consists of blocks, beginning by a line starting at first column:
#   category_(category_description)
# The following lines start with space and contain space separated patterns.
my %cats;
my $cat_current = "";
open (my $cats, "<", $exp_file) or die "Cannot open file $exp_file: $!";
while (<$cats>) {
  /^>(STYLE|SEM)$/ and last;
  if (/^\S/) {
    /^(\w+)_\([^)]*\)$/ or die "Bad line '$_' in $exp_file";
    $cat_current = $1;
  } else {
    length $cat_current or die "Line '$_' in $exp_file does not belong to any category";
    s/^\s*//;
    my @pats = split /\s+/;
    foreach my $pat (@pats) {
      die "Repeated category pattern $pat in $exp_file" if exists $cats{$pat};
      $cats{$pat} = $cat_current;
    }
  }
}
close $cats;

# 4) read endings from $end_file.
# File consists of blocks, beginning by a line starting at first column:
#   pat
# The rest of the line and following lines contain comma separated
#   ending[tags]
# where ending is \+?\w+, where initial plus indicates ending is for both comparative and superlative
#       tags are comma separated tags, possibly containing @ and #.
# At one point, the following line appears
#   >NEG
# The patterns defined before do not allow negations,
# atterns defined after this line allow negations.
my %ends;
my $end_negatiable = 0;
my $end_current = "";
open (my $ends, "<", $end_file) or die "Cannot open file $end_file: $!";
while (<$ends>) {
  chomp;
  /^>NEG\s*$/ and $end_negatiable = 1 and next;
  if (/^\S/) {
    s/^(\w+)(?:\s|$)// or die "Bad line '$_' in $end_file";
    $end_current = $1;
  }
  length $end_current or die "Line '$_' in $end_file does not belong to any pattern";
  $ends{$end_current} = {negatiable=>$end_negatiable, lines=>''} unless exists $ends{$end_current};
  $ends{$end_current}->{lines} .= " $_";
}
close $ends;

foreach my $pat (sort keys %ends) {
  my $lines = $ends{$pat}->{lines};
  while ($lines =~ s/^\s*(\+?)([^[]*)\[(.*?)]\s*(?:,|$)//) {
    my ($ending, $comparative, @tags) = ($2 eq '0' ? '' : $2, $1 eq '+', split /,/, $3);
    $ending =~ /^\w*$/ or die "Bad ending '$ending' in $end_file";
    foreach my $wildcard (@tags) {
      foreach my $tag (expand_wildcard($wildcard)) {
        $tag =~ s/^\s*(.*?)\s*$/$1/;
        die "Tag '$tag' expected to contain # because it belongs to +$ending" if $comparative and $tag !~ /#/;
        die "Tag '$tag' not expected to contain # because it belongs to $ending" if !$comparative and $tag =~ /#/;
        tagcheck($tag, $ends{$pat}->{negatiable});
        push @{$ends{$pat}->{endings}->{$ending}}, $tag;
      }
    }
  }
  $lines =~ /^\s*$/ or die "Cannot parse endings near '$lines' of pattern $pat in $end_file";
}

# 5) read derivational comment types and their visibility
my %dtypes;
open (my $dtypes, "<", $dtypes_file) or die "Cannot open file $dtypes_file: $!";
while (<$dtypes>) {
  chomp;
  s/^\s*//;
  s/\s*(?:#.*)$//;
  /^$/ and next;
  my @parts = split /\s+/;
  @parts == 2 or die "Line '$_' in $dtypes_file does not have two columns";
  my ($dtype, $visibility) = @parts;
  $visibility eq "hidden" or $visibility eq "visible_noninheritable" or $visibility eq "visible_inheritable" or
    die "Unknown visibility level '$visibility' in file $dtypes_file";
  $dtypes{$dtype} = $visibility;
}
close $dtypes;

my %dtypes_visibility_re;
foreach my $visibility (qw(hidden visible_noninheritable visible_inheritable)) {
  $dtypes_visibility_re{$visibility} = join("|", map(quotemeta, grep {$dtypes{$_} eq $visibility} keys(%dtypes)));
}

# Helper methods
sub rstrip($$) { my ($str, $n) = @_; return $n > 0 ? substr($str, 0, -$n) : $str; }
sub derivation($$$$) { my ($ori, $new, $type, $mode) = @_; return sprintf "(%s**%s)", $type, $ori if $mode eq "abs"; my $i = 0; while (substr($ori, 0, $i+1) eq substr($new, 0, $i+1)) {$i++;}; return sprintf "(%s*%d%s)", $type, length($new) - $i, substr($ori, $i); }
sub apply_without_sense($$$) { my ($lemma, $remove, $append) = @_; my $sense = ""; $lemma =~ s/(?<=.)-[0-9]+$// and $sense = $&; return rstrip($lemma, $remove) . $append . $sense; }

# 6) read dictionary and generate lemmas using %dist.
# Line can be commented with #. Otherwise, the line has format
#   root pat =megalemma
# where root is $formchars+ for $formchars defined later
#       megalemma has the following structure:
#         lemma`reflemma+tagscomments
#         where lemma and reflemma is $formchars+(-\d+)?
#               tags are / separated tags
#               comments are sequence of _[[:alpha:]] and _(...)
# The file contains &mikro; and &amp; entities, which we manually decode.

# Start by reading the dictionary and computing "correct" root if we have
# multiple variants marked with various style addinfo comments.
my (%correct_roots, @manual_derivation_targets);
my $comment_any_style;
foreach my $addinfo (@addinfo) { $comment_any_style = '_['.join('', keys %{$addinfo->[1]}).']' if $addinfo->[0] eq STYLE_DELIMITER; }

my $formchars = '[-.´\§[:alpha:][:digit:]]';
my @dict;
open (my $dict, "<", $dictionary_file) or die "Cannot open file $dictionary_file: $!";
while (<$dict>) {
  chomp;
  next if /^#/;

  s/&mikro;/μ/g;
  s/&amp;/&/g;

  /^($formchars+)\s+(\w+)\s+=\s*(\S+)\s*$/ or die "Bad line '$_' in $dictionary_file";
  my ($root, $pat, $megalemma) = ($1, $2, $3);

  my ($tags_re, $comments_re) = ('(?:\+([^_]+))', '((?:_[a-zA-Z]|_(\((?>[^()]|(?-1))*\)))+)');
  $megalemma =~ /^($formchars+?)(-\d+)?(`$formchars+)?$comments_re?$tags_re?$comments_re?$/ or die "Cannot parse lemma '$megalemma' in $dictionary_file";
  my ($lemma, $sense, $reflemma, $tags, $comments) = ($1, $2 ? $2 : '', $3 ? $3 : '', $6 ? $6 : '', ($4 ? $4 : '') . ($7 ? $7 : ''));
  die "Lemma '$lemma' contain dash followed by number" if $lemma =~ /-[0-9]/;
  die "Pattern '$pat' not present in $dist_file" unless exists $dist{$pat};
  die "Lemma '$lemma' has pattern '$pat' with multiple derivations but manually specified tags" if length $tags && @{$dist{$pat}} > 1;

  # Parse manual derivation comments and store the targets
  my $comments_copy = $comments;
  while ($comments_copy =~ s/_(\(((?:\^[^^*)]*)?\*)(\*|\d+)([^)]*)\))//) {
    my ($derivation, $dtype, $remove, $append) = ($1, $2, $3, $4);

    if (not exists $dtypes{$dtype}) {
      $comments =~ s/\Q_$derivation//g;
      print_stderr_uniq "Unknown type in derivational comment $derivation for lemma $lemma.\n";
    }

    my $target = $lemma.$sense;
    $target = ($remove eq "*" ? "" : rstrip($target, $remove)) . $append;
    push @manual_derivation_targets, [$lemma.$sense, $derivation, $target];
  }

  # Remove derivational commens with type of visibility hidden
  $comments =~ s/_\((?:$dtypes_visibility_re{hidden})(?:[*]|[0-9]+)[^)]*\)//g;

  push @dict, [$root, $pat, $lemma, $sense, $reflemma, $tags, $comments];

  # Fill %correct_roots map
  if (!length $tags && $comments !~ /$comment_any_style/) {
    my $key = "$lemma $sense $pat";
    if (!exists $correct_roots{$key} || $correct_roots{$key} eq $root) {
      $correct_roots{$key} = $root;
    } else {
      $correct_roots{$key} = "";
    }
  }
}
close $dict;

# Generate all derivations
my (%dict, %original_lemmas);
foreach my $entry (@dict) {
  my ($root, $pat, $lemma, $sense, $reflemma, $tags, $comments) = @$entry;

  # Get the "correct" root for generating derived lemma
  my $correct_root = $root;
  if (!length $tags && $comments =~ /$comment_any_style/) {
    my $key = "$lemma $sense $pat";
    if ($correct_roots{$key}) {
      $correct_root = $correct_roots{$key};
    }
  }
  print_stderr_uniq "Changing root for derivations from $root to $correct_root.\n" if $correct_root ne $root;

  foreach my $dist (@{$dist{$pat}}) {
    my ($groot, $gpat, $glemma, $grefLemma) = ($root.$dist->{rootAdd}, $dist->{derivedPat},
                                               rstrip($dist->{lemmaBase} eq 'r' ? $correct_root : $lemma, $dist->{lemmaRemove}).$dist->{lemmaAdd},
                                               rstrip($dist->{refLemmaBase} eq 'r' ? $correct_root : $lemma, $dist->{refLemmaRemove}).$dist->{refLemmaAdd});
    die "Pattern '$gpat' not present in $end_file" unless exists $ends{$gpat};
    my $is_derivation = $grefLemma ne $glemma;
    my $negatiable = $ends{$gpat}->{negatiable};

    my @ending_keys = keys(%{$ends{$gpat}->{endings}});
    die "Explicit tags are used for lemma $glemma, but $gpat has more than one ending" if length($tags) && @ending_keys != 1;
    my $endings = $ends{$gpat}->{endings};
    if (length $tags) {
      my @tags = ();
      foreach my $wildcard (split /\//, $tags) {
        foreach my $tag (expand_wildcard($wildcard)) {
          tagcheck($tag, $ends{$gpat}->{negatiable});
          push @tags, $tag;
        }
      }
      $endings = {$ending_keys[0]=>[@tags]};
    }
    my $gcomments = $comments;
    $gcomments .= "_$cats{$gpat}" if exists $cats{$gpat};
    if ($is_derivation) {
      # Remove semantic comments
      $gcomments =~ s/_\([^^][^)]*\)//g;

      # Remove style comments
      while ($gcomments =~ s/((?:^|[)])[^(]*)$comment_any_style/$1/g) {}

      # Remove derivational commens with type of visibility visible_noninheritable.
      $gcomments =~ s/_\((?:$dtypes_visibility_re{visible_noninheritable})(?:[*]|[0-9]+)[^)]*\)//g;

      # Derivate the links to variants
      if ($gcomments =~ /_\(\^/) {
        my $same = 0;
        while ($same < length($lemma) && $same < length($glemma) && substr($lemma, $same, 1) eq substr($glemma, $same, 1)) { $same++; }
        my ($remove, $append) = (length($lemma) - $same, substr($glemma, $same));
        $gcomments =~ s/_\((\^[^*)]*)[*]([*]|[0-9]+)([^)]*)\)/"_" . derivation(apply_without_sense($2 eq "*" ? $3 : rstrip($lemma, $2) . $3, $remove, $append), $glemma, $1, $2 eq "*" ? "abs" : "rel")/ge;
      }

      # Append automatically generated derivational comment.
      $gcomments .= "_".derivation($grefLemma.$sense, $glemma.$sense, "", "rel") if $grefLemma ne $glemma;
    }

    $original_lemmas{$glemma.$sense} = 1;
    push @{$dict{$glemma}->{$sense}}, {root=>$groot, endings=>$endings, reflemma=>$reflemma, orilemma=>$grefLemma.$sense, comments=>$gcomments,
                                       pat=>length $tags ? '' : $gpat, is_derivation=>$is_derivation, negatiable=>$negatiable};
  }
}

# Check that manual derivation targets exist
for my $manual_derivation (@manual_derivation_targets) {
  my ($lemma, $derivation, $target) = @{$manual_derivation};
  next if exists $original_lemmas{$target};
  print_stderr_uniq "Manual derivational comment target $target of $lemma generated using $derivation does not exist.\n";
}

# 6) generate resulting dictionary

# Start by merging lemmas with different sense, if they have the same set of form-tag pairs.
# In such situations, keep the smaller sense (with no explicit sense being the smaller).
my (%merged_dict, %resense_map) = ();
foreach my $lemma ($uc->sort(keys %dict)) {
  my @senses = sort {($a ? int(substr($a, 1)) : -1) <=> ($b ? int(substr($b, 1)) : -1)} keys(%{$dict{$lemma}});
  if (@senses == 1) {
    $merged_dict{$lemma.$senses[0]} = $dict{$lemma}->{$senses[0]};
  } else {
    my %paradigms = ();
    foreach my $sense (@senses) {
      my %tagforms = ();
      foreach my $info (@{$dict{$lemma}->{$sense}}) {
        my $endings = $info->{endings};
        foreach my $ending (sort(keys %{$endings})) {
          my $form = $info->{root} . $ending;
          foreach my $tag (@{$endings->{$ending}}) {
            my $tagA = $tag; $tagA =~ s/@/A/;
            my $tagA2 = $tagA; $tagA2 =~ s/#/2/;
            $tagforms{"$tagA2\t$form"} = 1;
            if ($tagA =~ /#/) {
              my $tagA3 = $tagA; $tagA3 =~ s/#/3/;
              $tagforms{"$tagA3\t$form"} = 1;
            }
            if ($tag =~ /@/ && $info->{negatiable}) {
              my $tagN = $tag; $tagN =~ s/@/N/;
              my $tagN2 = $tagN; $tagN2 =~ s/#/2/;
              $tagforms{"$tagN2\t$form"} = 1;
              if ($tagN =~ /#/) {
                my $tagN3 = $tagN; $tagN3 =~ s/#/3/;
                $tagforms{"$tagN3\t$form"} = 1;
              }
            }
          }
        }
      }
      my $has_nonbn = 0; foreach my $tagform (keys(%tagforms)) { $has_nonbn = 1 if substr($tagform, 0, 2) ne "BN"; }
      my $paradigm = join("\n", sort {$a cmp $b} keys(%tagforms));
      if ($has_nonbn && exists $paradigms{$paradigm}) {
        my $target = $paradigms{$paradigm};
        $resense_map{$lemma.$sense} = $target;
        foreach my $info (@{$dict{$lemma}->{$sense}}) {
          $info->{comments} =~ s/_\(([^*)]*)[*]([*]|[0-9]+)([^)]*)\)/"_" . derivation($2 eq "*" ? $3 : rstrip($lemma.$sense, $2) . $3, $target, $1, $2 eq "*" ? "abs" : "rel")/ge;
        }
        push @{$merged_dict{$target}}, @{$dict{$lemma}->{$sense}};
        my $lemmasense_origin = $dict{$lemma}->{$sense}->[0]->{is_derivation} ? " (from $dict{$lemma}->{$sense}->[0]->{orilemma})" : "";
        my $target_origin = $merged_dict{$target}->[0]->{is_derivation} ? " (from $merged_dict{$target}->[0]->{orilemma})" : "";
        print_stderr_uniq "Resense $lemma$sense$lemmasense_origin to $target$target_origin\n";
      } else {
        $merged_dict{$lemma.$sense} = $dict{$lemma}->{$sense};
        $paradigms{$paradigm} = $lemma.$sense;
      }
    }
  }
}

# This is a bit tricky, because we need to merge multiple lemmas.
sub join_comments($) {
  my ($info) = @_;
  my $comments = $info->{comments};
  $comments->{txt} = '';

  # Generate Categories, Terms and Styles
  foreach my $addinfo (@addinfo) {
    my $delimiter = $addinfo->[0];
    foreach my $comment (sort keys %{$comments->{$delimiter}}) {
      $comments->{txt} .= "_$delimiter$comment"
    }
  }

  # Add general comments and derivations in parentheses
  my @parens = keys %{$comments->{parens}};
  if (@parens == 1) {
    $comments->{txt} .= "_^$parens[0]";
  } elsif (@parens > 1) {
    my @keys = ();
    foreach my $paren (@parens) {
      if ($paren =~ /^\(\*\*?([0-9]*)/) { push @keys, ["3", $1 || 0, $paren] }
      elsif ($paren =~ /^\((\^?[^^*)]*)\*\*?([0-9]*)/) { push @keys, ["2".$1, $2 || 0, $paren] }
      else { push @keys, ["1", 0, $paren]}
    }
    @keys = sort {($a->[0] cmp $b->[0]) || ($a->[1] <=> $b->[1]) || ($uc->cmp($a->[2], $b->[2]))} @keys;
    $comments->{txt} .= "_^" . join("_", map {$_->[2]} @keys);
  }
}

foreach my $lemma ($uc->sort(keys %merged_dict)) {
  my @infos;

  # Start by generating relevant comments.
  foreach my $info (@{$merged_dict{$lemma}}) {
    my ($comments, @comments) = ($info->{comments});

    # Remap derivations using resense_map
    $comments =~ s/_\(([^*)]*)[*]([*]|[0-9]+)([^)]*)\)/exists $resense_map{$2 eq "*" ? $3 : rstrip($lemma, $2) . $3} ? "_" . derivation($resense_map{$2 eq "*" ? $3 : rstrip($lemma, $2) . $3}, $lemma, $1, $2 eq "*" ? "abs" : "rel") : $&/ge;

    while (length $comments) {
      $comments =~ s/^_([[:alpha:]]|\([^)]*\))// or die "Cannot parse comments $comments";
      push @comments, $1;
    }
    $info->{comments} = {};
    # add Category, Term and Style allowed in @addinfo
    foreach my $addinfo (@addinfo) {
      my ($delimiter, $chars) = @$addinfo;
      $info->{comments}->{$delimiter} = {};
      foreach my $comment (@comments) {
        next unless exists $chars->{$comment};
        $info->{comments}->{$delimiter}->{$comment} = 1;
      }
    }
    # add general and derivation comments
    $info->{comments}->{parens} = {};
    foreach my $comment (@comments) {
      next if $comment !~ /^\(/ or $comment =~ /^\(_/;
      $info->{comments}->{parens}->{$comment} = 1;
    }
    join_comments($info);
    push @infos, $info;
  }

  # If there is only one element in @infos, we can print the results early.
  # This is merely an optimalization, because in most cases there is only one @info
  # and we avoid various rehashing in this case.
  if (@infos == 1) {
    my $info = $infos[0];
    my $complete_lemma = $lemma.$info->{reflemma}.$info->{comments}->{txt};
    my $endings = $info->{endings};
    my @tagforms = ();
    foreach my $ending (sort(keys %{$endings})) {
      my $form = $info->{root} . $ending;
      foreach my $tag (@{$endings->{$ending}}) {
        my $tagA = $tag; $tagA =~ s/@/A/;
        my $tagA2 = $tagA; $tagA2 =~ s/#/2/;
        push @tagforms, $tagA2."\t$form";
        if ($tagA =~ /#/) {
          my $tagA3 = $tagA; $tagA3 =~ s/#/3/;
          push @tagforms, $tagA3."\t$grad_prefix$form";
        }
        if ($tag =~ /@/ && $info->{negatiable}) {
          my $tagN = $tag; $tagN =~ s/@/N/;
          my $tagN2 = $tagN; $tagN2 =~ s/#/2/;
          push @tagforms, $tagN2."\t$neg_prefix$form";
          if ($tagN =~ /#/) {
            my $tagN3 = $tagN; $tagN3 =~ s/#/3/;
            push @tagforms, $tagN3."\t$gradneg_prefix$form";
          }
        }
      }
    }

    foreach my $tagform (sort(@tagforms)) {
      print "$complete_lemma\t$tagform\n";
    }
    next;
  }

  # Generate all form-tags (or forms only when join_on_forms)
  my %maybetag_forms;
  foreach my $info (@infos) {
    my $endings = $info->{endings};
    foreach my $ending (sort(keys %{$endings})) {
      my $form = $info->{root} . $ending;
      foreach my $tag (@{$endings->{$ending}}) {
        my $tagA = $tag; $tagA =~ s/@/A/;
        my $tagA2 = $tagA; $tagA2 =~ s/#/2/;
        $maybetag_forms{($join_on_forms?'':$tagA2)."\t$form"}->{tags}->{$tagA2} = 1;
        push @{$maybetag_forms{($join_on_forms?'':$tagA2)."\t$form"}->{infos}}, $info;
        if ($tagA =~ /#/) {
          my $tagA3 = $tagA; $tagA3 =~ s/#/3/;
          $maybetag_forms{($join_on_forms?'':$tagA3)."\t$grad_prefix$form"}->{tags}->{$tagA3} = 1;
          push @{$maybetag_forms{($join_on_forms?'':$tagA3)."\t$grad_prefix$form"}->{infos}}, $info;
        }
        if ($tag =~ /@/ && $info->{negatiable}) {
          my $tagN = $tag; $tagN =~ s/@/N/;
          my $tagN2 = $tagN; $tagN2 =~ s/#/2/;
          $maybetag_forms{($join_on_forms?'':$tagN2)."\t$neg_prefix$form"}->{tags}->{$tagN2} = 1;
          push @{$maybetag_forms{($join_on_forms?'':$tagN2)."\t$neg_prefix$form"}->{infos}}, $info;
          if ($tagN =~ /#/) {
            my $tagN3 = $tagN; $tagN3 =~ s/#/3/;
            $maybetag_forms{($join_on_forms?'':$tagN3)."\t$gradneg_prefix$form"}->{tags}->{$tagN3} = 1;
            push @{$maybetag_forms{($join_on_forms?'':$tagN3)."\t$gradneg_prefix$form"}->{infos}}, $info;
          }
        }
      }
    }
  }

  # Merge the infos for every form-tag (or form if join_on_forms)
  my %lemmas;
  for my $maybetag_form (sort(keys %maybetag_forms)) {
    my $taginfos = $maybetag_forms{$maybetag_form};

    my $form = (split /\t/, $maybetag_form)[1];
    my $infos = $taginfos->{infos};
    if (@$infos > 1) {
      # Merge the lemma infos
      my $info = dclone($infos->[0]);
      for (my $i = 1; $i < @$infos; $i++) {
        my $other = $infos->[$i];

        # Merge reflemma
        if ($info->{reflemma} ne $other->{reflemma}) {
          if (!length($info->{reflemma})) { $info->{reflemma} = $other->{reflemma}; }
          elsif (!length($other->{reflemma})) {}
          else {
            my $log_msg = "Two different reflemmas '$info->{reflemma}' and '$other->{reflemma}' for lemma '$lemma', ";
            $info->{reflemma} = $other->{reflemma} if $other->{reflemma} < $info->{reflemma};
            print_stderr_uniq $log_msg . "keeping '$info->{reflemma}'.\n";
          }
        }

        # Intersect general comments
        foreach my $paren (keys %{$info->{comments}->{parens}}) {
          next if $paren =~ /^\([*^]/;
          next if exists $other->{comments}->{parens}->{$paren};
          print_stderr_uniq "Removing comment $paren when merging $lemma$info->{comments}->{txt} and $lemma$other->{comments}->{txt}\n";
          delete $info->{comments}->{parens}->{$paren};
        }
        foreach my $paren (keys %{$other->{comments}->{parens}}) {
          next if $paren =~ /^\([*^]/;
          next if exists $info->{comments}->{parens}->{$paren};
          print_stderr_uniq "Removing comment $paren when merging $lemma$info->{comments}->{txt} and $lemma$other->{comments}->{txt}\n";
        }

        # Union derivations
        foreach my $paren (keys %{$other->{comments}->{parens}}) {
          next if $paren !~ /^\([*^]/;
          $info->{comments}->{parens}->{$paren} = 1;
        }

        # Report we could append _(*0) if there are infos with both values for is_derivation.
        if (($info->{is_derivation} ne $other->{is_derivation}) and (not exists $info->{comments}->{parens}->{"(*0)"})) {
          $info->{comments}->{parens}->{"(*0)"} = 1;
          print_stderr_uniq "Possible (*0) when merging $lemma$info->{comments}->{txt} and $lemma$other->{comments}->{txt}\n";
        }

        # Merge categories, either using union or intersect
        foreach my $addinfo (@addinfo) {
          my ($delimiter, $chars) = @$addinfo;
          if ($delimiter eq CATEGORY_DELIMITER || $delimiter eq TERM_DELIMITER) {
            # Union
            foreach my $comment (keys %{$other->{comments}->{$delimiter}}) {
              $info->{comments}->{$delimiter}->{$comment} = 1;
            }
          } elsif ($delimiter eq STYLE_DELIMITER) {
            # Intersection
            foreach my $comment (keys %{$info->{comments}->{$delimiter}}) {
              next if exists $other->{comments}->{$delimiter}->{$comment};
              print_stderr_uniq "Removing style label $comment when merging $lemma$info->{comments}->{txt} and $lemma$other->{comments}->{txt}\n";
              delete $info->{comments}->{$delimiter}->{$comment};
            }
            foreach my $comment (keys %{$other->{comments}->{$delimiter}}) {
              next if exists $info->{comments}->{$delimiter}->{$comment};
              print_stderr_uniq "Removing style label $comment when merging $lemma$info->{comments}->{txt} and $lemma$other->{comments}->{txt}\n";
            }
          }
        }
      }

      # At present, inhibit _^(*0).
      if (exists $info->{comments}->{parens}->{"(*0)"}) {
        delete $info->{comments}->{parens}->{"(*0)"};
      }

      join_comments($info);
      @$infos = ($info);
    }
    my $complete_lemma = $lemma.$infos->[0]->{reflemma}.$infos->[0]->{comments}->{txt};
    foreach my $tag (keys %{$taginfos->{tags}}) {
      push @{$lemmas{$complete_lemma}}, "$tag\t$form";
    }
  }

  # Print out lemma-tag-form
  foreach my $lemma ($uc->sort(keys %lemmas)) {
    foreach my $tagform (sort(@{$lemmas{$lemma}})) {
      print "$lemma\t$tagform\n";
    }
  }
} continue {
  delete $dict{$lemma};
}
