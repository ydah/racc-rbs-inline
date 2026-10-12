# frozen_string_literal: true

require_relative "test_helper"
require "racc_rbs_inline/grammar_types"

class GrammarTypesTest < Minitest::Test
  def grammar(rule = "target: NUMBER { result = val[0] }", declarations: "# @racc-type NUMBER target : Integer", options: "")
    "class TypedParser\n#{declarations}\n#{options}\nrule\n#{rule}\nend\n"
  end

  def body_for(source, options: [])
    Dir.mktmpdir do |directory|
      input = File.join(directory, "grammar.y")
      output = File.join(directory, "parser.rb")
      File.write(input, source)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, Gem.bin_path("racc", "racc"), input, "-l", *options, "-o", output)
      assert status.success?, stdout + stderr
      parsed = Prism.parse(File.read(output))
      parsed.value.statements.body.find { |node| node.is_a?(Prism::ClassNode) }.body
    end
  end

  def signatures(source)
    RaccRbsInline::GrammarTypes.new(source).signatures(body: body_for(source))
  end

  def test_types_reduction_tuple_result_and_return
    assert_equal "#: ([Integer] val, Array[untyped] _values, Integer result) -> Integer", signatures(grammar).fetch(:_reduce_1)
  end

  def test_empty_rules_and_untyped_symbols
    source = grammar("target: { result = 0 } | NUMBER { result = val[0] }", declarations: "# @racc-type target : Integer")
    types = signatures(source)
    assert_equal "#: ([] val, Array[untyped] _values, nil | Integer result) -> Integer", types.fetch(:_reduce_1)
    assert_equal "#: ([untyped] val, Array[untyped] _values, untyped | Integer result) -> Integer", types.fetch(:_reduce_2)
  end

  def test_no_result_var_omits_result_parameter
    source = grammar("target: NUMBER { val[0] }", options: "options no_result_var")
    assert_equal "#: ([Integer] val, Array[untyped] _values) -> Integer", signatures(source).fetch(:_reduce_1)
  end

  def test_table_validation_accepts_generator_options
    source = grammar
    [["--no-omit-actions"], ["--embedded"], ["--debug"]].each do |options|
      types = RaccRbsInline::GrammarTypes.new(source).signatures(body: body_for(source, options: options))
      assert types.key?(:_reduce_1), options.inspect
    end
  end

  def test_quoted_symbols_and_union_types
    source = grammar("target: ':' NUMBER { result = val[1] }", declarations: "# @racc-type ':' : String\n# @racc-type NUMBER target : Integer | nil")
    type = signatures(source).fetch(:_reduce_1)
    assert_includes type, "[String, Integer | nil] val"
    assert_includes type, "String | Integer | nil result"
  end

  def test_japanese_and_escaped_literal_symbols
    source = grammar('target: "あ" "\\n" { result = 1 }', declarations: '# @racc-type "あ" "\\n" : String' + "\n# @racc-type target : Integer")
    assert_includes signatures(source).fetch(:_reduce_1), "[String, String] val"
  end

  def test_generated_symbols_have_derived_types_but_generic_reductions
    skip "Racc extended grammar syntax requires 1.8" if Gem::Version.new(Racc::VERSION) < Gem::Version.new("1.8")
    { "?" => "Integer?", "*" => "Array[Integer]", "+" => "Array[Integer]" }.each do |operator, expected|
      source = grammar("target: NUMBER#{operator} { result = val[0] }")
      types = signatures(source)
      assert_equal 1, types.size
      assert_includes types.values.first, "[#{expected}] val"
    end
    source = grammar("target: (NUMBER NUMBER) { result = 0 }")
    types = signatures(source)
    assert_equal 1, types.size
    assert_includes types.values.first, "[Array[untyped]] val"
  end

  def test_reduce_none_and_no_declarations_keep_generic_annotations
    assert_empty signatures(grammar("target: NUMBER"))
    assert_empty signatures(grammar(declarations: ""))
  end

  def test_rejects_unknown_conflicting_and_malformed_declarations
    ["# @racc-type UNKNOWN : Integer", "# @racc-type NUMBER : Integer\n# @racc-type NUMBER : String",
     "# @racc-type NUMBER Integer", "# @racc-type : Integer", "# @racc-type NUMBER : Array[",
     "# @racc-type NUMBER : Integer trailing", "# @racc-type NUMBER :", "# @racc-type 123 : Integer",
     "# @racc-type NUMBER : void"].each do |declaration|
      assert_raises(RaccRbsInline::Error, declaration) { RaccRbsInline::GrammarTypes.new(grammar(declarations: declaration)) }
    end
  end

  def test_identical_duplicate_declarations_are_allowed
    source = grammar(declarations: "# @racc-type NUMBER target : Integer\n# @racc-type NUMBER : Integer")
    assert signatures(source).key?(:_reduce_1)
  end

  def test_rejects_rule_count_length_and_lhs_mismatches
    source = grammar
    original = body_for(source).location.slice
    [original.sub("1, 4, :_reduce_1", "2, 4, :_reduce_1"),
     original.sub("1, 4, :_reduce_1", "1, 5, :_reduce_1"),
     original.sub("0, 0, :racc_error", "0, 0, :racc_error, 0, 4, :_reduce_2")].each do |altered|
      refute_equal original, altered
      body = Prism.parse("class TypedParser\n#{altered}\nend").value.statements.body.first.body
      assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source).signatures(body: body) }
    end
  end

  def test_rejects_same_shaped_grammar_with_different_symbols
    source = grammar
    other = grammar("other: TOKEN { result = val[0] }", declarations: "# @racc-type TOKEN other : Integer")
    assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source).signatures(body: body_for(other)) }
  end

  def test_rejects_reordered_rhs_with_identical_reduction_and_symbol_tables
    source = grammar("target: A B { result = val[0] }", options: "token A B", declarations: "# @racc-type A target : Integer\n# @racc-type B : String")
    other = source.sub("target: A B", "target: B A")
    assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source).signatures(body: body_for(other)) }
  end

  def test_rejects_missing_dynamic_and_inconsistent_tables
    source = grammar
    original = body_for(source).location.slice
    [original.sub(/racc_reduce_table = \[.*?\]/m, "racc_reduce_table = build_table()"),
     original.sub("racc_reduce_n = 2", "racc_reduce_n = 3"),
     original.sub("racc_use_result_var = true", "racc_use_result_var = false"),
     original.sub("racc_nt_base = 3", "other_nt_base = 3")].each do |altered|
      refute_equal original, altered
      body = Prism.parse("class TypedParser\n#{altered}\nend").value.statements.body.first.body
      assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source).signatures(body: body) }
    end
  end

  def test_rejects_invalid_grammar
    ["not a grammar", "", "---- header\nputs 1\n"].each do |source|
      assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source) }
    end
  end

  def test_never_executes_interpolation_in_grammar_or_declarations
    $racc_inline_executed = false
    [grammar('target: "#{$racc_inline_executed = true}" { result = 0 }', declarations: ""),
     grammar(declarations: '# @racc-type "#{$racc_inline_executed = true}" : String')].each do |source|
      assert_raises(RaccRbsInline::Error) { RaccRbsInline::GrammarTypes.new(source) }
      refute $racc_inline_executed
    end
  ensure
    $racc_inline_executed = nil
  end

  def test_declaration_detection_does_not_interpret_quoted_tokens
    $racc_inline_executed = false
    source = grammar('target: "#{$racc_inline_executed = true}" { result = 0 }', declarations: "")
    refute RaccRbsInline::GrammarTypes.declared?(source)
    refute $racc_inline_executed
    assert RaccRbsInline::GrammarTypes.declared?(grammar)
  ensure
    $racc_inline_executed = nil
  end

  def test_does_not_execute_actions_or_user_sections
    source = grammar('target: NUMBER { $racc_inline_executed = true; result = val[0] }') + "---- header\nraise 'must not execute'\n"
    assert RaccRbsInline::GrammarTypes.new(source)
  end

  def test_ignores_directive_text_in_actions_block_comments_and_user_sections
    source = <<~'GRAMMAR'
      class TypedParser
      # @racc-type NUMBER target : Integer
      /*
      # @racc-type UNKNOWN : String
      */
      rule
        target: NUMBER {
          text = <<'TEXT'
      # @racc-type NUMBER : String
      TEXT
          result = val[0]
        }
      end
      ---- header
      # @racc-type UNKNOWN : String
    GRAMMAR
    assert_equal "#: ([Integer] val, Array[untyped] _values, Integer result) -> Integer", signatures(source).fetch(:_reduce_1)
    refute RaccRbsInline::GrammarTypes.declared?(source.sub("# @racc-type NUMBER target : Integer", "# no declarations"))
  end
end
