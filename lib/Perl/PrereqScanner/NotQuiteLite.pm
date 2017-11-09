package Perl::PrereqScanner::NotQuiteLite;

use strict;
use warnings;
use Carp;
use Perl::PrereqScanner::NotQuiteLite::Context;
use Perl::PrereqScanner::NotQuiteLite::Util;

our $VERSION = '0.50';

our @BUNDLED_PARSERS = qw/
  Aliased Autouse Catalyst ClassLoad Core Inline
  Mixin ModuleRuntime MojoBase Moose
  Plack POE Superclass TestMore TestRequires
  UniversalVersion
/;
our @DEFAULT_PARSERS = qw/Core Moose/;

### Helpers For Debugging

use constant DEBUG => $ENV{PERL_PSNQL_DEBUG} || 0;
use constant DEBUG_RE => DEBUG > 3 ? 1 : 0;

if (!!DEBUG) {
  require Data::Dump; Data::Dump->import(qw/dump/);
  sub _debug { print @_, "\n" }
  sub _error { print @_, "*" x 50, "\n" }
  sub _dump_stack {
    my ($c, $char) = @_;
    my $stacked = join '', map {($_->[2] ? "($_->[2])" : '').$_->[0]} @{$c->{stack}};
    _debug("$char \t\t\t\t stacked: $stacked");
  }
}

sub _match_error {
  my $rstr = shift;
  $@ = shift() . substr($$rstr, pos($$rstr), 100);
  return;
}

### Global Variables To Be Sorted Out Later

my %defined_keywords = _keywords();

my %unsupported_packages = map {$_ => 1} qw(
  MooseX::Declare
  Perl6::Attributes
  Text::RewriteRules
  Regexp::Grammars
  tt
  syntax
);

my %is_conditional = map {$_ => 1} qw(
  if elsif unless else given when
  for foreach while until
);

my %expects_expr_block = map {$_ => 1} qw(
  if elsif unless given when
  for foreach while until
);

my %expects_block_list = map {$_ => 1} qw(
  map grep sort
);

my %expects_fh_list = map {$_ => 1} qw(
  print printf say
);

my %expects_fh_or_block_list = (
  %expects_block_list,
  %expects_fh_list,
);

my %expects_block = map {$_ => 1} qw(
  else default
  eval sub do while until continue
  BEGIN END INIT CHECK
  if elsif unless given when
  for foreach while until
  map grep sort
);

my %expects_word = map {$_ => 1} qw(
  use require no sub
);

my %ends_expr = map {$_ => 1} qw(
  and or xor
  if else elsif unless when default
  for foreach while until
  && || !~ =~ = += -= *= /= **= //= %= ^= |=
  > < >= <= <> <=> cmp ge gt le lt eq ne ? :
);

my %has_sideff = map {$_ => 1} qw(
  and or xor && || //
  if unless
);

# keywords that allow /regexp/ to follow directly
my %regexp_may_follow = map {$_ => 1} qw(
  and or cmp if elsif unless eq ne
  gt lt ge le for while until grep map not split when
);

