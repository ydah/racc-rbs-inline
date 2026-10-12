# frozen_string_literal: true

require_relative "test_helper"

class AnnotatorGrammarTest < Minitest::Test
  GRAMMAR = <<~RACC
    class TypedParser
      # @racc-type NUMBER target : Integer
    rule
      target: NUMBER { result = val[0] }
    end
  RACC

  def setup
    @directory = Dir.mktmpdir
    grammar = File.join(@directory, "parser.y")
    output = File.join(@directory, "parser.rb")
    File.write(grammar, GRAMMAR)
    _, error, status = Open3.capture3(RbConfig.ruby, Gem.bin_path("racc", "racc"), grammar, "-o", output)
    assert status.success?, error
    @source = File.read(output)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_upgrades_generic_annotations_and_is_idempotent
    generic = RaccRbsInline.annotate(@source)
    typed = RaccRbsInline.annotate(generic, grammar: GRAMMAR)
    assert_match(/\[Integer\] val, Array\[untyped\] _values, Integer result\) -> Integer/, typed)
    assert_equal typed, RaccRbsInline.annotate(typed, grammar: GRAMMAR)
    assert_equal typed, RaccRbsInline.annotate(typed)
    assert_equal generic.scan("#: ").length, typed.scan("#: ").length
  end

  def test_refreshes_types_without_changing_other_source_bytes
    typed = RaccRbsInline.annotate(@source, grammar: GRAMMAR)
    updated = RaccRbsInline.annotate(typed, grammar: GRAMMAR.gsub("Integer", "String"))
    assert_equal typed.sub("[Integer] val, Array[untyped] _values, Integer result) -> Integer",
                           "[String] val, Array[untyped] _values, String result) -> String"), updated
  end

  def test_grammar_without_declarations_preserves_phase_one_output
    grammar = GRAMMAR.lines.reject { |line| line.include?("@racc-type") }.join
    assert_equal RaccRbsInline.annotate(@source), RaccRbsInline.annotate(@source, grammar: grammar)
  end

  def test_mismatching_grammar_is_rejected_even_when_already_annotated
    source = RaccRbsInline.annotate(@source).freeze
    grammar = GRAMMAR.sub("target: NUMBER", "target: NUMBER NUMBER")
    assert_raises(RaccRbsInline::Error) { RaccRbsInline.annotate(source, grammar: grammar) }
    assert_equal RaccRbsInline.annotate(@source), source
  end

  def test_preserves_crlf_when_updating_annotations
    source = RaccRbsInline.annotate(@source).gsub("\n", "\r\n")
    typed = RaccRbsInline.annotate(source, grammar: GRAMMAR)
    refute_match(/(?<!\r)\n/, typed)
    assert_equal typed, RaccRbsInline.annotate(typed, grammar: GRAMMAR)
  end
end
