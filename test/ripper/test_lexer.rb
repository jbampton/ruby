# frozen_string_literal: true
begin
  require 'ripper'
  require 'test/unit'
  module TestRipper; end
rescue LoadError
end

class TestRipper::Lexer < Test::Unit::TestCase
  def test_nested_dedent_heredoc
    bug = '[ruby-core:80977] [Bug #13536]'
    str = <<~'E'
    <<~"D"
    #{
    <<~"B"
    this must be a valid ruby
    B
    }
    D
    E
    assert_equal(str, Ripper.tokenize(str).join(""), bug)

    str = <<~'E'
    <<~"D"
    #{
    <<~"B"
      this must be a valid ruby
    B
    }
    D
    E
    assert_equal(str, Ripper.tokenize(str).join(""), bug)
  end

  def test_embedded_expr_in_heredoc
    src = <<~'E'
    <<~B
      #{1}
    B
    E
    expect = %I[
      on_heredoc_beg
      on_nl
      on_ignored_sp
      on_embexpr_beg
      on_int
      on_embexpr_end
      on_tstring_content
      on_heredoc_end
    ]
    assert_equal expect, Ripper.lex(src).map {|e| e[1]}
  end

  def test_space_after_expr_in_heredoc
    src = <<~'E'
    <<~B
     #{1} a
    B
    E
    expect = %I[
      on_heredoc_beg
      on_nl
      on_ignored_sp
      on_embexpr_beg
      on_int
      on_embexpr_end
      on_tstring_content
      on_heredoc_end
    ]
    assert_equal expect, Ripper.lex(src).map {|e| e[1]}
  end

  def test_expr_at_beginning_in_heredoc
    src = <<~'E'
    <<~B
      a
    #{1}
    B
    E
    expect = %I[
      on_heredoc_beg
      on_nl
      on_tstring_content
      on_embexpr_beg
      on_int
      on_embexpr_end
      on_tstring_content
      on_heredoc_end
    ]
    assert_equal expect, Ripper.lex(src).map {|e| e[1]}
  end

  def test_stack_at_on_heredoc_beg
    src = "a <<b"
    expect = %I[
      on_ident
      on_sp
      on_heredoc_beg
    ]
    assert_equal expect, Ripper.lex(src).map {|e| e[1]}
  end

  def test_end_of_script_char
    all_assertions do |all|
      ["a", %w"[a ]", %w"{, }", "if"].each do |src, append|
        expected = Ripper.lex(src).map {|e| e[1]}
        ["\0b", "\4b", "\32b"].each do |eof|
          c = "#{src}#{eof}#{append}"
          all.for(c) do
            assert_equal expected, Ripper.lex(c).map {|e| e[1]}
          end
        end
      end
    end
  end

  def test_slice
    assert_equal "string\#{nil}\n",
      Ripper.slice(%(<<HERE\nstring\#{nil}\nHERE), "heredoc_beg .*? nl $(.*?) heredoc_end", 1)
  end

  def state(name)
    Ripper::Lexer::State.new(Ripper.const_get(name))
  end

  def test_state_after_ivar
    assert_equal [[1,0],:on_ivar,"@a",state(:EXPR_END)], Ripper.lex("@a").last
    assert_equal [[1,1],:on_ivar,"@a",state(:EXPR_ENDFN)], Ripper.lex(":@a").last
    assert_equal [[1,1],:on_int,"1",state(:EXPR_END)], Ripper.lex("@1").last
    assert_equal [[1,2],:on_int,"1",state(:EXPR_END)], Ripper.lex(":@1").last
  end

  def test_state_after_cvar
    assert_equal [[1,0],:on_cvar,"@@a",state(:EXPR_END)], Ripper.lex("@@a").last
    assert_equal [[1,1],:on_cvar,"@@a",state(:EXPR_ENDFN)], Ripper.lex(":@@a").last
    assert_equal [[1,2],:on_int,"1",state(:EXPR_END)], Ripper.lex("@@1").last
    assert_equal [[1,3],:on_int,"1",state(:EXPR_END)], Ripper.lex(":@@1").last
  end

  def test_token_aftr_error_heredoc
    code = "<<A.upcase\n"
    result = Ripper::Lexer.new(code).scan
    message = proc {result.pretty_inspect}
    expected = [
      [[1, 0], :on_heredoc_beg, "<<A", state(:EXPR_BEG)],
      [[1, 2], :compile_error, "A", state(:EXPR_BEG), "can't find string \"A\" anywhere before EOF"],
      [[1, 3], :on_period, ".", state(:EXPR_DOT)],
      [[1, 4], :on_ident, "upcase", state(:EXPR_ARG)],
      [[1, 10], :on_nl, "\n", state(:EXPR_BEG)],
    ]
    pos = 0
    expected.each_with_index do |ex, i|
      s = result[i]
      assert_equal ex, s.to_a, message
      if pos > s.pos[1]
        assert_equal pos, s.pos[1] + s.tok.bytesize, message
      else
        assert_equal pos, s.pos[1], message
        pos += s.tok.bytesize
      end
    end
    assert_equal pos, code.bytesize
    assert_equal expected.size, result.size
  end

  def test_trailing_on_embexpr_end
    # This is useful for scanning a template engine literal `{ foo, bar: baz }`
    # whose body inside brackes works like trailing method arguments, like Haml.
    token = Ripper.lex("a( foo, bar: baz }").last
    assert_equal [[1, 17], :on_embexpr_end, "}", state(:EXPR_ARG)], token
  end

  BAD_CODE = [
    [:parse_error,      'def req(true) end',         %r[unexpected 'true'],         'true'],
    [:parse_error,      'def req(a, a) end',         %r[duplicated argument name],  'a'],
    [:assign_error,     'begin; nil = 1; end',       %r[assign to nil],             'nil'],
    [:alias_error,      'begin; alias $x $1; end',   %r[number variables],          '$1'],
    [:class_name_error, 'class bad; end',            %r[class/module name],         'bad'],
    [:param_error,      'def req(@a) end',           %r[formal argument.*instance], '@a'],
    [:param_error,      'def req(a?:) end',          %r[formal argument must.*local], 'a?'],
  ]

  def test_raise_errors_keyword
    all_assertions do |all|
      BAD_CODE.each do |(err, code, message)|
        all.for([err, code]) do
          assert_raise_with_message(SyntaxError, message) { Ripper.tokenize(code, raise_errors: true) }
        end
      end
    end
  end

  def test_tokenize_with_syntax_error
    all_assertions do |all|
      BAD_CODE.each do |(err, code)|
        all.for([err, code]) do
          assert_equal "end", Ripper.tokenize(code).last
        end
      end
    end
  end

  def test_lex_with_syntax_error
    all_assertions do |all|
      BAD_CODE.each do |(err, code)|
        all.for([err, code]) do
          assert_equal [[1, code.size-3], :on_kw, "end", state(:EXPR_END)], Ripper.lex(code).last
        end
      end
    end
  end

  def test_lexer_scan_with_syntax_error
    all_assertions do |all|
      BAD_CODE.each do |(err, code, message, token)|
        all.for([err, code]) do
          lexer = Ripper::Lexer.new(code)
          elems = lexer.scan
          assert_predicate lexer, :error?
          error = lexer.errors.first
          assert_match message, error.message
          i = elems.find_index{|e| e == error}
          assert_operator 0...elems.size, :include?, i
          elem = elems[i + 1]
          assert_not_equal error.event, elem.event
          assert_equal error.pos, elem.pos
          assert_equal error.tok, elem.tok
          assert_equal error.state, elem.state
        end
      end
    end
  end

  def test_lex_with_syntax_error_and_heredoc
    bug = '[Bug #17644]'
    s = <<~EOF
        foo
      end
      <<~EOS
        bar
      EOS
    EOF
    assert_equal([[5, 0], :on_heredoc_end, "EOS\n", state(:EXPR_BEG)], Ripper.lex(s).last, bug)
  end

  def test_tokenize_with_here_document
    bug = '[Bug #18963]'
    code = %[
<<A + "hello
A
world"
]
    assert_equal(code, Ripper.tokenize(code).join(""), bug)
  end

  InvalidHeredocInsideBlockParam = <<~CODE
    a do |b
      <<-C
      C
      |
    end
  CODE

  def test_heredoc_inside_block_param
    bug = '[Bug #19399]'
    code = InvalidHeredocInsideBlockParam
    assert_equal(code, Ripper.tokenize(code).join(""), bug)
  end

  def test_heredoc_no_memory_leak
    assert_no_memory_leak([], "#{<<-"begin;"}", "#{<<-'end;'}", rss: true)
    require "ripper"
    source = "" #{InvalidHeredocInsideBlockParam.dump}
    begin;
      400_000.times do
        Ripper.new(source).parse
      end
    end;
  end

  def test_heredoc_unterminated_interpolation
    code = <<~'HEREDOC'
    <<A+1
    #{
    HEREDOC

    assert_include(Ripper.tokenize(code).join(""), "+1")
  end

  def test_nested_heredoc
    code = <<~'HEREDOC'
    <<~H1
      1
      #{<<~H2}
        2
      H2
      3
    H1
    HEREDOC

    expected = [
      [[1, 0], :on_heredoc_beg, "<<~H1", state(:EXPR_BEG)],
      [[1, 5], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_ignored_sp, "  ", state(:EXPR_BEG)],
      [[2, 2], :on_tstring_content, "1\n", state(:EXPR_BEG)],
      [[3, 0], :on_ignored_sp, "  ", state(:EXPR_BEG)],
      [[3, 2], :on_embexpr_beg, "\#{", state(:EXPR_BEG)],
      [[3, 4], :on_heredoc_beg, "<<~H2", state(:EXPR_BEG)],
      [[3, 9], :on_embexpr_end, "}", state(:EXPR_END)],
      [[3, 10], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[4, 0], :on_ignored_sp, "    ", state(:EXPR_BEG)],
      [[4, 4], :on_tstring_content, "2\n", state(:EXPR_BEG)],
      [[5, 0], :on_heredoc_end, "  H2\n", state(:EXPR_BEG)],
      [[6, 0], :on_ignored_sp, "  ", state(:EXPR_BEG)],
      [[6, 2], :on_tstring_content, "3\n", state(:EXPR_BEG)],
      [[7, 0], :on_heredoc_end, "H1\n", state(:EXPR_BEG)],
    ]

    assert_lexer(expected, code)

    code = <<~'HEREDOC'
    <<-H1
      1
      #{<<~H2}
        2
      H2
      3
    H1
    HEREDOC

    expected = [
      [[1, 0], :on_heredoc_beg, "<<-H1", state(:EXPR_BEG)],
      [[1, 5], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "  1\n  ", state(:EXPR_BEG)],
      [[3, 2], :on_embexpr_beg, "\#{", state(:EXPR_BEG)],
      [[3, 4], :on_heredoc_beg, "<<~H2", state(:EXPR_BEG)],
      [[3, 9], :on_embexpr_end, "}", state(:EXPR_END)],
      [[3, 10], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[4, 0], :on_ignored_sp, "    ", state(:EXPR_BEG)],
      [[4, 4], :on_tstring_content, "2\n", state(:EXPR_BEG)],
      [[5, 0], :on_heredoc_end, "  H2\n", state(:EXPR_BEG)],
      [[6, 0], :on_tstring_content, "  3\n", state(:EXPR_BEG)],
      [[7, 0], :on_heredoc_end, "H1\n", state(:EXPR_BEG)],
    ]

    assert_lexer(expected, code)

    code = <<~'HEREDOC'
      <<H1
      #{<<H2}a
      H2
      b
    HEREDOC

    expected = [
      [[1, 0], :on_heredoc_beg, "<<H1", state(:EXPR_BEG)],
      [[1, 4], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_embexpr_beg, "\#{", state(:EXPR_BEG)],
      [[2, 2], :on_heredoc_beg, "<<H2", state(:EXPR_BEG)],
      [[2, 6], :on_embexpr_end, "}", state(:EXPR_END)],
      [[2, 7], :on_tstring_content, "a\n", state(:EXPR_BEG)],
      [[3, 0], :on_heredoc_end, "H2\n", state(:EXPR_BEG)],
      [[4, 0], :on_tstring_content, "b\n", state(:EXPR_BEG)]
    ]

    assert_lexer(expected, code)

    code = <<~'HEREDOC'
      <<H1
      #{<<H2}a
      H2
      b
      c
    HEREDOC

    expected = [
      [[1, 0], :on_heredoc_beg, "<<H1", state(:EXPR_BEG)],
      [[1, 4], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_embexpr_beg, "\#{", state(:EXPR_BEG)],
      [[2, 2], :on_heredoc_beg, "<<H2", state(:EXPR_BEG)],
      [[2, 6], :on_embexpr_end, "}", state(:EXPR_END)],
      [[2, 7], :on_tstring_content, "a\n", state(:EXPR_BEG)],
      [[3, 0], :on_heredoc_end, "H2\n", state(:EXPR_BEG)],
      [[4, 0], :on_tstring_content, "b\nc\n", state(:EXPR_BEG)]
    ]

    assert_lexer(expected, code)
  end

  def test_invalid_escape_ctrl_mbchar
    code = %["\\C-\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\C-\u{3042}", state(:EXPR_BEG)],
      [[1, 7], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)

    code = %["\\C-\\\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\C-\\\u{3042}", state(:EXPR_BEG)],
      [[1, 8], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)
  end

  def test_invalid_escape_meta_mbchar
    code = %["\\M-\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\M-\u{3042}", state(:EXPR_BEG)],
      [[1, 7], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)

    code = %["\\M-\\\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\M-\\\u{3042}", state(:EXPR_BEG)],
      [[1, 8], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)
  end

  def test_invalid_escape_meta_ctrl_mbchar
    code = %["\\M-\\C-\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\M-\\C-\u{3042}", state(:EXPR_BEG)],
      [[1, 10], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)

    code = %["\\M-\\C-\\\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\M-\\C-\\\u{3042}", state(:EXPR_BEG)],
      [[1, 11], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)
  end

  def test_invalid_escape_ctrl_meta_mbchar
    code = %["\\C-\\M-\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\C-\\M-\u{3042}", state(:EXPR_BEG)],
      [[1, 10], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)

    code = %["\\C-\\M-\\\u{3042}"]
    expected = [
      [[1, 0], :on_tstring_beg, '"', state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\\C-\\M-\\\u{3042}", state(:EXPR_BEG)],
      [[1, 11], :on_tstring_end, '"', state(:EXPR_END)],
    ]

    assert_lexer(expected, code)
  end

  def test_invalid_escape_string
    code = "\"hello\\x world"
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "hello", state(:EXPR_BEG)],
      [[1, 5], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[1, 7], :on_tstring_content, " world", state(:EXPR_BEG)],
    ]

    code = "\"\nhello\\x world"
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n" "hello", state(:EXPR_BEG)],
      [[2, 5], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[2, 7], :on_tstring_content, " world", state(:EXPR_BEG)],
    ]
    assert_lexer(expected, code)

    code = "\"\n\\Cxx\""
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\Cx", state(:EXPR_BEG)],
      [[2, 3], :on_tstring_content, "x", state(:EXPR_BEG)],
      [[2, 4], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "\"\n\\Mxx\""
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\Mx", state(:EXPR_BEG)],
      [[2, 3], :on_tstring_content, "x", state(:EXPR_BEG)],
      [[2, 4], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "\"\n\\c\\cx\""
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\c\\c", state(:EXPR_BEG)],
      [[2, 4], :on_tstring_content, "x", state(:EXPR_BEG)],
      [[2, 5], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "\"\n\\ux\""
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\u", state(:EXPR_BEG)],
      [[2, 2], :on_tstring_content, "x", state(:EXPR_BEG)],
      [[2, 3], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "\"\n\\xx\""
    expected = [
      [[1, 0], :on_tstring_beg, "\"", state(:EXPR_BEG)],
      [[1, 1], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[2, 2], :on_tstring_content, "x", state(:EXPR_BEG)],
      [[2, 3], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "<<A\n\n\\xyz"
    expected = [
      [[1, 0], :on_heredoc_beg, "<<A", state(:EXPR_BEG)],
      [[1, 3], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[3, 0], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[3, 2], :on_tstring_content, "yz", state(:EXPR_BEG)],
    ]
    assert_lexer(expected, code)

    code = "%(\n\\xyz)"
    expected = [
      [[1, 0], :on_tstring_beg, "%(", state(:EXPR_BEG)],
      [[1, 2], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[2, 2], :on_tstring_content, "yz", state(:EXPR_BEG)],
      [[2, 4], :on_tstring_end, ")", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = "%Q(\n\\xyz)"
    expected = [
      [[1, 0], :on_tstring_beg, "%Q(", state(:EXPR_BEG)],
      [[1, 3], :on_tstring_content, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_tstring_content, "\\x", state(:EXPR_BEG)],
      [[2, 2], :on_tstring_content, "yz", state(:EXPR_BEG)],
      [[2, 4], :on_tstring_end, ")", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)

    code = ":\"\n\\xyz\""
    expected = [
      [[1, 0], :on_symbeg, ":\"", state(:EXPR_FNAME)],
      [[1, 2], :on_tstring_content, "\n", state(:EXPR_FNAME)],
      [[2, 0], :on_tstring_content, "\\x", state(:EXPR_FNAME)],
      [[2, 2], :on_tstring_content, "yz", state(:EXPR_FNAME)],
      [[2, 4], :on_tstring_end, "\"", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)
  end

  def test_spaces_at_eof
    code = "1\n\t \t"
    expected = [
      [[1, 0], :on_int, "1", state(:EXPR_END)],
      [[1, 1], :on_nl, "\n", state(:EXPR_BEG)],
      [[2, 0], :on_sp, "\t \t", state(:EXPR_END)],
    ]
    assert_lexer(expected, code)
  end

  def assert_lexer(expected, code)
    assert_equal(code, Ripper.tokenize(code).join(""))
    assert_equal(expected, result = Ripper.lex(code),
                 proc {expected.zip(result) {|e, r| break diff(e, r) unless e == r}})
  end
end
