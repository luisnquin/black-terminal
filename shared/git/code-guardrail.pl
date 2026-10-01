#!/usr/bin/env perl
# code-guardrail: refuse commits whose added code breaks a named policy.
use strict;
use warnings;

my $MODE = shift @ARGV || 'pre-commit';
my $GIT = $ENV{CODE_GUARDRAIL_GIT} || 'git';

exit 0 if lc($ENV{CODE_GUARDRAIL} || '') =~ /^(off|0|no|skip)$/;

my $EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

sub git {
    my @cmd = @_;
    my $pid = open(my $fh, '-|');
    return undef unless defined $pid;
    unless ($pid) {
        open(STDERR, '>', '/dev/null');
        exec($GIT, @cmd);
        exit 127;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return $? == 0 ? $out : undef;
}

sub lex_rust {
    my ($content) = @_;
    my ($depth, $string, @lines) = (0, undef);

    for my $text (split /\n/, $content, -1) {
        my ($code, $comment, $i, $n) = ('', '', 0, length $text);

        while ($i < $n) {
            my $two = substr($text, $i, 2);

            if ($depth) {
                $depth += $two eq '/*' ? 1 : $two eq '*/' ? -1 : 0;
                my $step = ($two eq '/*' || $two eq '*/') ? 2 : 1;
                $comment .= substr($text, $i, $step);
                $i += $step;
                next;
            }

            if ($string) {
                my $c = substr($text, $i, 1);
                my $hashes = '#' x ($string->{raw} // 0);
                if (!defined $string->{raw} && $c eq '\\') {
                    $i += 2;
                } elsif ($c eq '"' && substr($text, $i + 1, length $hashes) eq $hashes) {
                    $i += 1 + length $hashes;
                    $code .= '""';
                    $string = undef;
                } else {
                    $i++;
                }
                next;
            }

            my $rest = substr($text, $i);
            my $fresh = $i == 0 || substr($text, $i - 1, 1) !~ /\w/;

            if ($two eq '//') {
                $comment .= $rest;
                last;
            }
            if ($two eq '/*') {
                ($depth, $i) = (1, $i + 2);
                $comment .= '/*';
                next;
            }
            if ($fresh && $rest =~ /^([bc]?r(#*)")/) {
                $string = {raw => length $2};
                $i += length $1;
                next;
            }
            if (($fresh && $rest =~ /^([bc]?")/) || $rest =~ /^(")/) {
                $string = {};
                $i += length $1;
                next;
            }
            if ($rest =~ /^('(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^\\'])')/) {
                $code .= "''";
                $i += length $1;
                next;
            }

            $code .= substr($text, $i, 1);
            $i++;
        }

        push @lines, {code => $code, comment => $comment};
    }

    return \@lines;
}

sub justified {
    my ($lines, $at) = @_;
    my $marker = qr{\bSAFETY:|^\s*//[/!]\s*#\s*Safety\b};

    return 1 if $lines->[$at]{comment} =~ $marker;

    for (my $k = $at - 1; $k >= 0; $k--) {
        my ($code, $comment) = @{$lines->[$k]}{qw(code comment)};
        if ($code !~ /\S/ && length $comment) {
            return 1 if $comment =~ $marker;
            next;
        }
        next if $code =~ /^\s*#!?\[/;
        return 0;
    }
    return 0;
}

sub rust_unsafe {
    my ($content, $added) = @_;
    my $lines = lex_rust($content);
    my @found;

    for my $lineno (@$added) {
        my $line = $lines->[$lineno - 1] or next;
        next unless $line->{code} =~ /\bunsafe\b/;
        next if justified($lines, $lineno - 1);
        push @found, $lineno;
    }
    return @found;
}

my @POLICIES = (
    {
        name    => 'rust-unsafe-policy',
        applies => qr{\.rs$},
        check   => \&rust_unsafe,
        title   => 'unsafe without a SAFETY comment',
        advice  => [
            "Before keeping an unsafe, ask another subagent to evaluate a safe",
            "alternative, architecture changes included when they fit. If the",
            "alternative is simple, preserves behavior and adds no relevant cost,",
            "implement it directly. If it needs major architecture, performance or",
            "scope changes, present the proposal and ask the user before implementing it.",
            "",
            "When the unsafe stays, put a // SAFETY: comment directly above it, 2-3",
            "lines naming the invariants it relies on and why they hold at that point.",
            "If it needs more, a complete justification beats the line limit. An",
            "unsafe fn or trait may carry a # Safety section in its docs instead.",
        ],
    },
);

my $git_dir = $ENV{GIT_DIR};
unless (defined $git_dir && -d $git_dir) {
    chomp($git_dir = git('rev-parse', '--absolute-git-dir') // '');
}
exit 0 unless length $git_dir && -d $git_dir;

for my $marker (qw(rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG)) {
    exit 0 if -e "$git_dir/$marker";
}

my ($diff, $rev, $is_amend, $head) = ('', '', 0, '');

if ($MODE eq 'post-commit') {
    my @parents = split ' ', (git('rev-list', '--parents', '-n', '1', 'HEAD') // '');
    exit 0 unless @parents;
    $head = shift @parents;
    exit 0 if @parents > 1;
    exit 0 if $ENV{POST_COMMIT_HEAD} && $head ne $ENV{POST_COMMIT_HEAD};

    my $base = @parents ? $parents[0] : $EMPTY_TREE;
    $rev = 'HEAD';
    $diff = git('diff', $base, 'HEAD', '--unified=0', '--no-color', '--no-ext-diff',
                '--diff-filter=ACMR', '-M') // '';

    $is_amend = 1 if (git('reflog', '-1', '--format=%gs') // '') =~ /^commit \(amend\)/;
} else {
    $diff = git('diff', '--cached', '--unified=0', '--no-color', '--no-ext-diff',
                '--diff-filter=ACMR', '-M') // '';
}

exit 0 unless length $diff;

my (%added, @order, $file, $lineno);

for my $raw (split /\n/, $diff) {
    if ($raw =~ m{^\+\+\+ (?:b/)?(.+)$}) {
        $file = $1 eq '/dev/null' ? undef : $1;
        $file = undef if defined $file
            && $file =~ m{(?:^|/)(?:vendor|third_party|target|\.direnv)/};
        $lineno = undef;
        next;
    }
    if ($raw =~ /^@@ -\d+(?:,\d+)? \+(\d+)/) {
        $lineno = $1;
        next;
    }
    next unless defined $file && defined $lineno && $raw =~ /^\+/;
    push @order, $file unless $added{$file};
    push @{$added{$file}}, $lineno++;
}

my @broken;

for my $policy (@POLICIES) {
    my @hits;
    for my $path (grep { $_ =~ $policy->{applies} } @order) {
        my $content = git('show', "$rev:$path") // next;
        push @hits, map { "$path:$_" } $policy->{check}->($content, $added{$path});
    }
    push @broken, {%$policy, hits => \@hits} if @hits;
}

exit 0 unless @broken;

my $verb = $MODE eq 'post-commit' ? 'commit undone' : 'commit refused';
my @out = ("");

for my $b (@broken) {
    push @out, "$b->{name}: $b->{title} - $verb", "";
    push @out, map { "  $_" } @{$b->{hits}};
    push @out, "", @{$b->{advice}}, "";
}

if ($MODE eq 'post-commit') {
    if ($is_amend || $head eq '' || !git('rev-parse', '--verify', '--quiet', 'HEAD^')) {
        push @out, "Not reset automatically (amend or root commit). Fix it by hand.", "";
        print STDERR join("\n", @out);
        exit 0;
    }

    system($GIT, 'reset', '--soft', 'HEAD^');
    push @out, "Changes are back in the index, nothing lost. Orphaned commit: "
        . substr($head, 0, 12) . " (reflog).", "";
    print STDERR join("\n", @out);
    exit 0;
}

print STDERR join("\n", @out);
exit 1;
