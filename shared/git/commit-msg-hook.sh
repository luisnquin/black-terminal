#!/usr/bin/env bash
# commit-msg hook: strip Cursor co-author trailer and normalize git revert subjects.
set -euo pipefail

msg_file="$1"

perl -i -0pe '
  s/^Co-authored-by: Cursor <cursoragent\@cursor\.com>\n?//gm;

  my @lines = split /\n/, $_, -1;
  if (@lines && $lines[0] =~ /^Revert "(.*)"\s*$/) {
    my $subject = $1;
    while ($subject =~ s/^(revert: )"(.+)"$/$1$2/) {}
    $subject =~ s/"+\z//;
    $lines[0] = "revert: $subject";
  }
  $_ = join "\n", @lines;

  s/\n{3,}\z/\n\n/;
' "$msg_file"
