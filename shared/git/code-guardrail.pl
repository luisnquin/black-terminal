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

my $JS    = {quotes => q{'"}, template => 1, regex => 1, interp => '${'};
my %SYNTAX = (
    (map { $_ => $JS } qw(ts tsx mts cts js jsx mjs cjs)),
    dart  => {quotes => q{'"}, triple => [q{'''}, '"""'], raw => 1, nest => 1, interp => '${', on => 1},
    swift => {quotes => '"', triple => ['"""'], nest => 1, interp => '\\('},
    (map { $_ => {quotes => q{'"}, triple => ['"""'], nest => 1, interp => '${'} } qw(kt kts)),
);

my %REGEX_AFTER = map { $_ => 1 }
    qw(return typeof case do else in of void yield await delete instanceof new throw);

sub blank {
    (my $text = shift) =~ s/[^\n]/ /g;
    return $text;
}

sub mask_source {
    my ($src, $syn) = @_;
    my ($n, $i, $out, %comments) = (length $src, 0, '');
    my ($sig, $word) = ('', '');

    my $line_of = sub { 1 + (substr($src, 0, shift) =~ tr/\n//) };
    my $record = sub {
        my ($at, $text) = @_;
        my $line = $line_of->($at);
        $comments{$line++} .= $_ for split /\n/, $text, -1;
    };
    my $balanced = sub {
        my ($j, $open, $close) = @_;
        for (my $depth = 1; $j < $n && $depth; $j++) {
            my $c = substr($src, $j, 1);
            $depth += $c eq $open ? 1 : $c eq $close ? -1 : 0;
        }
        return $j;
    };
    my $string_end = sub {
        my ($j, $close, $escape, $interp) = @_;
        while ($j < $n) {
            my $c = substr($src, $j, 1);
            return $j if substr($src, $j, length $close) eq $close;
            return $j if $c eq "\n" && length $close == 1 && $close ne '`';
            if ($interp && substr($src, $j, length $interp) eq $interp) {
                $j = $balanced->($j + length $interp, $interp eq '${' ? ('{', '}') : ('(', ')'));
            } elsif ($escape && $c eq '\\') {
                $j += 2;
            } else {
                $j++;
            }
        }
        return $n;
    };
    my $emit_string = sub {
        my ($open, $close, $escape, $interp) = @_;
        my $start = $i + length $open;
        my $end = $string_end->($start, $close, $escape, $interp);
        my $closed = substr($src, $end, length $close) eq $close;
        $out .= $open . blank(substr($src, $start, $end - $start)) . ($closed ? $close : '');
        $i = $end + ($closed ? length $close : 0);
        ($sig, $word) = ('"', '');
    };

    CHAR: while ($i < $n) {
        my $c = substr($src, $i, 1);
        my $two = substr($src, $i, 2);

        if ($two eq '//') {
            my $end = index($src, "\n", $i);
            $end = $n if $end < 0;
            $record->($i, substr($src, $i, $end - $i));
            $out .= ' ' x ($end - $i);
            $i = $end;
            next;
        }
        if ($two eq '/*') {
            my ($j, $depth) = ($i + 2, 1);
            while ($j < $n && $depth) {
                my $pair = substr($src, $j, 2);
                if ($syn->{nest} && $pair eq '/*') { $depth++; $j += 2 }
                elsif ($pair eq '*/')              { $depth--; $j += 2 }
                else                               { $j++ }
            }
            $record->($i, substr($src, $i, $j - $i));
            $out .= blank(substr($src, $i, $j - $i));
            $i = $j;
            next;
        }

        my $fresh = $i == 0 || substr($src, $i - 1, 1) !~ /\w/;
        for my $triple (@{$syn->{triple} || []}) {
            next unless substr($src, $i, 3) eq $triple;
            $emit_string->($triple, $triple, 1, $syn->{interp});
            next CHAR;
        }
        if ($syn->{raw} && $fresh && $two =~ /^r['"]$/) {
            $out .= 'r';
            $i++;
            $emit_string->(substr($two, 1), substr($two, 1), 0, undef);
            next;
        }
        if ($syn->{template} && $c eq '`') {
            $emit_string->('`', '`', 1, '${');
            next;
        }
        if (index($syn->{quotes}, $c) >= 0) {
            $emit_string->($c, $c, 1, $c eq "'" && $syn->{template} ? undef : $syn->{interp});
            next;
        }
        if ($syn->{regex} && $c eq '/' && ($sig eq '' || $sig =~ m{[(,=:\[!&|?{};+\-*%<>~^]} || $REGEX_AFTER{$word})) {
            my ($j, $class) = ($i + 1, 0);
            while ($j < $n) {
                my $d = substr($src, $j, 1);
                last if $d eq "\n" || (!$class && $d eq '/');
                $class = 1 if $d eq '[';
                $class = 0 if $d eq ']';
                $j += $d eq '\\' ? 2 : 1;
            }
            if ($j < $n && substr($src, $j, 1) eq '/') {
                $out .= '/' . blank(substr($src, $i + 1, $j - $i - 1)) . '/';
                $i = $j + 1;
                ($sig, $word) = ('/', '');
                next;
            }
        }

        $out .= $c;
        $i++;
        next if $c =~ /\s/;
        $word = $c =~ /\w/ ? ($sig =~ /\w/ ? $word : '') . $c : '';
        $sig = $c;
    }

    return ($out, \%comments);
}

sub swallowing {
    (my $body = shift) =~ s/\s+//g;
    $body =~ s/;$//;
    $body = $1 while $body =~ /^\((.*)\)$/;
    return $body =~ /^(?:return)?(?:null|undefined|nil|Unit|false|0|\[\]|\{\}|""|''|empty(?:List|Map|Set)\(\)|(?:list|map|set)Of\(\))?$/;
}

sub catch_blocks {
    my ($masked, $syn) = @_;
    my @found;

    my $close_of = sub {
        my ($j, $open, $close) = @_;
        for (my $depth = 0; $j < length $masked; $j++) {
            my $c = substr($masked, $j, 1);
            $depth++ if $c eq $open;
            $depth-- if $c eq $close;
            return $j if $depth == 0;
        }
        return undef;
    };
    my $block = sub {
        my ($start, $brace) = @_;
        my $end = $close_of->($brace, '{', '}') // return;
        push @found, [$start, $end, substr($masked, $brace + 1, $end - $brace - 1)];
    };

    while ($masked =~ /(?<![.\w\$])catch\b\s*/g) {
        my ($start, $j) = ($-[0], pos $masked);
        $j = 1 + ($close_of->($j, '(', ')') // next) if substr($masked, $j, 1) eq '(';
        my $brace = index($masked, '{', $j);
        next if $brace < 0 || substr($masked, $j, $brace - $j) =~ /[;}]/;
        $block->($start, $brace);
        pos($masked) = $j;
    }

    if ($syn->{on}) {
        while ($masked =~ /\}\s*\bon\s+[\w.<>?, ]+?\s*\{/g) {
            $block->($-[0] + 1, $+[0] - 1);
        }
    }

    while ($masked =~ /\.(?:catch|catchError)\s*\(/g) {
        my ($start, $paren) = ($-[0], $+[0] - 1);
        my $end = $close_of->($paren, '(', ')') // next;
        my $inner = substr($masked, $paren + 1, $end - $paren - 1);
        next unless $inner =~ /^\s*(?:async\s+)?(?:\([^()]*\)|[\w\$]+)\s*(=>)?\s*/;
        my ($arrow, $at) = ($1, $paren + 1 + $+[0]);

        if (substr($masked, $at, 1) eq '{') {
            my $close = $close_of->($at, '{', '}') // next;
            next if substr($masked, $close + 1, $end - $close - 1) =~ /\S/;
            push @found, [$start, $end, substr($masked, $at + 1, $close - $at - 1)];
        } elsif ($arrow) {
            push @found, [$start, $end, substr($masked, $at, $end - $at)];
        }
    }

    return @found;
}

sub swallowed_error {
    my ($content, $added, $path) = @_;
    my ($ext) = $path =~ /\.(\w+)$/;
    my $syn = $SYNTAX{lc $ext} or return;
    my ($masked, $comments) = mask_source($content, $syn);
    my @masked_lines = split /\n/, $masked, -1;
    my %fresh = map { $_ => 1 } @$added;
    my $marker = qr{\bignored:\s*\S+(?:\s+\S+){2,}};
    my $line_of = sub { 1 + (substr($masked, 0, shift) =~ tr/\n//) };
    my (@found, %seen);

    for my $catch (catch_blocks($masked, $syn)) {
        my ($start, $end, $body) = @$catch;
        next unless swallowing($body);

        my ($from, $to) = ($line_of->($start), $line_of->($end));
        next unless grep { $fresh{$_} } $from .. $to;
        next if grep { ($comments->{$_} // '') =~ $marker } $from .. $to;

        my ($above, $annotated) = ($from - 1, 0);
        while ($above >= 1 && $masked_lines[$above - 1] !~ /\S/ && defined $comments->{$above}) {
            $annotated = 1, last if $comments->{$above} =~ $marker;
            $above--;
        }

        push @found, $from unless $annotated || $seen{$from}++;
    }
    return sort { $a <=> $b } @found;
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
    {
        name    => 'swallowed-error-policy',
        applies => qr{\.(?:[mc]?[jt]sx?|dart|swift|kts?)$},
        check   => \&swallowed_error,
        title   => 'catch that drops the error',
        advice  => [
            "This catch is empty, holds only comments, or returns an empty default,",
            "so the failure disappears for callers and for whoever debugs it later.",
            "",
            "If losing the error is intended, change nothing in the code. Put a",
            "// ignored: <reason> comment inside the catch or directly above it, at",
            "least three words on why dropping this error is safe.",
            "",
            "If it is a bug, handling or propagating the error changes what callers",
            "see at runtime. Present that change and ask the user before applying it.",
            "Do not rethrow, log, or swap the default just to get past this check.",
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
                '--diff-filter=ACMRD', '-M') // '';

    $is_amend = 1 if (git('reflog', '-1', '--format=%gs') // '') =~ /^commit \(amend\)/;
} else {
    $diff = git('diff', '--cached', '--unified=0', '--no-color', '--no-ext-diff',
                '--diff-filter=ACMRD', '-M') // '';
}

exit 0 unless length $diff;

my (%candidates, %removed, $file, $lineno);
my @diff = split /\n/, $diff;

sub trimmed {
    (my $text = shift) =~ s/^\s+|\s+$//g;
    return $text;
}

for my $k (0 .. $#diff) {
    my $raw = $diff[$k];

    next if $raw =~ /^--- / && $k < $#diff && $diff[$k + 1] =~ /^\+\+\+ /;
    if ($k > 0 && $diff[$k - 1] =~ /^--- / && $raw =~ m{^\+\+\+ (?:b/)?(.+)$}) {
        $file = $1 eq '/dev/null' ? undef : $1;
        $file = undef if defined $file
            && $file =~ m{(?:^|/)(?:vendor|third_party|target|node_modules|dist|\.direnv)/};
        $lineno = undef;
        next;
    }
    if ($raw =~ /^@@ -\d+(?:,\d+)? \+(\d+)/) {
        $lineno = $1;
        next;
    }
    next unless defined $lineno;

    if ($raw =~ /^-(.*)/) {
        my $text = trimmed($1);
        $removed{$text}++ if length $text;
    } elsif (defined $file && $raw =~ /^\+(.*)/) {
        push @{$candidates{$file}}, [$lineno++, trimmed($1)];
    }
}

my (%added, @order);

for my $path (sort keys %candidates) {
    for my $line (@{$candidates{$path}}) {
        my ($at, $text) = @$line;
        next if length $text && $removed{$text} && $removed{$text}--;
        push @{$added{$path}}, $at;
    }
    push @order, $path if $added{$path};
}

my %skipped = map { $_ => 1 } split /[\s,]+/, $ENV{CODE_GUARDRAIL_SKIP} // '';
my @broken;

for my $policy (grep { !$skipped{$_->{name}} } @POLICIES) {
    my @hits;
    for my $path (grep { $_ =~ $policy->{applies} } @order) {
        my $content = git('show', "$rev:$path") // next;
        push @hits, map { "$path:$_" } $policy->{check}->($content, $added{$path}, $path);
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