my $re_namespace = qr/(?:::|')?(?:\w+(?:(?:::|')\w+)*)/;
my $re_nonblock_chars = qr/[^\\\(\)\{\}\[\]\<\>\/"'`#q~,\s]*/;
my $re_variable = qr/
  (?:$re_namespace)
  | (?:\^[A-Z\]])
  | (?:\{\^[A-Z0-9_]+\})
  | (?:[_"\(\)<\\\&`'\+\-,.\/\%#:=~\|?!\@\*\[\]\^])
/x;
my $re_pod = qr/(
  =[a-zA-Z]\w*\b
  .*?
  (?:(?:\n)
  =cut\b.*?(?:\n|\z)|\z)
)/sx;
my $re_comment = qr/(?:\s*#.*?\n)+/s;

my $g_re_scalar_variable = qr{\G(\$(?:$re_variable))};
my $g_re_hash_shortcut = qr{\G(\{\s*(?:\w+|(['"])[\w\s]+\2|(?:$re_nonblock_chars))\s*(?<!\$)\})};
my $g_re_prototype = qr{\G(\([^\)]*?\))};

my %ReStrInDelims;
sub _gen_re_str_in_delims {
  my $delim = shift;
  $ReStrInDelims{$delim} ||= do {
    if ($delim eq '\\') {
      qr/(?:[^\\]*(?:(?:\\\\)[^\\]*)*)/s;
    } else {
      $delim = quotemeta $delim;
      qr/(?:[^\\$delim]*(?:\\.[^\\$delim]*)*)/s;
    }
  };
}

my $re_str_in_single_quotes = _gen_re_str_in_delims(q{'});
my $re_str_in_double_quotes = _gen_re_str_in_delims(q{"});
my $re_str_in_backticks     = _gen_re_str_in_delims(q{`});

my %ReStrInDelimsWithEndDelim;
sub _gen_re_str_in_delims_with_end_delim {
  my $delim = shift;
  $ReStrInDelimsWithEndDelim{$delim} ||= do {
    my $re = _gen_re_str_in_delims($delim);
    qr{$re\Q$delim\E};
  };
}

my %RdelSkip;
sub _gen_rdel_and_re_skip {
  my $ldel = shift;
  @{$RdelSkip{$ldel} ||= do {
    (my $rdel = $ldel) =~ tr/[({</])}>/;
    my $re_skip = qr{[^\Q$ldel$rdel\E\\]+};
    [$rdel, $re_skip];
  }};
}

my %RegexpShortcut;
sub _gen_re_regexp_shortcut {
  my ($ldel, $rdel) = @_;
  $RegexpShortcut{$ldel} ||= do {
    $ldel = quotemeta $ldel;
    $rdel = $rdel ? quotemeta $rdel : $ldel;
    qr{(?:[^\\\(\)\{\}\[\]<>$ldel$rdel]*(?:\\.[^\\\(\)\[\]\{\}<>$ldel$rdel]*)*)$rdel};
  };
}

############################

my %LOADED;

sub new {
  my ($class, %args) = @_;

  my %mapping;
  my @parsers = $class->_get_parsers($args{parsers});
  for my $parser (@parsers) {
    if (!exists $LOADED{$parser}) {
      eval "require $parser; 1" or die "Parser Error: $@";
      $LOADED{$parser} = $parser->can('register') ? $parser->register : undef;
    }
    my $parser_mapping = $LOADED{$parser} or next;
    for my $type (qw/use no keyword method/) {
      next unless exists $parser_mapping->{$type};
      for my $name (keys %{$parser_mapping->{$type}}) {
        $mapping{$type}{$name} = [
          $parser,
          $parser_mapping->{$type}{$name},
          (($type eq 'use' or $type eq 'no') ? ($name) : ()),
        ];
      }
    }
  }
  $args{_} = \%mapping;

  bless \%args, $class;
}

sub _get_parsers {
  my ($class, $list) = @_;
  my @parsers;
  my %should_ignore;
  for my $parser (@{$list || [qw/:default/]}) {
    if ($parser eq ':installed') {
      require Module::Find;
      push @parsers, Module::Find::findsubmod("$class\::Parser");
    } elsif ($parser eq ':bundled') {
      push @parsers, map {"$class\::Parser::$_"} @BUNDLED_PARSERS;
    } elsif ($parser eq ':default') {
      push @parsers, map {"$class\::Parser::$_"} @DEFAULT_PARSERS;
    } elsif ($parser =~ s/^\+//) {
      push @parsers, $parser;
    } elsif ($parser =~ s/^\-//) {
      $should_ignore{"$class\::Parser\::$parser"} = 1;
    } elsif ($parser =~ /^$class\::Parser::/) {
      push @parsers, $parser;
    } else {
      push @parsers, "$class\::Parser\::$parser";
    }
  }
  grep {!$should_ignore{$_}} @parsers;
}

sub scan_file {
  my ($self, $file) = @_;
  open my $fh, '<', $file or croak "Can't open $file: $!";
  my $code = do { local $/; <$fh> };
  $self->{file} = $file;
  $self->scan_string($code);
}

sub scan_string {
  my ($self, $string) = @_;

  $string = '' unless defined $string;

  my $c = Perl::PrereqScanner::NotQuiteLite::Context->new(%$self);

  # UTF8 BOM
  if ($string =~ s/\A(\xef\xbb\xbf)//s) {
    utf8::decode($string);
    $c->{decoded} = 1;
  }
  # Other BOMs (TODO: also decode?)
  $string =~ s/\A(\x00\x00\xfe\xff|\xff\xfe\x00\x00|\xfe\xff|\xff\xfe)//s;

  # normalize
  if ("\n" eq "\015") {
    $string =~ s/(?:\015?\012)/\n/gs;
  } elsif ("\n" eq "\012") {
    $string =~ s/(?:\015\012?)/\n/gs;
  } elsif ("\n" eq "\015\012") {
    $string =~ s/(?:\015(?!\012)|(?<!\015)\012)/\n/gs;
  } else {
    $string =~ s/(?:\015\012|\015|\012)/\n/gs;
  }

  # FIXME
  $c->{stack} = [];
  $c->{errors} = [];
  $c->{callback} = {
    use     => \&_use,
    require => \&_require,
    no      => \&_no,
  };
  $c->{wants_doc} = 0;

  pos($string) = 0;

  {
    local $@;
    eval { $self->_scan($c, \$string, 0) };
    push @{$c->{errors}}, "Scan Error: $@" if $@;
    if ($c->{redo}) {
      delete $c->{redo};
      delete $c->{ended};
      redo;
    }
  }
  $c;
}

sub _scan {
  my ($self, $c, $rstr, $parent_scope) = @_;

  _dump_stack($c, "BEGIN SCOPE") if !!DEBUG;

  # found __DATA|END__ somewhere?
  return $c if $c->{ended};

  my $wants_doc = $c->{wants_doc};
  my $line_top = 1;
  my $waiting_for_a_block;

  my $current_scope = 0;
  my ($token, $token_desc, $token_type) = ('', '', '');
  my ($prev_token, $prev_token_type) = ('', '');
  my ($stack, $unstack);
  my (@keywords, @tokens, @scope_tokens);
  my $caller_package;
  my $prepend;
  my ($pos, $c1);
  while(defined($pos = pos($$rstr))) {
    $token = undef;

    # cache first letter for better performance
    $c1 = substr($$rstr, $pos, 1);

    if ($line_top) {
      if ($c1 eq '=') {
        if ($$rstr =~ m/\G($re_pod)/gcsx) {
          ($token, $token_desc, $token_type) = ($1, 'POD', '') if $wants_doc;
          next;
        }
      }
    }
    if ($c1 eq "\n") {
      $$rstr =~ m{\G(?>\n+)}gcs;
      $line_top = 1;
      next;
    }

    $line_top = 0;
    # ignore whitespaces
    if ($c1 eq ' ' or $c1 eq "\t") {
      $$rstr =~ m{\G(?>[ \t]+)}gc;
      next;
    } elsif ($c1 eq '_') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '_' and $$rstr =~ m/\G(__(?:DATA|END)__\b)/gc) {
        if ($wants_doc) {
          ($token, $token_desc, $token_type) = ($1, 'END_OF_CODE', '');
          next;
        } else {
          $c->{ended} = 1;
          last;
        }
      }
    } elsif ($c1 eq '#') {
      if ($$rstr =~ m{\G($re_comment)}gcs) {
        ($token, $token_desc, $token_type) = ($1, 'COMMENT', '') if $wants_doc;
        $line_top = 1;
        next;
      }
    } elsif ($c1 eq ';') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, ';', ';');
      $current_scope |= F_SENTENCE_END|F_EXPR_END;
      next;
    } elsif ($c1 eq '$') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '#') {
        if (substr($$rstr, $pos + 2, 1) eq '{') {
          if ($$rstr =~ m{\G(\$\#\{[\w\s]+\})}gc) {
            ($token, $token_desc, $token_type) = ($1, '$#{NAME}', 'TERM');
            next;
          } else {
            pos($$rstr) = $pos + 3;
            ($token, $token_desc, $token_type) = ('$#{', '$#{', 'TERM');
            $stack = [$token, $pos, 'VARIABLE'];
            next;
          }
        } elsif ($$rstr =~ m{\G(\$\#(?:$re_namespace))}gc) {
          ($token, $token_desc, $token_type) = ($1, '$#NAME', 'TERM');
          next;
        } elsif ($prev_token_type eq 'ARROW') {
          my $c3 = substr($$rstr, $pos + 2, 1);
          if ($c3 eq '*') {
            pos($$rstr) = $pos + 3;
            ($token, $token_desc, $token_type) = ('$#*', 'VARIABLE', 'VARIABLE');
            next;
          }
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('$#', 'SPECIAL_VARIABLE', 'TERM');
          next;
        }
      } elsif ($c2 eq '$') {
        if ($$rstr =~ m{\G(\$(?:\$)+(?:$re_namespace))}gc) {
          ($token, $token_desc, $token_type) = ($1, '$$NAME', 'VARIABLE');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('$$', 'SPECIAL_VARIABLE', 'TERM');
          next;
        }
      } elsif ($c2 eq '{') {
        if ($$rstr =~ m{\G(\$\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '${NAME}', 'VARIABLE');
          if ($prev_token_type eq 'KEYWORD' and $expects_fh_or_block_list{$prev_token}) {
            $token_type = '';
            next;
          }
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('${', '${', 'VARIABLE');
          $stack = [$token, $pos, 'VARIABLE'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } elsif ($$rstr =~ m{$g_re_scalar_variable}gc) {
        ($token, $token_desc, $token_type) = ($1, '$NAME', 'VARIABLE');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'VARIABLE');
        next;
      }
    } elsif ($c1 eq '@') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '_' and $$rstr =~ m{\G\@_\b}gc) {
        ($token, $token_desc, $token_type) = ('@_', 'SPECIAL_VARIABLE', 'VARIABLE');
        next;
      } elsif ($c2 eq '{') {
        if ($$rstr =~ m{\G(\@\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '@{NAME}', 'VARIABLE');
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('@{', '@{', 'VARIABLE');
          $stack = [$token, $pos, 'VARIABLE'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } elsif ($c2 eq '$') {
        if ($$rstr =~ m{\G(\@\$(?:$re_namespace))}gc) {
          ($token, $token_desc, $token_type) = ($1, '@$NAME', 'VARIABLE');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('@$', '@$', 'VARIABLE');
          next;
        }
      } elsif ($prev_token_type eq 'ARROW') {
        # postderef
        if ($c2 eq '*') {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('@*', '@*', 'VARIABLE');
          next;
        } else {
          pos($$rstr) = $pos + 1;
          ($token, $token_desc, $token_type) = ('@', '@', 'VARIABLE');
          next;
        }
      } elsif ($c2 eq '[') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('@[', 'SPECIAL_VARIABLE', 'VARIABLE');
        next;
      } elsif ($$rstr =~ m{\G(\@(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '@NAME', 'VARIABLE');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'VARIABLE');
        next;
      }
    } elsif ($c1 eq '%') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '{') {
        if ($$rstr =~ m{\G(\%\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '%{NAME}', 'VARIABLE');
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('%{', '%{', 'VARIABLE');
          $stack = [$token, $pos, 'VARIABLE'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('%=', '%=', 'OP');
        next;
      } elsif ($$rstr =~ m{\G(\%\$(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '%$NAME', 'VARIABLE');
        next;
      } elsif ($$rstr =~ m{\G(\%(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '%NAME', 'VARIABLE');
        next;
      } elsif ($prev_token_type eq 'VARIABLE' or $prev_token_type eq 'TERM') {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      } elsif ($prev_token_type eq 'ARROW') {
        if ($c2 eq '*') {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('%*', '%*', 'VARIABLE');
          next;
        } else {
          pos($$rstr) = $pos + 1;
          ($token, $token_desc, $token_type) = ('%', '%', 'VARIABLE');
          next;
        }
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'VARIABLE');
        next;
      }
    } elsif ($c1 eq '*') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '{') {
        if ($$rstr =~ m{\G(\*\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '*{NAME}', 'VARIABLE');
          if ($prev_token eq 'KEYWORD' and $expects_fh_or_block_list{$prev_token}) {
            $token_type = '';
            next;
          }
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('*{', '*{', 'VARIABLE');
          $stack = [$token, $pos, 'VARIABLE'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } elsif ($c2 eq '*') {
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('**=', '**=', 'OP');
          next;
        } elsif ($prev_token_type eq 'ARROW') {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('**', '**', 'VARIABLE');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('**', '**', 'OP');
          next;
        }
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('*=', '*=', 'OP');
        next;
      } elsif ($$rstr =~ m{\G(\*(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '*NAME', 'VARIABLE');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '&') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '&') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('&&', '&&', 'OP');
        next;
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('&=', '&=', 'OP');
        next;
      } elsif ($c2 eq '{') {
        if ($$rstr =~ m{\G(\&\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '&{NAME}', 'TERM');
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('&{', '&{', 'TERM');
          $stack = [$token, $pos, 'FUNC'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } elsif ($$rstr =~ m{\G(\&(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '&NAME', 'TERM');
        next;
      } elsif ($$rstr =~ m{\G(\&\$(?:$re_namespace))}gc) {
        ($token, $token_desc, $token_type) = ($1, '&$NAME', 'TERM');
        next;
      } elsif ($prev_token_type eq 'ARROW') {
        if ($c2 eq '*') {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('&*', '&*', 'VARIABLE');
          next;
        }
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '\\') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '{') {
        if ($$rstr =~ m{\G(\\\{[\w\s]+\})}gc) {
          ($token, $token_desc, $token_type) = ($1, '\\{NAME}', 'VARIABLE');
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('\\{', '\\{', 'VARIABLE');
          $stack = [$token, $pos, 'VARIABLE'];
        }
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
        }
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, '');
        next;
      }
    } elsif ($c1 eq '-') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '>') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('->', 'ARROW', 'ARROW');
        if ($prev_token_type eq 'WORD' or $prev_token_type eq 'KEYWORD') {
          $caller_package = $prev_token;
          $current_scope |= F_KEEP_TOKENS;
        }
        next;
      } elsif ($c2 eq '-') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('--', '--', $prev_token_type);
        next;
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('-=', '-=', 'OP');
        next;
      } elsif ($$rstr =~ m{\G(\-[ABCMORSTWXbcdefgkloprstuwxz]\b)}gc) {
        ($token, $token_desc, $token_type) = ($1, 'FILE_TEST', 'TERM');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq q{"}) {
      if ($$rstr =~ m{\G(?:\"($re_str_in_double_quotes)\")}gcs) {
        ($token, $token_desc, $token_type) = ([$1, q{"}], 'STRING', 'STRING');
        next;
      }
    } elsif ($c1 eq q{'}) {
      if ($$rstr =~ m{\G(?:\'($re_str_in_single_quotes)\')}gcs) {
        ($token, $token_desc, $token_type) = ([$1, q{'}], 'STRING', 'STRING');
        next;
      }
    } elsif ($c1 eq '`') {
      if ($$rstr =~ m{\G(?:\`($re_str_in_backticks)\`)}gcs) {
        ($token, $token_desc, $token_type) = ([$1, q{`}], 'BACKTICK', 'TERM');
        next;
      }
    } elsif ($c1 eq '/') {
      if ($prev_token_type eq '' or $prev_token_type eq 'OP' or ($prev_token_type eq 'KEYWORD' and $regexp_may_follow{$prev_token})) { # undoubtedly regexp
        if (my $regexp = $self->_match_regexp0($c, $rstr, $pos, 'm')) {
          ($token, $token_desc, $token_type) = ($regexp, 'REGEXP', 'TERM');
          next;
        } else {
          # the above may fail
          _debug("REGEXP ERROR: $@") if !!DEBUG;
          pos($$rstr) = $pos;
        }
      }
      if (($prev_token_type eq '' or (!($current_scope & F_EXPR) and $prev_token_type eq 'WORD')) or ($prev_token_type eq 'KEYWORD' and @keywords and $prev_token eq $keywords[-1])) {
        if (my $regexp = $self->_match_regexp0($c, $rstr, $pos)) {
          ($token, $token_desc, $token_type) = ($regexp, 'REGEXP', 'TERM');
          next;
        } else { 
          # the above may fail
          _debug("REGEXP ERROR: $@") if !!DEBUG;
          pos($$rstr) = $pos;
        }
      }
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '/') {
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('//=', '//=', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('//', '//', 'OP');
          next;
        }
      }
      if ($c2 eq '=') { # this may be a part of /=.../
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('/=', '/=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '{') {
      if ($$rstr =~ m{$g_re_hash_shortcut}gc) {
        ($token, $token_desc) = ($1, '{TERM}');
        if ($parent_scope & F_EXPECTS_BRACKET) {
          $current_scope |= F_SCOPE_END;
          next;
        }
        if ($prev_token_type eq 'ARROW' or $prev_token_type eq 'VARIABLE') {
          $token_type = 'VARIABLE';
          next;
        } elsif ($waiting_for_a_block) {
          $waiting_for_a_block = 0;
          next;
        } elsif ($prev_token_type eq 'KEYWORD' and exists $expects_fh_or_block_list{$prev_token}) {
          $token_type = '';
          next;
        } else {
          $token_type = 'TERM';
          next;
        }
      }
      pos($$rstr) = $pos + 1;
      ($token, $token_desc) = ($c1, $c1);
      my $stack_owner;
      if (@keywords) {
        for(my $i = @keywords; $i > 0; $i--) {
          my $keyword = $keywords[$i - 1];
          if (exists $expects_block{$keyword}) {
            $stack_owner = $keyword;
            last;
          }
        }
      }
      $stack = [$token, $pos, $stack_owner || ''];
      if ($parent_scope & F_EXPECTS_BRACKET) {
        $current_scope |= F_SCOPE_END|F_SENTENCE_END|F_EXPR_END;
        next;
      }
      if ($prev_token_type eq 'ARROW' or $prev_token_type eq 'VARIABLE') {
        $token_type = 'VARIABLE';
      } elsif ($waiting_for_a_block) {
        $waiting_for_a_block = 0;
      } else {
        $token_type = (($current_scope | $parent_scope) & F_KEEP_TOKENS) ? 'TERM' : '';
      }
      next;
    } elsif ($c1 eq '[') {
      if ($$rstr =~ m{\G(\[(?:$re_nonblock_chars)\])}gc) {
        ($token, $token_desc, $token_type) = ($1, '[TERM]', 'VARIABLE');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'VARIABLE');
        $stack = [$token, $pos, 'VARIABLE'];
        next;
      }
    } elsif ($c1 eq '(') {
      if ($waiting_for_a_block and @keywords and $keywords[-1] eq 'sub' and $$rstr =~ m{$g_re_prototype}gc) {
        ($token, $token_desc, $token_type) = ($1, '(PROTOTYPE)', '');
        next;
      } elsif ($$rstr =~ m{\G\(((?:$re_nonblock_chars)(?<!\$))\)}gc) {
        ($token, $token_desc, $token_type) = ([[[$1, 'TERM']]], '()', 'TERM');
        if ($prev_token_type eq 'KEYWORD' and @keywords and $keywords[-1] eq $prev_token and !exists $expects_expr_block{$prev_token}) {
          pop @keywords;
        }
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'TERM');
        my $stack_owner;
        if (@keywords) {
          for (my $i = @keywords; $i > 0; $i--) {
            my $keyword = $keywords[$i - 1];
            if (exists $expects_block{$keyword}) {
              $stack_owner = $keyword;
              last;
            }
          }
        }
        $stack = [$token, $pos, $stack_owner || ''];
        next;
      }
    } elsif ($c1 eq '}') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, $c1, '');
      $unstack = $token;
      $current_scope |= F_SENTENCE_END|F_EXPR_END;
      next;
    } elsif ($c1 eq ']') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, $c1, '');
      $unstack = $token;
      next;
    } elsif ($c1 eq ')') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, $c1, '');
      $unstack = $token;
      next;
    } elsif ($c1 eq '<') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '<'){
        if ($$rstr =~ m{\G<<\s*(?:
          [A-Za-z_][\w]* |
          "(?:[^\\"]*(?:\\.[^\\"]*)*)" |
          '(?:[^\\']*(?:\\.[^\\']*)*)' |
          `(?:[^\\`]*(?:\\.[^\\`]*)*)`
        )}sx) {
          if (my $heredoc = $self->_match_heredoc($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($heredoc, 'HEREDOC', 'TERM');
            next;
          } else {
            # the above may fail
            pos($$rstr) = $pos;
          }
        }
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('<<=', '<<=', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('<<', '<<', 'OP');
          next;
        }
      } elsif ($c2 eq '=') {
        if (substr($$rstr, $pos + 2, 1) eq '>') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('<=>', '<=>', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('<=', '<=', 'OP');
          next;
        }
      } elsif ($c2 eq '>') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('<>', '<>', 'OP');
        next;
      } elsif ($$rstr =~ m{\G(<(?:
        \\. |
        \w+ |
        [./-] |
        \[[^\]]*\] |
        \{[^\}]*\} |
        \* |
        \? |
        \~ |
        \$ |
      )*(?<!\-)>)}gcx) {
        ($token, $token_desc, $token_type) = ($1, '<NAME>', 'TERM');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq ':') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq ':') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('::', '::', '');
        next;
      }
      if ($waiting_for_a_block and @keywords and $keywords[-1] eq 'sub') {
        while($$rstr =~ m{\G(:?[\w\s]+)}gcs) {
          my $startpos = pos($$rstr);
          if (substr($$rstr, $startpos, 1) eq '(') {
            my @nest = '(';
            pos($$rstr) = $startpos + 1;
            my ($p, $c1);
            while(defined($p = pos($$rstr))) {
              $c1 = substr($$rstr, $p, 1);
              if ($c1 eq '\\') {
                pos($$rstr) = $p + 2;
                next;
              }
              if ($c1 eq ')') {
                pop @nest;
                pos($$rstr) = $p + 1;
                last unless @nest;
              }
              if ($c1 eq '(') {
                push @nest, $c1;
                pos($$rstr) = $p + 1;
                next;
              }
              $$rstr =~ m{\G([^\\()]+)}gc and next;
            }
          }
        }
        ($token, $token_desc, $token_type) = (substr($$rstr, $pos, pos($$rstr) - $pos), 'ATTRIBUTE', '');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '=') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '>') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('=>', 'COMMA', 'OP');
        if (@keywords and $prev_token_type eq 'KEYWORD' and $keywords[-1] eq $prev_token) {
          pop @keywords;
          if (!@keywords and ($current_scope & F_KEEP_TOKENS)) {
            $current_scope &= MASK_KEEP_TOKENS;
            @tokens = ();
          }
        }
        next;
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('==', '==', 'OP');
        next;
      } elsif ($c2 eq '~') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('=~', '=~', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '>') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '>') {
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('>>=', '>>=', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('>>', '>>', 'OP');
          next;
        }
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('>=', '>=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '+') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '+') {
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('++=', '++=', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('++', '++', $prev_token_type);
          next;
        }
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('+=', '+=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '|') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '|') {
        if (substr($$rstr, $pos + 2, 1) eq '=') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('||=', '||=', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('||', '||', 'OP');
          next;
        }
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('|=', '|=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '^') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('^=', '^=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '!') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '~') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('!~', '!~', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '~') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '~') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('~~', '~~', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq ',') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, 'COMMA', 'OP');
      next;
    } elsif ($c1 eq '?') {
      pos($$rstr) = $pos + 1;
      ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
      next;
    } elsif ($c1 eq '.') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq '.') {
        if (substr($$rstr, $pos + 2, 1) eq '.') {
          pos($$rstr) = $pos + 3;
          ($token, $token_desc, $token_type) = ('...', '...', 'OP');
          next;
        } else {
          pos($$rstr) = $pos + 2;
          ($token, $token_desc, $token_type) = ('..', '..', 'OP');
          next;
        }
      } elsif ($c2 eq '=') {
        pos($$rstr) = $pos + 2;
        ($token, $token_desc, $token_type) = ('.=', '.=', 'OP');
        next;
      } else {
        pos($$rstr) = $pos + 1;
        ($token, $token_desc, $token_type) = ($c1, $c1, 'OP');
        next;
      }
    } elsif ($c1 eq '0') {
      my $c2 = substr($$rstr, $pos + 1, 1);
      if ($c2 eq 'x') {
        if ($$rstr =~ m{\G(0x[0-9A-Fa-f_]+)}gc) {
          ($token, $token_desc, $token_type) = ($1, 'HEX NUMBER', 'TERM');
          next;
        }
      } elsif ($c2 eq 'b') {
        if ($$rstr =~ m{\G(0b[01_]+)}gc) {
          ($token, $token_desc, $token_type) = ($1, 'BINARY NUMBER', 'TERM');
          next;
        }
      }
    }

    if ($$rstr =~ m{\G((?:0|[1-9][0-9_]*)(?:\.[0-9][0-9_]*)?)}gc) {
      my $number = $1;
      my $p = pos($$rstr);
      my $n1 = substr($$rstr, $p, 1);
      if ($n1 eq '.') {
        if ($$rstr =~ m{\G((?:\.[0-9_])+)}gc) {
          $number .= $1;
          ($token, $token_desc, $token_type) = ($number, 'VERSION_STRING', 'TERM');
          next;
        } elsif (substr($$rstr, $p, 2) ne '..') {
          $number .= '.';
          pos($$rstr) = $p + 1;
        }
      } elsif ($n1 eq 'E' or $n1 eq 'e') {
        if ($$rstr =~ m{\G([Ee][+-]?[0-9]+)}gc) {
          $number .= $1;
        }
      }
      ($token, $token_desc, $token_type) = ($number, 'NUMBER', 'TERM');
      if ($prepend) {
        $token = "$prepend$token";
        pop @tokens if @tokens and $tokens[-1][0] eq $prepend;
        pop @scope_tokens if @scope_tokens and $scope_tokens[-1][0] eq $prepend;
      }
      next;
    }

    if ($prev_token_type ne 'ARROW' and ($prev_token_type ne 'KEYWORD' or !exists $expects_word{$prev_token})) {
      if ($prev_token_type eq 'TERM' or $prev_token_type eq 'VARIABLE') {
        if ($c1 eq 'x') {
          if ($$rstr =~ m{\G(x\b(?!\s*=>))}gc){
            ($token, $token_desc, $token_type) = ($1, $1, '');
            next;
          }
        }
      }

      if ($c1 eq 'q') {
        if ($$rstr =~ m{\G((?:qq?)\b(?!\s*=>))}gc) {
          if (my $quotelike = $self->_match_quotelike($c, $rstr, $1)) {
            ($token, $token_desc, $token_type) = ($quotelike, 'STRING', 'STRING');
            next;
          } else {
            _debug("QUOTELIKE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        } elsif ($$rstr =~ m{\G((?:qw)\b(?!\s*=>))}gc) {
          if (my $quotelike = $self->_match_quotelike($c, $rstr, $1)) {
            ($token, $token_desc, $token_type) = ($quotelike, 'QUOTED_WORD_LIST', 'TERM');
            next;
          } else {
            _debug("QUOTELIKE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        } elsif ($$rstr =~ m{\G((?:qx)\b(?!\s*=>))}gc) {
          if (my $quotelike = $self->_match_quotelike($c, $rstr, $1)) {
            ($token, $token_desc, $token_type) = ($quotelike, 'BACKTICK', 'TERM');
            next;
          } else {
            _debug("QUOTELIKE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        } elsif ($$rstr =~ m{\G(qr\b(?!\s*=>))}gc) {
          if (my $regexp = $self->_match_regexp($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($regexp, 'qr', 'TERM');
            next;
          } else {
            _debug("QUOTELIKE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        }
      } elsif ($c1 eq 'm') {
        if ($$rstr =~ m{\G(m\b(?!\s*=>))}gc) {
          if (my $regexp = $self->_match_regexp($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($regexp, 'm', 'TERM');
            next;
          } else {
            _debug("REGEXP ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        }
      } elsif ($c1 eq 's') {
        if ($$rstr =~ m{\G(s\b(?!\s*=>))}gc) {
          if (my $regexp = $self->_match_substitute($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($regexp, 's', 'TERM');
            next;
          } else {
            _debug("SUBSTITUTE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        }
      } elsif ($c1 eq 't') {
        if ($$rstr =~ m{\G(tr\b(?!\s*=>))}gc) {
          if (my $trans = $self->_match_transliterate($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($trans, 'tr', 'TERM');
            next;
          } else {
            _debug("TRANSLITERATE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        }
      } elsif ($c1 eq 'y') {
        if ($$rstr =~ m{\G(y\b(?!\s*=>))}gc) {
          if (my $trans = $self->_match_transliterate($c, $rstr)) {
            ($token, $token_desc, $token_type) = ($trans, 'y', 'TERM');
            next;
          } else {
            _debug("TRANSLITERATE ERROR: $@") if !!DEBUG;
            pos($$rstr) = $pos;
          }
        }
      }
    }

    if ($$rstr =~ m{\G(\w+)}gc) {
      $token = $1;
      if ($prev_token_type eq 'ARROW') {
        $$rstr =~ m{\G((?:(?:::|')\w+)+)\b}gc and $token .= $1;
        ($token_desc, $token_type) = ('METHOD', 'METHOD');
      } elsif ($token eq 'CORE') {
        ($token_desc, $token_type) = ('NAMESPACE', 'WORD');
      } elsif ($token eq 'format') {
        if ($$rstr =~ m{\G(.*?\n.*?\n\.\n)}gcs) {
          $token .= $1;
          ($token_desc, $token_type) = ('FORMAT', '');
          $current_scope |= F_SENTENCE_END|F_EXPR_END;
          next;
        }
      } elsif (exists $defined_keywords{$token} and ($prev_token_type ne 'KEYWORD' or !$expects_word{$prev_token}) or ($prev_token eq 'sub' and $token eq 'BEGIN')) {
        ($token_desc, $token_type) = ('KEYWORD', 'KEYWORD');
        push @keywords, $token unless $token eq 'undef';
      } else {
        if ($c1 eq 'v' and $token =~ /^v(?:0|[1-9][0-9]*)$/) {
          if ($$rstr =~ m{\G((?:\.[0-9][0-9_]*)+)}gc) {
            $token .= $1;
            ($token_desc, $token_type) = ('VERSION_STRING', 'TERM');
            next;
          }
        }
        $$rstr =~ m{\G((?:(?:::|')\w+)+)\b}gc and $token .= $1;
        ($token_desc, $token_type) = ('WORD', 'WORD');
        if ($prepend) {
          $token = "$prepend$token";
          pop @tokens if @tokens and $tokens[-1][0] eq $prepend;
          pop @scope_tokens if @scope_tokens and $scope_tokens[-1][0] eq $prepend;
        }
      }
      next;
    }

    # ignore control characters
    if ($$rstr =~ m{\G([[:cntrl:]]+)}gc) {
      next;
    }

    if ($$rstr =~ m{\G([[:ascii:]]+)}gc) {
      last if $parent_scope & F_STRING_EVAL;
      _error("UNKNOWN: $1");
      push @{$c->{errors}}, qq{"$1"};
      $token = $1;
      next;
    }
    if ($$rstr =~ m{\G([[:^ascii:]](?:[[:^ascii:]]|\w)*)}gc) {
      if (!$c->{utf8}) {
        last if $parent_scope & F_STRING_EVAL;
        _error("UNICODE?: $1");
        push @{$c->{errors}}, qq{"$1"};
      } else {
        _debug("UTF8: $1") if !!DEBUG;
      }
      $token = $1;
      next;
    }
    if ($$rstr =~ m{\G(\S+)}gc) {
      last if $parent_scope & F_STRING_EVAL;
      _error("UNEXPECTED: $1");
      push @{$c->{errors}}, qq{"$1"};
      $token = $1;
    }

    last;
  } continue {
    if (defined $token) {
      if (!($current_scope & F_EXPR)) {
        _debug('BEGIN EXPR') if !!DEBUG;
        $current_scope |= F_EXPR;
      } elsif (($current_scope & F_EXPR) and (($current_scope & F_EXPR_END) or $ends_expr{$token})) {
        @keywords = ();
        _debug('END EXPR') if !!DEBUG;
        $current_scope &= MASK_EXPR_END;
      }
      $prepend = undef;

      if (!!DEBUG) {
        my $token_str = ref $token ? Data::Dump::dump($token) : $token;
        _debug("GOT: $token_str ($pos) TYPE: $token_desc ($token_type)".($prev_token_type ? " PREV: $prev_token_type" : '').(@keywords ? " KEYWORD: @keywords" : '').(($current_scope | $parent_scope) & F_EVAL ? ' EVAL' : '').(($current_scope | $parent_scope) & F_KEEP_TOKENS ? ' KEEP' : ''));
      }

      if ($parent_scope & F_KEEP_TOKENS) {
        push @scope_tokens, [$token, $token_desc];
        if ($token eq '-' or $token eq '+') {
          $prepend = $token;
        }
      }
      if (!($current_scope & F_KEEP_TOKENS) and (exists $c->{callback}{$token} or exists $c->{keyword}{$token}) and $token_type ne 'METHOD') {
        $current_scope |= F_KEEP_TOKENS;
      }
      if (exists $expects_block{$token}) {
        $waiting_for_a_block = 1;
      }
      if ($current_scope & F_EVAL or ($parent_scope & F_EVAL and (!@{$c->{stack}} or $c->{stack}[-1][0] ne '{'))) {
        if ($token_type eq 'STRING') {
          if ($token->[0] =~ /\b(?:(?:use|no)\s+[A-Za-z]|require\s+(?:q[qw]?.|['"])?[A-Za-z])/) {
            my $eval_string = $token->[0];
            if (defined $eval_string and $eval_string ne '') {
              $eval_string =~ s/\\(.)/$1/g;
              pos($eval_string) = 0;
              $c->{eval} = 1;
              my $saved_stack = $c->{stack};
              $c->{stack} = [];
              eval { $self->_scan($c, \$eval_string, (
                ($current_scope | $parent_scope | F_STRING_EVAL) &
                F_RESCAN
              ))};
              $c->{stack} = $saved_stack;
            }
          }
          $current_scope &= MASK_EVAL;
        } elsif ($token_desc eq 'HEREDOC') {
          if ($token->[0] =~ /\b(?:use|require|no)\s+[A-Za-z]/) {
            my $eval_string = $token->[0];
            if (defined $eval_string and $eval_string ne '') {
              $eval_string =~ s/\\(.)/$1/g;
              pos($eval_string) = 0;
              $c->{eval} = 1;
              my $saved_stack = $c->{stack};
              $c->{stack} = [];
              eval { $self->_scan($c, \$eval_string, (
                ($current_scope | $parent_scope | F_STRING_EVAL) &
                F_RESCAN
              ))};
              $c->{stack} = $saved_stack;
            }
          }
          $current_scope &= MASK_EVAL;
        }
        $c->{eval} = ($current_scope | $parent_scope) & F_EVAL ? 1 : 0;
      }
      if ($token eq 'eval') {
        $current_scope |= F_EVAL;
        $c->{eval} = 1;
      }

      if ($current_scope & F_KEEP_TOKENS) {
        push @tokens, [$token, $token_desc];
        if ($token eq '-' or $token eq '+') {
          $prepend = $token;
        }
        if ($token_type eq 'KEYWORD' and $has_sideff{$token}) {
          $current_scope |= F_SIDEFF;
        }
      }
      if ($stack) {
        push @{$c->{stack}}, $stack;
        _dump_stack($c, $stack->[0]) if !!DEBUG;
        my $child_scope = $current_scope | $parent_scope;
        if ($token eq '{' and $is_conditional{$stack->[2]}) {
          $child_scope |= F_CONDITIONAL
        }
        my $scanned_tokens = $self->_scan($c, $rstr, (
          $child_scope & F_RESCAN
        ));
        if ($token eq '{' and $current_scope & F_EVAL) {
          $current_scope &= MASK_EVAL;
          $c->{eval} = ($current_scope | $parent_scope) & F_EVAL ? 1 : 0;
        }
        if ($current_scope & F_KEEP_TOKENS) {
          my $start = pop @tokens || '';
          my $end = pop @$scanned_tokens || '';
          push @tokens, [$scanned_tokens, "$start->[0]$end->[0]"];
        } elsif ($parent_scope & F_KEEP_TOKENS) {
          my $start = pop @scope_tokens || '';
          my $end = pop @$scanned_tokens || '';
          push @scope_tokens, [$scanned_tokens, "$start->[0]$end->[0]"];
        }

        if ($stack->[0] eq '(' and $prev_token_type eq 'KEYWORD' and @keywords and $keywords[-1] eq $prev_token and !exists $expects_expr_block{$prev_token}) {
          pop @keywords;
        }

        if ($stack->[0] eq '{' and @keywords and exists $expects_block{$keywords[0]} and !exists $expects_block_list{$keywords[-1]}) {
          $current_scope |= F_SENTENCE_END unless @tokens and ($keywords[-1] eq 'sub' or $keywords[-1] eq 'eval');
        }
        $stack = undef;
      }
      if ($unstack and @{$c->{stack}}) {
        my $stacked = pop @{$c->{stack}};
        my $stacked_type = substr($stacked->[0], -1);
        if (
          ($unstack eq '}' and $stacked_type ne '{') or
          ($unstack eq ']' and $stacked_type ne '[') or
          ($unstack eq ')' and $stacked_type ne '(')
        ) {
          my $prev_pos = $stacked->[1] || 0;
          die "mismatch $stacked_type $unstack\n" .
              substr($$rstr, $prev_pos, pos($$rstr) - $prev_pos);
        }
        _dump_stack($c, $unstack) if !!DEBUG;
        $current_scope |= F_SCOPE_END;
        $unstack = undef;
      }

      if ($current_scope & F_SENTENCE_END) {
        if (($current_scope & F_KEEP_TOKENS) and @tokens) {
          my $first_token = $tokens[0][0];
          if ($first_token eq '->') {
            $first_token = $tokens[1][0];
            # ignore ->use and ->no
            # ->require may be from UNIVERSAL::require
            if ($first_token eq 'use' or $first_token eq 'no') {
              $first_token = '';
            }
          }
          my $cond = (($current_scope | $parent_scope) & (F_CONDITIONAL|F_SIDEFF)) ? 1 : 0;
          if (exists $c->{callback}{$first_token}) {
            $c->{current_scope} = \$current_scope;
            $c->{cond} = $cond;
            $c->{callback}{$first_token}->($c, $rstr, \@tokens);
          }
          if (exists $c->{keyword}{$first_token}) {
            $c->{current_scope} = \$current_scope;
            $c->{cond} = $cond;
            $c->run_callback_for(keyword => $first_token, \@tokens);
          }
          if (exists $c->{method}{$first_token} and $caller_package) {
            unshift @tokens, [$caller_package, 'WORD'];
            $c->{current_scope} = \$current_scope;
            $c->{cond} = $cond;
            $c->run_callback_for(method => $first_token, \@tokens);
          }
        }
        @tokens = ();
        @keywords = ();
        $current_scope &= MASK_SENTENCE_END;
        $caller_package = undef;
        $token = $token_type = '';
        _debug('END SENTENSE') if !!DEBUG;
      }

      last if $current_scope & F_SCOPE_END;
      last if $c->{ended};

      ($prev_token, $prev_token_type) = ($token, $token_type);
    }

    if (@{$c->{errors}} and !($parent_scope & F_STRING_EVAL)) {
      my $rest = substr($$rstr, pos($$rstr));
      _error("REST:\n\n".$rest) if $rest;
      last;
    }
  }

  if (@tokens) {
    if (my $first_token = $tokens[0][0]) {
      if (exists $c->{callback}{$first_token}) {
        $c->{callback}{$first_token}->($c, $rstr, \@tokens);
      }
      if (exists $c->{keyword}{$first_token}) {
        $c->run_callback_for(keyword => $first_token, \@tokens);
      }
    }
  }

  _dump_stack($c, "END SCOPE") if !!DEBUG;

  \@scope_tokens;
}

sub _match_quotelike {
  my ($self, $c, $rstr, $op) = @_;

  # '#' only works when it comes just after the op,
  # without prepending spaces
  $$rstr =~ m/\G(?:\s(?:$re_comment))?\s*/gcs;

  unless ($$rstr =~ m/\G(\S)/gc) {
    return _match_error($rstr, "No block delimiter found after $op");
  }
  my $ldel = $1;
  my $startpos = pos($$rstr);

  if ($ldel =~ /[[(<{]/) {
    my ($rdel, $re_skip) = _gen_rdel_and_re_skip($ldel);
    my @nest = ($ldel);
    my ($p, $c1);
    while(defined($p = pos($$rstr))) {
      $c1 = substr($$rstr, $p, 1);
      if ($c1 eq '\\') {
        pos($$rstr) = $p + 2;
        next;
      }
      if ($c1 eq $ldel) {
        pos($$rstr) = $p + 1;
        push @nest, $ldel;
        next;
      }
      if ($c1 eq $rdel) {
        pos($$rstr) = $p + 1;
        pop @nest;
        last unless @nest;
        next;
      }
      $$rstr =~ m{\G$re_skip}gc and next;
      last;
    }
    return if @nest;
  } else {
    my $re = _gen_re_str_in_delims_with_end_delim($ldel);
    $$rstr =~ /\G$re/gcs or return;
  }

  my $endpos = pos($$rstr);

  return [substr($$rstr, $startpos, $endpos - $startpos - 1), $op];
}

sub _match_regexp0 { # //
  my ($self, $c, $rstr, $startpos, $token_type) = @_;
  pos($$rstr) = $startpos + 1;

  my $re_shortcut = _gen_re_regexp_shortcut('/');
  $$rstr =~ m{\G$re_shortcut}gcs or  # shortcut
  defined($self->_scan_re($c, $rstr, '/', '/', $token_type ? 'm' : '')) or return _match_error($rstr, "Closing delimiter was not found: $@");

  $$rstr =~ m/\G([msixpodualgc]*)/gc;
  my $mod = $1;

  my $endpos = pos($$rstr);

  my $re = substr($$rstr, $startpos, $endpos - $startpos);
  if ($re =~ /\n/s and $mod !~ /x/) {
    return _match_error($rstr, "multiline without x");
  }
  return $re;
}

sub _match_regexp {
  my ($self, $c, $rstr) = @_;
  my $startpos = pos($$rstr) || 0;

  # '#' only works when it comes just after the op,
  # without prepending spaces
  $$rstr =~ m/\G(?:\s(?:$re_comment))?\s*/gcs;

  unless ($$rstr =~ m/\G(\S)/gc) {
    return _match_error($rstr, "No block delimiter found");
  }
  my ($ldel, $rdel) = ($1, $1);

  if ($ldel =~ /[[(<{]/) {
    $rdel =~ tr/[({</])}>/;
  }

  my $re_shortcut = _gen_re_regexp_shortcut($ldel, $rdel);
  $$rstr =~ m{\G$re_shortcut}gcs or  # shortcut
  defined($self->_scan_re($c, $rstr, $ldel, $rdel, 'm/qr')) or return _match_error($rstr, "Closing delimiter was not found: $@");

  # strictly speaking, qr// doesn't support gc.
  $$rstr =~ m/\G[msixpodualgc]*/gc;
  my $endpos = pos($$rstr);

  return substr($$rstr, $startpos, $endpos - $startpos);
}

sub _match_substitute {
  my ($self, $c, $rstr) = @_;
  my $startpos = pos($$rstr) || 0;

  # '#' only works when it comes just after the op,
  # without prepending spaces
  $$rstr =~ m/\G(?:\s(?:$re_comment))?\s*/gcs;

  unless ($$rstr =~ m/\G(\S)/gc) {
    return _match_error($rstr, "No block delimiter found");
  }
  my ($ldel1, $rdel1) = ($1, $1);

  if ($ldel1 =~ /[[(<{]/) {
    $rdel1 =~ tr/[({</])}>/;
  }

  my $re_shortcut = _gen_re_regexp_shortcut($ldel1, $rdel1);
  ($ldel1 ne '\\' and $$rstr =~ m{\G$re_shortcut}gcs) or  # shortcut
  defined($self->_scan_re($c, $rstr, $ldel1, $rdel1, 's')) or return _match_error($rstr, "Closing delimiter was not found: $@");
  defined($self->_scan_re2($c, $rstr, $ldel1, 's')) or return;
  $$rstr =~ m/\G[msixpodualgcer]*/gc;
  my $endpos = pos($$rstr);

  return substr($$rstr, $startpos, $endpos - $startpos);
}

sub _match_transliterate {
  my ($self, $c, $rstr) = @_;
  my $startpos = pos($$rstr) || 0;

  # '#' only works when it comes just after the op,
  # without prepending spaces
  $$rstr =~ m/\G(?:\s(?:$re_comment))?\s*/gcs;

  unless ($$rstr =~ m/\G(\S)/gc) {
    return _match_error($rstr, "No block delimiter found");
  }
  my $ldel1 = $1;
  my $ldel2;

  if ($ldel1 =~ /[[(<{]/) {
    (my $rdel1 = $ldel1) =~ tr/[({</])}>/;
    my $re = _gen_re_str_in_delims_with_end_delim($rdel1);
    $$rstr =~ /\G$re/gcs or return;
    $$rstr =~ /\G(?:$re_comment)/gcs;
    unless ($$rstr =~ /\G\s*(\S)/gc) {
      return _match_error($rstr, "Missing second block");
    }
    $ldel2 = $1;
  } else {
    my $re = _gen_re_str_in_delims_with_end_delim($ldel1);
    $$rstr =~ /\G$re/gcs or return;
    $ldel2 = $ldel1;
  }

  if ($ldel2 =~ /[[(<{]/) {
    (my $rdel2 = $ldel2) =~ tr/[({</])}>/;
    my $re = _gen_re_str_in_delims_with_end_delim($rdel2);
    $$rstr =~ /\G$re/gcs or return;
  } else {
    my $re = _gen_re_str_in_delims_with_end_delim($ldel2);
    $$rstr =~ /\G$re/gcs or return;
  }

  $$rstr =~ m/\G[cdsr]*/gc;
  my $endpos = pos($$rstr);

  return substr($$rstr, $startpos, $endpos - $startpos);
}

sub _match_heredoc {
  my ($self, $c, $rstr) = @_;

  my $startpos = pos($$rstr) || 0;

  $$rstr =~ m{\G(<<\s*)}gc;

  my $label;
  if ($$rstr =~ m{\G([A-Za-z_]\w*)}gc) {
    $label = $1;
  } elsif ($$rstr =~ m{
      \G ' ($re_str_in_single_quotes) '
    | \G " ($re_str_in_double_quotes) "
    | \G ` ($re_str_in_backticks) `
  }gcsx) {
    $label = $+;
  } else {
    return;
  }
  $label =~ s/\\(.)/$1/g;
  my $extrapos = pos($$rstr);
  $$rstr =~ m{\G.*\n}gc;
  my $str1pos = pos($$rstr)--;
  unless ($$rstr =~ m{\G.*?\n(?=\Q$label\E\n)}gcs) {
    return _match_error($rstr, qq{Missing here doc terminator ('$label')});
  }
  my $ldpos = pos($$rstr);
  $$rstr =~ m{\G\Q$label\E\n}gc;
  my $ld2pos = pos($$rstr);

  my $heredoc = [
    substr($$rstr, $str1pos, $ldpos-$str1pos),
    substr($$rstr, $startpos, $extrapos-$startpos),
    substr($$rstr, $ldpos, $ld2pos-$ldpos),
  ];
  substr($$rstr, $str1pos, $ld2pos - $str1pos) = '';
  pos($$rstr) = $extrapos;
  return $heredoc;
}

sub _scan_re {
  my ($self, $c, $rstr, $ldel, $rdel, $op) = @_;
  my $startpos = pos($$rstr) || 0;

  _debug(" L $ldel R $rdel") if !!DEBUG_RE;

  my ($outer_opening_delimiter, $outer_closing_delimiter);
  if (@{$c->{stack}}) {
    ($outer_closing_delimiter = $outer_opening_delimiter = $c->{stack}[-1][0]) =~ tr/[({</])}>/;
  }

  my @nesting = ($ldel);
  my $multiline = 0;
  my $saw_sharp = 0;
  my $prev;
  my ($p, $c1);
  while (defined($p = pos($$rstr))) {
    $c1 = substr($$rstr, $p, 1);
    if ($c1 eq "\n") {
      $$rstr =~ m{\G\n\s*}gcs;
      $multiline = 1;
      $saw_sharp = 0;
      # _debug("CRLF") if !!DEBUG_RE;
      next;
    }
    if ($c1 eq ' ' or $c1 eq "\t") {
      $$rstr =~ m{\G\s*}gc;
      # _debug("WHITESPACE") if !!DEBUG_RE;
      next;
    }
    if ($c1 eq '#' and $rdel ne '#') {
      if ($multiline and $$rstr =~ m{\G(#[^\Q$rdel\E]*?)\n}gcs) {
        _debug(" comment $1") if !!DEBUG_RE
      } else {
        pos($$rstr) = $p + 1;
        $saw_sharp = 1;
        _debug(" saw #") if !!DEBUG_RE;
      }
      next;
    }

    if ($c1 eq '\\' and $rdel ne '\\') {
      if ($$rstr =~ m/\G(\\.)/gcs) {
        _debug(" escaped $1") if !!DEBUG_RE;
        next;
      }
    }

    _debug(" looking @nesting: $c1") if !!DEBUG_RE;

    if ($c1 eq '[') {
      # character class may have other (ignorable) delimiters
      if ($$rstr =~ m/\G(\[\[:\w+?:\]\])/gcs) {
        _debug(" character class $1") if !!DEBUG_RE;
        next;
      }
      if ($$rstr =~ m/\G(\[[^\\\]]]*?(\\.[^\\\]]]*)*\])/gcs) {
        _debug(" character class: $1") if !!DEBUG_RE;
        next;
      }
    }

    if ($c1 eq $rdel) {
      pos($$rstr) = $p + 1;
      if ($saw_sharp) {
        my $tmp_pos = $p + 1;
        if ($op eq 's') {
          _debug(" looking for latter part") if !!DEBUG_RE;
          my $latter = $self->_scan_re2($c, $rstr, $ldel, $op);
          if (!defined $latter) {
            pos($$rstr) = $tmp_pos;
            next;
          }
          _debug(" latter: $latter") if !!DEBUG_RE;
        }
        if ($$rstr =~ m/\G[a-wyz]*x/) {
          # looks like an end of block
          _debug(" end of block $rdel (after #)") if !!DEBUG_RE;
          @nesting = ();
          pos($$rstr) = $tmp_pos;
          last;
        }
        pos($$rstr) = $tmp_pos;
        if ($multiline) {
          next; # part of a comment
        }
      }
      _debug(" end of block $rdel") if !!DEBUG_RE;
      my $expected = $rdel;
      if ($ldel ne $rdel) {
        $expected =~ tr/)}]>/({[</;
      }
      while(my $nested = pop @nesting) {
        last if $nested eq $expected;
      }
      last unless @nesting;
      next;
    } elsif ($c1 eq $ldel) {
      pos($$rstr) = $p + 1;
      if ($multiline and $saw_sharp) {
      } else {
        _debug(" block $ldel") if !!DEBUG_RE;
        push @nesting, $ldel;
        next;
      }
    }

    if ($c1 eq '{') {
      # quantifier shouldn't be nested
      if ($$rstr =~ m/\G({[0-9]+(?:,(?:[0-9]+)?)?})/gcs) {
        _debug(" quantifier $1") if !!DEBUG_RE;
        next;
      }
    }

    if ($c1 eq '(') {
      my $c2 = substr($$rstr, $p + 1, 1);
      if ($c2 eq '?' and !($multiline and $saw_sharp)) {
        # code
        if ($$rstr =~ m/\G((\()\?+?)(?=\{)/gc) {
          _debug(" code $1") if !!DEBUG_RE;
          push @nesting, $2;
          unless (eval { $self->_scan($c, $rstr, F_EXPECTS_BRACKET); 1 }) {
            _debug("scan failed") if !!DEBUG_RE;
            return;
          }
          next;
        }
        # comment
        if ($$rstr =~ m{\G(\(\?\#[^\\\)]*(?:\\.[^\\\)]*)*\))}gcs) {
          _debug(" comment $1") if !!DEBUG_RE;
          next;
        }
      }

      # grouping may have (ignorable) <>
      if ($$rstr =~ m/\G((\()(?:<[!=]|<\w+?>|>)?)/gc) {
        _debug(" group $1") if !!DEBUG_RE;
        push @nesting, $2;
        next;
      }
    }

    # maybe variables (maybe not)
    if ($c1 eq '$' and substr($$rstr, $p + 1, 1) eq '{') {
      my @tmp_stack = @{$c->{stack}};
      next if eval { $self->_scan($c, $rstr, F_EXPECTS_BRACKET); 1 };
      pos($$rstr) = $p;
      $c->{stack} = \@tmp_stack;
    }

    if ($c1 eq ')') {
      if (@nesting and $nesting[-1] eq '(') {
        _debug(" end of group $c1") if !!DEBUG_RE;
        pop @nesting;
        pos($$rstr) = $p + 1;
        next;
      } else {
        # die "unnested @nesting" unless $saw_sharp;
      }
    }

    # for //, see if an outer closing delimiter is found first (ie. see if it was actually a /)
    if (!$op) {
      if ($outer_opening_delimiter and $c1 eq $outer_opening_delimiter) {
        push @nesting, $c1;
        pos($$rstr) = $p + 1;
        next;
      }

      if ($outer_closing_delimiter and $c1 eq $outer_closing_delimiter) {
        if (@nesting and $nesting[-1] eq $outer_opening_delimiter) {
          pop @nesting;
          pos($$rstr) = $p + 1;
          next;
        }

        return _match_error($rstr, "Outer closing delimiter: $outer_closing_delimiter is found");
      }
    }

    if ($$rstr =~ m/\G(\w+|.)/gcs) {
      _debug(" rest $1") if !!DEBUG_RE;
      next;
    }
    last;
  }
  if ($#nesting>=0) {
    return _match_error($rstr, "Unmatched opening bracket(s): ". join("..",@nesting)."..");
  }

  my $endpos = pos($$rstr);

  return substr($$rstr, $startpos, $endpos - $startpos);
}


sub _scan_re2 {
  my ($self, $c, $rstr, $ldel, $op) = @_;
  my $startpos = pos($$rstr);

  if ($ldel =~ /[[(<{]/) {
    $$rstr =~ /\G(?:$re_comment)/gcs;

    unless ($$rstr =~ /\G\s*(\S)/gc) {
      return _match_error($rstr, "Missing second block for quotelike $op");
    }
    $ldel = $1;
  }

  if ($ldel =~ /[[(<{]/) {
    my ($rdel, $re_skip) = _gen_rdel_and_re_skip($ldel);
    my @nest = $ldel;
    my ($p, $c1);
    while(defined($p = pos($$rstr))) {
      $c1 = substr($$rstr, $p, 1);
      if ($c1 eq '\\') {
        pos($$rstr) = $p + 2;
        next;
      }
      if ($c1 eq $ldel) {
        pos($$rstr) = $p + 1;
        push @nest, $ldel;
        next;
      }
      if ($c1 eq $rdel) {
        pos($$rstr) = $p + 1;
        pop @nest;
        last unless @nest;
        next;
      }
      $$rstr =~ m{\G$re_skip}gc and next;
      last;
    }
    return _match_error($rstr, "nesting mismatch: @nest") if @nest;
  } else {
    my $re = _gen_re_str_in_delims_with_end_delim($ldel);
    $$rstr =~ /\G$re/gcs or return;
  }

  my $endpos = pos($$rstr);

  return substr($$rstr, $startpos, $endpos - $startpos);
}

sub _use {
  my ($c, $rstr, $tokens) = @_;
_debug("USE TOKENS: ".(Data::Dump::dump($tokens))) if !!DEBUG;
  shift @$tokens; # discard 'use' itself

  # TODO: see if the token is WORD or not?
  my $name_token = shift @$tokens or return;
  my $name = $name_token->[0];
  return if !defined $name or ref $name or $name eq '';

  my $c1 = substr($name, 0, 1);
  if ($c1 eq '5') {
    $c->add(perl => $name);
    return;
  }
  if ($c1 eq 'v') {
    my $c2 = substr($name, 1, 1);
    if ($c2 eq '5') {
      $c->add(perl => $name);
      return;
    }
    if ($c2 eq '6') {
      $c->{perl6} = 1;
      $c->{ended} = 1;
      return;
    }
  }
  if ($name eq 'utf8') {
    $c->add($name => 0);
    $c->{utf8} = 1;
    if (!$c->{decoded}) {
      $c->{decoded} = 1;
      _debug("UTF8 IS ON") if !!DEBUG;
      utf8::decode($$rstr);
      pos($$rstr) = 0;
      $c->{ended} = $c->{redo} = 1;
    }
  }

  if (is_module_name($name)) {
    my $maybe_version_token = $tokens->[0];
    my $maybe_version_token_desc = $maybe_version_token->[1];
    if ($maybe_version_token_desc and ($maybe_version_token_desc eq 'NUMBER' or $maybe_version_token_desc eq 'VERSION_STRING')) {
      $c->add($name => $maybe_version_token->[0]);
      shift @$tokens;
    } else {
      $c->add($name => 0);
    }
  }

  if ($c->has_callback_for(use => $name)) {
    eval { $c->run_callback_for(use => $name, $tokens) };
    warn "Callback Error: $@" if $@;
  }

  if (exists $unsupported_packages{$name}) {
    $c->{ended} = 1;
  }
}

sub _require {
  my ($c, $rstr, $tokens) = @_;
_debug("REQUIRE TOKENS: ".(Data::Dump::dump($tokens))) if !!DEBUG;
  shift @$tokens; # discard 'require' itself

  # TODO: see if the token is WORD or not?
  my $name_token = shift @$tokens or return;
  my $name = $name_token->[0];
  if (ref $name) {
    $name = $name->[0];
    return if $name =~ /\.pl$/i;

    $name =~ s|/|::|g;
    $name =~ s|\.pm$||i;
  }
  return if !defined $name or $name eq '';

  my $c1 = substr($name, 0, 1);
  if ($c1 eq '5') {
    $c->add_conditional(perl => $name);
    return;
  }
  if ($c1 eq 'v') {
    my $c2 = substr($name, 1, 1);
    if ($c2 eq '5') {
      $c->add_conditional(perl => $name);
      return;
    }
    if ($c2 eq '6') {
      $c->{perl6} = 1;
      $c->{ended} = 1;
      return;
    }
  }
  if (is_module_name($name)) {
    $c->add_conditional($name => 0);
    return;
  }
}

sub _no {
  my ($c, $rstr, $tokens) = @_;
_debug("NO TOKENS: ".(Data::Dump::dump($tokens))) if !!DEBUG;
  shift @$tokens; # discard 'no' itself

  # TODO: see if the token is WORD or not?
  my $name_token = shift @$tokens or return;
  my $name = $name_token->[0];
  return if !defined $name or ref $name or $name eq '';

  my $c1 = substr($name, 0, 1);
  if ($c1 eq '5') {
    $c->add(perl => $name);
    return;
  }
  if ($c1 eq 'v') {
    my $c2 = substr($name, 1, 1);
    if ($c2 eq '5') {
      $c->add(perl => $name);
      return;
    }
    if ($c2 eq '6') {
      $c->{perl6} = 1;
      $c->{ended} = 1;
      return;
    }
  }
  if ($name eq 'utf8') {
    $c->{utf8} = 0;
  }

  if (is_module_name($name)) {
    my $maybe_version_token = $tokens->[0];
    my $maybe_version_token_desc = $maybe_version_token->[1];
    if ($maybe_version_token_desc and ($maybe_version_token_desc eq 'NUMBER' or $maybe_version_token_desc eq 'VERSION_STRING')) {
      $c->add($name => $maybe_version_token->[0]);
      shift @$tokens;
    } else {
      $c->add($name => 0);
    }
  }

  if ($c->has_callback_for(no => $name)) {
    eval { $c->run_callback_for(no => $name, $tokens) };
    warn "Callback Error: $@" if $@;
    return;
  }
}

sub _keywords {(
    '__FILE__' => 1,
    '__LINE__' => 2,
    '__PACKAGE__' => 3,
    '__DATA__' => 4,
    '__END__' => 5,
    '__SUB__' => 6,
    AUTOLOAD => 7,
    BEGIN => 8,
    UNITCHECK => 9,
    DESTROY => 10,
    END => 11,
    INIT => 12,
    CHECK => 13,
    abs => 14,
    accept => 15,
    alarm => 16,
    and => 17,
    atan2 => 18,
    bind => 19,
    binmode => 20,
    bless => 21,
    break => 22,
    caller => 23,
    chdir => 24,
    chmod => 25,
    chomp => 26,
    chop => 27,
    chown => 28,
    chr => 29,
    chroot => 30,
    close => 31,
    closedir => 32,
    cmp => 33,
    connect => 34,
    continue => 35,
    cos => 36,
    crypt => 37,
    dbmclose => 38,
    dbmopen => 39,
    default => 40,
    defined => 41,
    delete => 42,
    die => 43,
    do => 44,
    dump => 45,
    each => 46,
    else => 47,
    elsif => 48,
    endgrent => 49,
    endhostent => 50,
    endnetent => 51,
    endprotoent => 52,
    endpwent => 53,
    endservent => 54,
    eof => 55,
    eq => 56,
    eval => 57,
    evalbytes => 58,
    exec => 59,
    exists => 60,
    exit => 61,
    exp => 62,
    fc => 63,
    fcntl => 64,
    fileno => 65,
    flock => 66,
    for => 67,
    foreach => 68,
    fork => 69,
    format => 70,
    formline => 71,
    ge => 72,
    getc => 73,
    getgrent => 74,
    getgrgid => 75,
    getgrnam => 76,
    gethostbyaddr => 77,
    gethostbyname => 78,
    gethostent => 79,
    getlogin => 80,
    getnetbyaddr => 81,
    getnetbyname => 82,
    getnetent => 83,
    getpeername => 84,
    getpgrp => 85,
    getppid => 86,
    getpriority => 87,
    getprotobyname => 88,
    getprotobynumber => 89,
    getprotoent => 90,
    getpwent => 91,
    getpwnam => 92,
    getpwuid => 93,
    getservbyname => 94,
    getservbyport => 95,
    getservent => 96,
    getsockname => 97,
    getsockopt => 98,
    given => 99,
    glob => 100,
    gmtime => 101,
    goto => 102,
    grep => 103,
    gt => 104,
    hex => 105,
    if => 106,
    index => 107,
    int => 108,
    ioctl => 109,
    join => 110,
    keys => 111,
    kill => 112,
    last => 113,
    lc => 114,
    lcfirst => 115,
    le => 116,
    length => 117,
    link => 118,
    listen => 119,
    local => 120,
    localtime => 121,
    lock => 122,
    log => 123,
    lstat => 124,
    lt => 125,
    m => 126,
    map => 127,
    mkdir => 128,
    msgctl => 129,
    msgget => 130,
    msgrcv => 131,
    msgsnd => 132,
    my => 133,
    ne => 134,
    next => 135,
    no => 136,
    not => 137,
    oct => 138,
    open => 139,
    opendir => 140,
    or => 141,
    ord => 142,
    our => 143,
    pack => 144,
    package => 145,
    pipe => 146,
    pop => 147,
    pos => 148,
    print => 149,
    printf => 150,
    prototype => 151,
    push => 152,
    q => 153,
    qq => 154,
    qr => 155,
    quotemeta => 156,
    qw => 157,
    qx => 158,
    rand => 159,
    read => 160,
    readdir => 161,
    readline => 162,
    readlink => 163,
    readpipe => 164,
    recv => 165,
    redo => 166,
    ref => 167,
    rename => 168,
    require => 169,
    reset => 170,
    return => 171,
    reverse => 172,
    rewinddir => 173,
    rindex => 174,
    rmdir => 175,
    s => 176,
    say => 177,
    scalar => 178,
    seek => 179,
    seekdir => 180,
    select => 181,
    semctl => 182,
    semget => 183,
    semop => 184,
    send => 185,
    setgrent => 186,
    sethostent => 187,
    setnetent => 188,
    setpgrp => 189,
    setpriority => 190,
    setprotoent => 191,
    setpwent => 192,
    setservent => 193,
    setsockopt => 194,
    shift => 195,
    shmctl => 196,
    shmget => 197,
    shmread => 198,
    shmwrite => 199,
    shutdown => 200,
    sin => 201,
    sleep => 202,
    socket => 203,
    socketpair => 204,
    sort => 205,
    splice => 206,
    split => 207,
    sprintf => 208,
    sqrt => 209,
    srand => 210,
    stat => 211,
    state => 212,
    study => 213,
    sub => 214,
    substr => 215,
    symlink => 216,
    syscall => 217,
    sysopen => 218,
    sysread => 219,
    sysseek => 220,
    system => 221,
    syswrite => 222,
    tell => 223,
    telldir => 224,
    tie => 225,
    tied => 226,
    time => 227,
    times => 228,
    tr => 229,
    truncate => 230,
    uc => 231,
    ucfirst => 232,
    umask => 233,
    undef => 234,
    unless => 235,
    unlink => 236,
    unpack => 237,
    unshift => 238,
    untie => 239,
    until => 240,
    use => 241,
    utime => 242,
    values => 243,
    vec => 244,
    wait => 245,
    waitpid => 246,
    wantarray => 247,
    warn => 248,
    when => 249,
    while => 250,
    write => 251,
    x => 252,
    xor => 253,
    y => 254 || 255,
)}

1;

__END__

=encoding utf-8

=head1 NAME

Perl::PrereqScanner::NotQuiteLite - a tool to scan your Perl code for its prerequisites

=head1 SYNOPSIS

  use Perl::PrereqScanner::NotQuiteLite;
  my $scanner = Perl::PrereqScanner::NotQuiteLite->new(
    parsers => [qw/:installed -UniversalVersion/],
    suggests => 1,
  );
  my $context = $scanner->scan_file('path/to/file');
  my $requirements = $context->requires;
  my $suggestions  = $context->suggests; # requirements in evals

=head1 BACKWARD INCOMPATIBLILITY

As of 0.49_01, the internal of this module was completely rewritten.
I'm supposing there's no one who has written their own parsers for
the previous version, but if this assumption was wrong, let me know.

=head1 DESCRIPTION

Perl::PrereqScanner::NotQuiteLite is yet another prerequisites
scanner. It passes almost all the scanning tests for
L<Perl::PrereqScanner> and L<Module::ExtractUse> (ie. except for
a few dubious ones), and runs slightly faster than PPI-based
Perl::PrereqScanner. However, it doesn't run as fast as
L<Perl::PrereqScanner::Lite> (which uses an XS lexer).

Perl::PrereqScanner::NotQuiteLite also recognizes C<eval>.
Prerequisites in C<eval> are not considered as requirements, but you
can collect them as suggestions.

=head1 METHODS

=head2 new

creates a scanner object. Options are:

=over 4

=item parsers

By default, Perl::PrereqScanner::NotQuiteLite only recognizes
modules loaded directly by C<use>, C<require>, C<no> statements,
plus modules loaded by a few common modules such as C<base>,
C<parent>, C<if> (that are in the Perl core), and by two keywords
exported by L<Moose> family (C<extends> and C<with>).

If you need more, you can pass extra parser names to the scanner, or
C<:installed>, which loads and registers all the installed parsers
under C<Perl::PrereqScanner::NotQuiteLite::Parser> namespace.

You can also pass a project-specific parser (that lies outside the 
C<Perl::PrereqScanner::NotQuiteLite::Parser> namespace) by
prepending C<+> to the name.

  use Perl::PrereqScanner::NotQuiteLite;
  my $scanner = Perl::PrereqScanner::NotQuiteLite->new(
    parsers => [qw/+PrereqParser::For::MyProject/],
  );

If you don't want to load a specific parser for some reason,
prepend C<-> to the parser name.

=item suggests

Perl::PrereqScanner::NotQuiteLite ignores C<use>-like statements in
C<eval> by default. If you set this option to true,
Perl::PrereqScanner::NotQuiteLite also parses statements in C<eval>,
and records requirements as suggestions.

=back

=head2 scan_file

takes a path to a file and returns a ::Context object.

=head2 scan_string

takes a string, scans and returns a ::Context object.

=head1 SEE ALSO

L<Perl::PrereqScanner>, L<Perl::PrereqScanner::Lite>, L<Module::ExtractUse>

=head1 AUTHOR

Kenichi Ishigaki, E<lt>ishigaki@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Kenichi Ishigaki.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
