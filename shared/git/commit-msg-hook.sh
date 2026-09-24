#!/usr/bin/env bash
# commit-msg hook: strip agent trailers, normalize git revert subjects, refuse em dashes.
set -euo pipefail

msg_file="$1"

perl -i -0pe '
  s/^Co-authored-by: Cursor <cursoragent\@cursor\.com>\n?//gm;
  s/^Claude-Session: \S+\n?//gm;
  s/^Co-Authored-By: Claude\b[^\n]*<noreply\@anthropic\.com>\n?//gmi;
  s/^🤖 Generated with \[Claude Code\][^\n]*\n?//gm;

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

dashed=$(perl -ne 'last if /^# -+ >8 -+$/; next if /^#/; print "  $.: $_" if /\xE2\x80\x94/' "$msg_file")

[ -z "$dashed" ] && exit 0

{
    printf '\nem dash in commit message - commit refused\n\n%s\n\n' "$dashed"
    printf 'Rewrite it with a comma, a colon, parentheses, or a new sentence.\n'
} >&2

exit 1
