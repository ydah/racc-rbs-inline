# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/integration_helpers"
require "racc_rbs_inline/cli"
require "rbs"
require "stringio"

class SemanticIntegrationTest < Minitest::Test
  include IntegrationHelpers

  def typed_grammar
    File.read(File.join(FIXTURES, "typed_calc.y"))
  end

  def generate_typed(dir, grammar)
    File.write(File.join(dir, "typed_calc.y"), grammar)
    out, err, status = gem_command("racc", "racc", "-o", "parser.rb", "typed_calc.y", chdir: dir)
    assert status.success?, "#{out}#{err}"
    File.read(File.join(dir, "parser.rb"))
  end

  def annotate_typed(source, grammar)
    RaccRbsInline.annotate(source, grammar: grammar, grammar_filename: "typed_calc.y")
  end

  def reduction_types(source)
    source.lines.each_cons(2).filter_map do |annotation, definition|
      next unless definition.match?(/^\s*def _reduce_(?:\d+|none)\(/)
      signature = annotation.strip.delete_prefix("#: ")
      RBS::Parser.parse_method_type(signature).type
    end
  end

  def check_both_routes(dir, source)
    write_type_project(dir, source)
    yield :native, steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }

    out, err, status = gem_command("rbs-inline", "rbs-inline", "parser.rb", chdir: dir)
    assert status.success?, err
    File.write(File.join(dir, "sig/generated.rbs"), out)
    out, err, status = gem_command("rbs", "rbs", "-I", "sig", "validate", chdir: dir)
    assert status.success?, "#{out}#{err}"
    steepfile = File.join(dir, "Steepfile")
    File.write(steepfile, File.read(steepfile).sub("inline: true", "inline: false"))
    yield :extracted, steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
  end

  def test_typed_calculator_checks_in_both_routes_and_keeps_runtime_behavior
    Dir.mktmpdir do |dir|
      grammar = typed_grammar
      original = generate_typed(dir, grammar)
      source = annotate_typed(original, grammar)
      signatures = reduction_types(source)
      parenthesized = signatures.find { |type| type.required_positionals.first.type.to_s.delete(" ") == "[String,Integer,String]" }
      refute_nil parenthesized
      assert_equal "Integer", parenthesized.return_type.to_s
      assert_equal %w[Integer String], parenthesized.required_positionals.last.type.to_s.split(" | ").sort
      check_both_routes(dir, source) { |route, diagnostics| assert_empty diagnostics, "#{route}: #{diagnostics.inspect}" }

      runner = "load File.expand_path(ARGV.fetch(0)); p TypedCalc.new([['(', '('], [:NUMBER, 2], ['+', '+'], [:NUMBER, 3], [')', ')'], [false, nil]]).do_parse"
      File.write(File.join(dir, "original.rb"), original)
      before, err, status = command(RbConfig.ruby, "-e", runner, "original.rb", chdir: dir)
      assert status.success?, err
      after, err, status = command(RbConfig.ruby, "-e", runner, "parser.rb", chdir: dir)
      assert status.success?, err
      assert_equal "5\n", before
      assert_equal before, after
    end
  end

  def test_parenthesized_action_returning_opening_token_is_rejected
    Dir.mktmpdir do |dir|
      grammar = typed_grammar.sub("result = val[1]", "result = val[0]")
      source = annotate_typed(generate_typed(dir, grammar), grammar)
      check_both_routes(dir, source) do |route, diagnostics|
        assert diagnostics.any? { |diagnostic| diagnostic.fetch("code") == "Ruby::MethodBodyTypeMismatch" },
               "#{route}: #{diagnostics.inspect}"
      end
    end
  end

  def test_no_result_var_uses_two_typed_arguments
    Dir.mktmpdir do |dir|
      grammar = typed_grammar.sub("rule\n", "options no_result_var\nrule\n").gsub("result = ", "")
      source = annotate_typed(generate_typed(dir, grammar), grammar)
      typed = reduction_types(source).select { |type| type.return_type.to_s == "Integer" }
      assert_equal 4, typed.length
      assert typed.all? { |type| type.required_positionals.length == 2 }
      check_both_routes(dir, source) { |route, diagnostics| assert_empty diagnostics, "#{route}: #{diagnostics.inspect}" }
    end
  end

  def test_empty_rule_accepts_nil_initial_result
    Dir.mktmpdir do |dir|
      grammar = "class EmptyTyped\n# @racc-type target : Integer\nrule\n  target: { result = 0 }\nend\n"
      source = annotate_typed(generate_typed(dir, grammar), grammar)
      signature = reduction_types(source).find { |type| type.return_type.to_s == "Integer" }
      refute_nil signature
      assert_equal "[]", signature.required_positionals.first.type.to_s.delete(" ")
      assert_equal %w[Integer nil], signature.required_positionals.last.type.to_s.split(" | ").sort
      write_type_project(dir, source)
      assert_empty steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
    end
  end

  def test_generated_optional_repetition_and_group_symbols_have_their_documented_types
    skip "Racc 1.8 introduced optional, repetition, and group syntax" if Gem::Version.new(Racc::VERSION) < Gem::Version.new("1.8")
    { "NUMBER?" => "Integer?", "NUMBER*" => "Array[Integer]", "NUMBER+" => "Array[Integer]",
      "(NUMBER NUMBER)" => "Array[untyped]" }.each do |symbol, type|
      Dir.mktmpdir do |dir|
        grammar = <<~GRAMMAR
          class ExpandedTyped
          # @racc-type NUMBER : Integer
          # @racc-type target : #{type}
          rule
            target: #{symbol} { result = val[0] }
          end
        GRAMMAR
        source = annotate_typed(generate_typed(dir, grammar), grammar)
        signatures = reduction_types(source)
        signature = signatures.find { |method| method.return_type.to_s.delete(" ") == type }
        refute_nil signature, symbol
        assert_equal "[#{type}]", signature.required_positionals.first.type.to_s.delete(" "), symbol
        generic = signatures.reject { |method| method.equal?(signature) }
        refute_empty generic, symbol
        assert generic.all? { |method| method.required_positionals.first.type.to_s == "Array[untyped]" }, symbol
        write_type_project(dir, source)
        assert_empty steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }, symbol
      end
    end
  end

  def test_mismatched_reduction_table_is_rejected_without_writing
    Dir.mktmpdir do |dir|
      grammar = typed_grammar
      original = generate_typed(dir, grammar)
      mismatched = original.sub(/\d+,\s*(\d+),\s*:_reduce_1/) { "99, #{Regexp.last_match(1)}, :_reduce_1" }
      refute_equal original, mismatched
      assert_raises(RaccRbsInline::Error) { annotate_typed(mismatched, grammar) }
      path = File.join(dir, "parser.rb")
      File.binwrite(path, mismatched)
      error = StringIO.new
      status = RaccRbsInline::CLI.run(["annotate", path, "--grammar", File.join(dir, "typed_calc.y")],
                                     out: StringIO.new, err: error)
      assert_equal 1, status, error.string
      assert_equal mismatched, File.binread(path)
    end
  end

  def test_different_grammar_rule_structure_is_rejected
    Dir.mktmpdir do |dir|
      grammar = typed_grammar
      original = generate_typed(dir, grammar)
      changed = grammar.sub("target: exp", "target: exp NUMBER")
      assert_raises(RaccRbsInline::Error) { annotate_typed(original, changed) }
    end
  end

  def test_existing_annotations_upgrade_and_refresh_when_grammar_is_supplied
    Dir.mktmpdir do |dir|
      grammar = typed_grammar
      original = generate_typed(dir, grammar)
      typed = annotate_typed(original, grammar)
      assert_equal typed, annotate_typed(RaccRbsInline.annotate(original), grammar)
      assert_equal typed, annotate_typed(typed, grammar)
      changed = grammar.sub("NUMBER exp target : Integer", "NUMBER exp target : Numeric")
      refreshed = annotate_typed(typed, changed)
      assert reduction_types(refreshed).any? { |type| type.return_type.to_s == "Numeric" }
      refute reduction_types(refreshed).any? { |type| type.return_type.to_s == "Integer" }
    end
  end

  def test_generate_automatically_uses_declarations_and_preserves_untyped_output
    Dir.mktmpdir do |dir|
      grammar = typed_grammar
      generate_typed(dir, grammar)
      path = File.join(dir, "parser.rb")
      error = StringIO.new
      status = RaccRbsInline::CLI.run(["generate", File.join(dir, "typed_calc.y"), "-o", path], out: StringIO.new, err: error)
      assert_equal 0, status, error.string
      assert reduction_types(File.read(path)).any? { |type| type.return_type.to_s == "Integer" }

      untyped = grammar.lines.reject { |line| line.include?("@racc-type") }.join
      original = generate_typed(dir, untyped)
      assert_equal RaccRbsInline.annotate(original), annotate_typed(original, untyped)
    end
  end

  def test_generate_keeps_interpolated_tokens_generic_without_actual_type_declarations
    grammar = <<~'GRAMMAR'
      class InterpolatedToken
      rule
        target: "x#{1}" { result = val[0] }
      end
    GRAMMAR
    fake_declaration = <<~'ACTION'
      {
        description = <<~TEXT
          # @racc-type target : Integer
        TEXT
        result = val[0]
      }
    ACTION
    [grammar, grammar.sub("{ result = val[0] }", fake_declaration.strip)].each do |untyped|
      Dir.mktmpdir do |dir|
        original = generate_typed(dir, untyped)
        path = File.join(dir, "parser.rb")
        error = StringIO.new
        status = RaccRbsInline::CLI.run(["generate", File.join(dir, "typed_calc.y"), "-o", path],
                                       out: StringIO.new, err: error)
        assert_equal 0, status, error.string
        assert_equal RaccRbsInline.annotate(original), File.binread(path)
        assert reduction_types(File.read(path)).all? { |type| type.return_type.to_s == "untyped" }
      end
    end
  end
end
