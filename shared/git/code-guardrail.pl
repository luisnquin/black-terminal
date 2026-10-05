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

my ($batch_in, $batch_out);

sub blob {
    my ($spec) = @_;
    return git('show', $spec) if $spec =~ /\n/;
    unless ($batch_in) {
        require IPC::Open2;
        IPC::Open2::open2($batch_out, $batch_in, $GIT, 'cat-file', '--batch');
        binmode $_ for $batch_in, $batch_out;
    }
    print {$batch_in} "$spec\n";
    $batch_in->flush;
    my $header = <$batch_out> // return undef;
    return undef unless $header =~ /^\S+ blob (\d+)$/;
    my ($size, $content) = ($1, '');
    while (length $content < $size) {
        read($batch_out, $content, $size - length $content, length $content) or return undef;
    }
    <$batch_out>;
    return $content;
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

sub construct_key {
    (my $key = shift) =~ s/\s+//g;
    $key =~ tr/'`/""/;
    $key =~ s/;//g;
    $key =~ s/,(?=[)\]}>])//g;
    $key =~ s/\(([\w\$]+)\)=>/$1=>/g;
    return $key;
}

sub matching {
    my ($text, $at, $open, $close) = @_;
    for (my ($j, $depth) = ($at, 0); $j < length $text; $j++) {
        my $c = substr($text, $j, 1);
        $depth++ if $c eq $open;
        $depth-- if $c eq $close;
        return $j if $depth == 0;
    }
    return length($text) - 1;
}

sub rust_unsafe_end {
    my ($code, $at) = @_;
    pos($code) = $at;
    $code =~ /\G\s*/g;
    my $next = pos $code;
    my $c = substr($code, $next, 1);
    return matching($code, $next, '{', '}') if $c eq '{';
    return matching($code, $next, '(', ')') if $c eq '(';
    for (my ($j, $depth) = ($next, 0); $j < length $code; $j++) {
        my $d = substr($code, $j, 1);
        $depth += $d eq '(' ? 1 : $d eq ')' ? -1 : 0;
        return $j if !$depth && ($d eq '{' || $d eq ';');
    }
    return length($code) - 1;
}

