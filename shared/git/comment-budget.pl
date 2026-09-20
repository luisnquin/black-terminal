#!/usr/bin/env perl
# comment-budget: refuse commits that spend more comment lines than the diff earns.
use strict;
use warnings;

my $MODE = shift @ARGV || 'pre-commit';
my $GIT = $ENV{COMMENT_BUDGET_GIT} || 'git';

exit 0 if lc($ENV{COMMENT_BUDGET} || '') =~ /^(off|0|no|skip)$/;

my $MAX_BLOCK_LINES = cfg('MAX_BLOCK_LINES', 3);
my $MAX_BLOCKS      = cfg('MAX_BLOCKS',      3);
my $MIN_BLOCKS      = cfg('MIN_BLOCKS',      1);
my $CODE_PER_BLOCK  = cfg('CODE_PER_BLOCK',  120);
my $MAX_DENSITY     = cfg('MAX_DENSITY_PCT', 15);
my $FREE_LINES      = cfg('FREE_LINES',      3);

my $EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

sub cfg {
    my ($key, $default) = @_;
    my $raw = $ENV{"COMMENT_BUDGET_$key"};
    return $default unless defined $raw && $raw =~ /^\d+$/;
    return $raw + 0;
}

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

my $git_dir = $ENV{GIT_DIR};
unless (defined $git_dir && -d $git_dir) {
    chomp($git_dir = git('rev-parse', '--absolute-git-dir') // '');
}
exit 0 unless length $git_dir && -d $git_dir;

for my $marker (qw(rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG)) {
    exit 0 if -e "$git_dir/$marker";
}

my ($diff, $is_amend, $head) = ('', 0, '');

if ($MODE eq 'post-commit') {
    my @parents = split ' ', (git('rev-list', '--parents', '-n', '1', 'HEAD') // '');
    exit 0 unless @parents;
    $head = shift @parents;
    exit 0 if @parents > 1;

    my $base = @parents ? $parents[0] : $EMPTY_TREE;
    $diff = git('diff', $base, 'HEAD', '--unified=0', '--no-color', '--no-ext-diff', '-M') // '';

    $is_amend = 1 if (git('reflog', '-1', '--format=%gs') // '') =~ /^commit \(amend\)/;
} else {
    $diff = git('diff', '--cached', '--unified=0', '--no-color', '--no-ext-diff',
                '--diff-filter=ACMR', '-M') // '';
}

exit 0 unless length $diff;

my $C_LIKE  = {line => ['//'], block => [['/*', '*/']]};
my $HASH    = {line => ['#']};
my $DASH    = {line => ['--']};
my $SEMI    = {line => [';']};

my %LANG = (
    (map { $_ => $HASH } qw(nix sh bash zsh fish ksh py pyi rb pl pm t yaml yml toml
                            tf tfvars hcl cfg conf ini service desktop mk just env r jl)),
    (map { $_ => $C_LIKE } qw(go rs c h cc cpp cxx hpp hh m mm java kt kts swift scala
                              dart php cs zig proto gradle groovy jsonnet)),
    (map { $_ => $C_LIKE } qw(js jsx mjs cjs ts tsx mts cts)),
    (map { $_ => {block => [['/*', '*/']]} } qw(css scss less)),
    lua  => {line => ['--'], block => [['--[[', ']]']]},
    sql  => $DASH,
    hs   => {line => ['--'], block => [['{-', '-}']]},
    elm  => $DASH,
    el   => $SEMI,
    lisp => $SEMI,
    clj  => $SEMI,
    scm  => $SEMI,
    html => {block => [['<!--', '-->']]},
    xml  => {block => [['<!--', '-->']]},
);

my %BY_NAME = (
    map { $_ => $HASH } qw(Makefile makefile GNUmakefile Dockerfile Containerfile
                           justfile Justfile .envrc .gitignore .gitattributes
                           .dockerignore .editorconfig),
);

my @EXEMPT = (
    qr{^#!},
    qr{^(?://|\#|--|;)\s*SPDX-},
    qr{^//\s*(?:go:|nolint|lint:|\+build|\@ts-|eslint|prettier-|biome-|oxlint|deno-lint|istanbul|jscpd:|coverage:|c8\b|v8\b)},
    qr{^///\s*<reference},
    qr{^\#\s*(?:shellcheck|noqa|type:\s*ignore|pylint:|mypy:|ruff:|fmt:|nosec|pragma:|-\*-|nix-shell|hadolint|checkov:|trivy:|gitleaks:)},
    qr{^---\s*@?\w+},
    qr{^--\s*(?:luacheck:|selene:|stylua:)},
    qr{^/\*\s*(?:eslint|global|istanbul|prettier|jshint|\@ts-|c8|v8)},
    qr{^<!--\s*(?:prettier-ignore|markdownlint)},
);

sub lang_for {
    my ($path) = @_;
    return undef if $path =~ m{(?:^|/)(?:vendor|node_modules|third_party|\.direnv|dist|__generated__|__snapshots__)/};

    (my $base = $path) =~ s{.*/}{};
    return undef if $base =~ /^(?:flake\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|go\.sum|poetry\.lock)$/;
    return undef if $base =~ /\.(?:md|mdx|txt|rst|json|lock|snap|svg|patch|diff|csv|tsv|golden|min\.js|min\.css|pb\.go|pb\.gw\.go|_templ\.go|generated\.go|g\.dart|freezed\.dart)$/i;
    return $BY_NAME{$base} if $BY_NAME{$base};

    my ($ext) = $base =~ /\.([A-Za-z0-9_]+)$/;
    return undef unless defined $ext;
    return $LANG{lc $ext};
}

sub exempt {
    my ($text) = @_;
    for my $rx (@EXEMPT) {
        return 1 if $text =~ $rx;
    }
    return 0;
}

# A token opens a comment only where an operator or an identifier cannot already
# be sitting: line start, after whitespace, or after a closing/separating char.
# That single rule is what keeps `http://x`, `i--` and `$#` out of the count.
sub boundary_ok {
    my ($text, $pos) = @_;
    return 1 if $pos == 0;
    return substr($text, $pos - 1, 1) =~ /[\s;)\]},=]/ ? 1 : 0;
}

sub classify {
    my ($text, $lang, $state) = @_;

    if ($state->{closer}) {
        my $closer = $state->{closer};
        my $at = index($text, $closer);
        return 'comment' if $at < 0;
        $state->{closer} = undef;
        my $rest = substr($text, $at + length $closer);
        return $rest =~ /\S/ ? 'code+comment' : 'comment';
    }

    my $openers = $lang->{openers} ||= [
        sort { length($b) <=> length($a) }
            (@{$lang->{line} || []}, map { $_->[0] } @{$lang->{block} || []})
    ];
    my $closer_of = $lang->{closer_of} ||=
        {map { $_->[0] => $_->[1] } @{$lang->{block} || []}};

    my $seen = 0;
    for my $tok (@$openers) {
        $seen = 1, last if index($text, $tok) >= 0;
    }
    return $text =~ /\S/ ? 'code' : 'blank' unless $seen;

    my $n = length $text;
    my ($i, $quote, $start) = (0, '', -1);

    SCAN: while ($i < $n) {
        my $c = substr($text, $i, 1);

        if ($quote) {
            $i += ($c eq '\\') ? 2 : 1;
            $quote = '' if $c eq $quote;
            next;
        }
        if ($c eq '"' || $c eq "'" || $c eq '`') {
            $quote = $c;
            $i++;
            next;
        }

        for my $tok (@$openers) {
            next unless substr($text, $i, length $tok) eq $tok;
            next unless boundary_ok($text, $i);

            my $closer = $closer_of->{$tok};
            if (!$closer) {
                $start = $i;
                last SCAN;
            }

            my $end = index($text, $closer, $i + length $tok);
            if ($end < 0) {
                $state->{closer} = $closer;
                $start = $i;
                last SCAN;
            }
            $start = $i if $start < 0;
            $i = $end + length $closer;
            next SCAN;
        }
        $i++;
    }

    return $text =~ /\S/ ? 'code' : 'blank' if $start < 0;

    my $payload = substr($text, $start);
    my $before  = substr($text, 0, $start);
    return 'exempt' if exempt($payload);
    return $before =~ /\S/ ? 'code+comment' : 'comment';
}

my (@added, $file, $lang, $lineno, %state);

for my $raw (split /\n/, $diff, -1) {
    if ($raw =~ m{^\+\+\+ (?:b/)?(.+)$}) {
        $file = $1 eq '/dev/null' ? undef : $1;
        $lang = defined $file ? lang_for($file) : undef;
        %state = ();
        next;
    }
    if ($raw =~ /^@@ -\S+ \+(\d+)/) {
        $lineno = $1;
        %state = ();
        next;
    }
    next unless defined $lang && defined $lineno;
    next unless $raw =~ /^\+/;
    next if $raw =~ m{^\+\+\+ };

    my $text = substr($raw, 1);
    my $kind = classify($text, $lang, \%state);
    push @added, {file => $file, line => $lineno, kind => $kind};
    $lineno++;
}

my ($code_lines, $comment_lines) = (0, 0);
my @blocks;
my $run;

for my $entry (@added) {
    my $kind = $entry->{kind};
    $code_lines++    if $kind eq 'code' || $kind eq 'code+comment';
    $comment_lines++ if $kind eq 'comment' || $kind eq 'code+comment';

    if ($kind eq 'comment') {
        if ($run && $run->{file} eq $entry->{file} && $run->{last} + 1 == $entry->{line}) {
            $run->{size}++;
            $run->{last} = $entry->{line};
            next;
        }
        $run = {file => $entry->{file}, line => $entry->{line}, last => $entry->{line}, size => 1, trailing => 0};
        push @blocks, $run;
        next;
    }

    $run = undef;
    push @blocks, {file => $entry->{file}, line => $entry->{line}, size => 1, trailing => 1}
        if $kind eq 'code+comment';
}

exit 0 unless @blocks;

my $budget = int($code_lines / $CODE_PER_BLOCK);
$budget = $MIN_BLOCKS if $budget < $MIN_BLOCKS;
$budget = $MAX_BLOCKS if $budget > $MAX_BLOCKS;

my $allowance = int($code_lines * $MAX_DENSITY / 100);
$allowance = $FREE_LINES if $allowance < $FREE_LINES;

my @oversized = grep { $_->{size} > $MAX_BLOCK_LINES } @blocks;
my $over_budget  = @blocks > $budget;
my $over_density = $comment_lines > $allowance;

exit 0 unless @oversized || $over_budget || $over_density;

my $verb = $MODE eq 'post-commit' ? 'commit undone' : 'commit refused';
my @out = ("", "comment budget exceeded - $verb", "");

push @out, sprintf("  earned  %d added code line%s",
    $code_lines, $code_lines == 1 ? '' : 's');
push @out, sprintf("  budget  %d block%s, <=%d lines each, %d comment line%s total",
    $budget, $budget == 1 ? '' : 's', $MAX_BLOCK_LINES,
    $allowance, $allowance == 1 ? '' : 's');
push @out, sprintf("  spent   %d block%s, %d comment line%s",
    scalar @blocks, @blocks == 1 ? '' : 's',
    $comment_lines, $comment_lines == 1 ? '' : 's');
push @out, "";

my $width = 0;
for my $b (@blocks) {
    my $len = length("$b->{file}:$b->{line}");
    $width = $len if $len > $width;
}
for my $b (@blocks) {
    my $note = $b->{trailing} ? 'trailing' : sprintf('%d line%s', $b->{size}, $b->{size} == 1 ? '' : 's');
    $note .= ' - over block cap' if $b->{size} > $MAX_BLOCK_LINES;
    push @out, sprintf("  %-*s  %s", $width, "$b->{file}:$b->{line}", $note);
}

push @out, "",
    "A comment earns its line only when the behavior is rare enough that reading",
    "the code does not explain it. Everything else is reasoning, and reasoning",
    "belongs in the commit body, where it cannot rot away from the code it claims",
    "to describe.",
    "",
    "Delete what the code already says. What survives, spend the budget on.",
    "";

if ($MODE eq 'post-commit') {
    my @parents = split ' ', (git('rev-list', '--parents', '-n', '1', 'HEAD') // '');
    shift @parents;

    if ($is_amend || !@parents) {
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