sub rust_unsafe {
    my ($content) = @_;
    my $lines = lex_rust($content);
    my $code = join "\n", map { $_->{code} } @$lines;
    my $line_of = sub { 1 + (substr($code, 0, shift) =~ tr/\n//) };
    my (@found, %seen);

    while ($code =~ /\bunsafe\b/g) {
        my ($start, $end) = ($-[0], rust_unsafe_end($code, $+[0]));
        my ($from, $to) = ($line_of->($start), $line_of->($end));
        next if justified($lines, $from - 1);

        if (my $prev = $seen{$from}) {
            $prev->{to} = $to if $to > $prev->{to};
            next;
        }
        push @found, $seen{$from} = {line => $from, from => $from, to => $to};
    }

    for my $v (@found) {
        $v->{key} = construct_key(join '', map { $_->{code} } @$lines[$v->{from} - 1 .. $v->{to} - 1]);
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

sub openers {
    my ($text) = @_;
    my (%open_of, %stack);
    my %pair = (')' => '(', ']' => '[', '}' => '{');
    for my $j (0 .. length($text) - 1) {
        my $c = substr($text, $j, 1);
        if ($c =~ /[(\[{]/) {
            push @{$stack{$c}}, $j;
        } elsif (my $o = $pair{$c}) {
            my $at = pop @{$stack{$o}};
            $open_of{$j} = $at if defined $at;
        }
    }
    return \%open_of;
}

# An empty catch reads the same everywhere, so its identity starts at the
# try/do or at the head of the .catch() receiver chain.
sub statement_start {
    my ($masked, $start, $open_of) = @_;
    my $before = sub {
        my $k = shift;
        $k-- while $k > 0 && substr($masked, $k - 1, 1) =~ /\s/;
        return $k;
    };

    if (substr($masked, $start, 1) eq '.') {
        my $k = $start;
        while (1) {
            my $j = $before->($k);
            last unless $j > 0;
            my $c = substr($masked, $j - 1, 1);
            if ($c =~ /[)\]}]/) {
                $k = $open_of->{$j - 1} // last;
                next;
            }
            last unless $c =~ /[\w\$]/;
            $j-- while $j > 0 && substr($masked, $j - 1, 1) =~ /[\w\$]/;
            $k = $j;
            my $dot = $before->($k);
            last unless $dot > 0 && substr($masked, $dot - 1, 1) eq '.';
            $k = $dot - 1;
            $k-- if $k > 0 && substr($masked, $k - 1, 1) eq '?';
        }
        return $k;
    }

    my $k = $start;
    while (1) {
        my $j = $before->($k);
        last unless $j > 0 && substr($masked, $j - 1, 1) eq '}';
        my $open = $open_of->{$j - 1} // last;
        my $head = substr($masked, 0, $open);
        return $-[0] if $head =~ /\b(?:try|do)\s*$/;
        last unless $head =~ /\b(?:catch|on)\b[^{};]*$/;
        $k = $-[0];
    }
    return $start;
}

sub swallowed_error {
    my ($content, $path) = @_;
    my ($ext) = $path =~ /\.(\w+)$/;
    my $syn = $SYNTAX{lc $ext} or return;
    my ($masked, $comments) = mask_source($content, $syn);
    my @masked_lines = split /\n/, $masked, -1;
    my $open_of = openers($masked);
    my $marker = qr{\bignored:\s*\S+(?:\s+\S+){2,}};
    my $line_of = sub { 1 + (substr($masked, 0, shift) =~ tr/\n//) };
    my (@found, %seen);

    for my $catch (catch_blocks($masked, $syn)) {
        my ($start, $end, $body) = @$catch;
        next unless swallowing($body);

        my ($from, $to) = ($line_of->($start), $line_of->($end));
        next if grep { ($comments->{$_} // '') =~ $marker } $from .. $to;

        my ($above, $annotated) = ($from - 1, 0);
        while ($above >= 1 && $masked_lines[$above - 1] !~ /\S/ && defined $comments->{$above}) {
            $annotated = 1, last if $comments->{$above} =~ $marker;
            $above--;
        }
        next if $annotated || $seen{$from}++;

        my $origin = statement_start($masked, $start, $open_of);
        push @found, {line => $from, from => $from, to => $to,
                      key => construct_key(substr($masked, $origin, $end - $origin + 1))};
    }
    return sort { $a->{line} <=> $b->{line} } @found;
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

my ($diff, $rev, $old_rev, $is_amend, $head) = ('', '', undef, 0, '');
my @DIFF = ('-c', 'core.quotePath=false', 'diff', '--unified=0', '--no-color', '--no-ext-diff',
            '--no-relative', '--src-prefix=a/', '--dst-prefix=b/', '--diff-filter=ACMRD', '-M');

if ($MODE eq 'post-commit') {
    my @parents = split ' ', (git('rev-list', '--parents', '-n', '1', 'HEAD') // '');
    exit 0 unless @parents;
    $head = shift @parents;
    exit 0 if @parents > 1;
    exit 0 if $ENV{POST_COMMIT_HEAD} && $head ne $ENV{POST_COMMIT_HEAD};

    ($rev, $old_rev) = ('HEAD', $parents[0]);
    $diff = git(@DIFF, $old_rev // $EMPTY_TREE, 'HEAD') // '';

    $is_amend = 1 if (git('reflog', '-1', '--format=%gs') // '') =~ /^commit \(amend\)/;
} else {
    $old_rev = 'HEAD' if git('rev-parse', '--verify', '--quiet', 'HEAD');
    $diff = git(@DIFF, '--cached') // '';
}

exit 0 unless length $diff;

sub diff_path {
    my ($raw, $prefix) = @_;
    $raw =~ s/\t$//;
    if ($raw =~ /^"(.*)"$/) {
        my %esc = (n => "\n", t => "\t", '"' => '"', '\\' => '\\', a => "\a", b => "\b", f => "\f", r => "\r", v => "\x0b");
        ($raw = $1) =~ s{\\([0-7]{3}|.)}{length $1 == 3 ? chr oct $1 : $esc{$1} // $1}ge;
    }
    return undef if $raw eq '/dev/null';
    return $raw =~ s/^\Q$prefix\E//r;
}

my $VENDORED = qr{(?:^|/)(?:vendor|third_party|target|node_modules|dist|\.direnv)/};
my (%added, @changed);
my @diff = split /\n/, $diff;

for (my $k = 0; $k <= $#diff; $k++) {
    if ($diff[$k] =~ /^--- / && $k < $#diff && $diff[$k + 1] =~ /^\+\+\+ /) {
        my ($old, $new) = (diff_path(substr($diff[$k], 4), 'a/'), diff_path(substr($diff[$k + 1], 4), 'b/'));
        $old = undef if defined $old && $old =~ $VENDORED;
        $new = undef if defined $new && $new =~ $VENDORED;
        push @changed, {old => $old, new => $new} if defined $old || defined $new;
        $k++;
        next;
    }
    next unless $diff[$k] =~ /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;
    my ($minus, $lineno, $plus) = ($1 // 1, $2, $3 // 1);
    my $new = @changed ? $changed[-1]{new} : undef;
    while (($minus || $plus) && $k < $#diff) {
        my $sign = substr($diff[++$k], 0, 1);
        if ($sign eq '-') {
            $minus--;
        } elsif ($sign eq '+') {
            push @{$added{$new}}, $lineno if defined $new;
            ($plus, $lineno) = ($plus - 1, $lineno + 1);
        }
    }
    $k++ while $k < $#diff && $diff[$k + 1] =~ /^\\/;
}

my %skipped = map { $_ => 1 } split /[\s,]+/, $ENV{CODE_GUARDRAIL_SKIP} // '';
my @broken;

for my $policy (grep { !$skipped{$_->{name}} } @POLICIES) {
    my (%before, %after, %touched_of, %untouched_of);

    for my $c (@changed) {
        next unless defined $c->{new} && $c->{new} =~ $policy->{applies};
        my $content = blob("$rev:$c->{new}") // next;
        my %touched = map { $_ => 1 } @{$added{$c->{new}} || []};

        for my $v ($policy->{check}->($content, $c->{new})) {
            $after{$v->{key}}++;
            my $bucket = (grep { $touched{$_} } $v->{from} .. $v->{to}) ? \%touched_of : \%untouched_of;
            push @{$bucket->{$v->{key}}}, "$c->{new}:$v->{line}";
        }
    }
    next unless %touched_of || %untouched_of;

    for my $c (@changed) {
        next unless defined $c->{old} && defined $old_rev && $c->{old} =~ $policy->{applies};
        my $content = blob("$old_rev:$c->{old}") // next;
        $before{$_->{key}}++ for $policy->{check}->($content, $c->{old});
    }

    my @hits = map { $_->[0] }
        sort { $a->[1] cmp $b->[1] || $a->[2] <=> $b->[2] }
        map { [$_, /^(.*):(\d+)$/] }
        map { @{$touched_of{$_} || $untouched_of{$_}} }
        grep { $after{$_} > ($before{$_} // 0) } keys %after;
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
