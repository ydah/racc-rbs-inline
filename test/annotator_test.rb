# frozen_string_literal: true

require_relative "test_helper"

class AnnotatorTest < Minitest::Test
  def annotate(body, prefix: "")
    RaccRbsInline.annotate("#{prefix}class Parser\n#{body}\nRacc_arg = []\nend\n")
  end

  def test_annotates_every_table_and_constant
    names = %w[action goto].product(%w[table check pointer default]).map { |parts| "racc_#{parts.join('_')}" }
    body = names.map { |name| "#{name} = []" }.join("\n")
    body += "\nracc_reduce_table = [0, :_reduce_none]\nracc_token_table = {false => 0, :NUMBER => 1, '+' => 2}"
    body += "\nRacc_token_to_s_table = ['NUMBER']\nRacc_debug_parser = false\nracc_nt_base = 3"
    result = annotate(body)

    names.each { |name| assert_includes result, "#{name} = [] #: Array[Integer?]" }
    assert_includes result, "racc_reduce_table = [0, :_reduce_none] #: Array[Integer | Symbol]"
    assert_includes result, "racc_token_table = {false => 0, :NUMBER => 1, '+' => 2} #: Hash[::Racc::Parser::token_symbol, Integer]"
    assert_includes result, "Racc_arg = [] #: ::Racc::Parser::racc_arg"
    assert_includes result, "Racc_token_to_s_table = ['NUMBER'] #: Array[String]"
    assert_includes result, "Racc_debug_parser = false #: bool"
    assert_includes result, "racc_nt_base = 3\n"
  end

  def test_convert_and_hash_splats_use_untyped_token_keys
    ["{TOKEN => 1}", "{1 => 1}", "{**tokens}", "tokens"].each do |value|
      assert_includes annotate("racc_token_table = #{value}"), "#{value} #: Hash[untyped, Integer]"
    end
  end

  def test_unwraps_actions_and_preserves_user_annotations
    body = <<~'RUBY'
      module_eval(<<'ACTION', 'grammar.y', 2)
        # User code: 日本語
        #: () -> String
        def message
          "こんにちは"
        end

        def _reduce_1(val, _values, result)
          result = val[0]
        end
      ACTION
    RUBY
    result = annotate(body)
    assert_includes result, "  #: () -> String\n  def message\n    \"こんにちは\"\n  end"
    assert_includes result, "  #: (Array[untyped] val, Array[untyped] _values, untyped result) -> untyped\n  def _reduce_1"
    refute_includes result, "module_eval"
    refute_includes result, "ACTION"
  end

  def test_annotates_two_and_three_parameter_reductions_only
    result = annotate("  def _reduce_3(val, _values, result)\n    result\n  end\n  def _reduce_none(val, _values)\n    val[0]\n  end\n  def _reduce_custom(val)\n    val\n  end")
    assert_includes result, "  #: (Array[untyped] val, Array[untyped] _values, untyped result) -> untyped\n  def _reduce_3"
    assert_includes result, "  #: (Array[untyped] val, Array[untyped] _values) -> untyped\n  def _reduce_none"
    assert_includes result, "  end\n  def _reduce_custom"
  end

  def test_does_not_touch_header_footer_or_embedded_runtime
    wrapper = "self.class.module_eval(<<'CODE', 'parser.rb', 1)\nclass Runtime; end\nCODE\n"
    outside = "module_eval(<<'CODE', 'grammar.y', 1)\n# 日本語\nracc_action_table = []\nCODE\n"
    parser = "class Parser\nRacc_arg = []\nend\n"
    result = RaccRbsInline.annotate(wrapper + outside + parser + outside)
    assert_equal "# rbs_inline: enabled\n" + wrapper + outside + "class Parser\nRacc_arg = [] #: ::Racc::Parser::racc_arg\nend\n" + outside, result
  end

  def test_does_not_touch_nested_user_definitions_or_explicit_receivers
    body = "class User\n  racc_action_table = []\n  def _reduce_1(val, _values, result); end\nend\nother.module_eval(<<'CODE')\nracc_goto_table = []\nCODE"
    assert_includes annotate(body), body
  end

  def test_finds_namespaced_and_multiple_parsers
    source = "module A\nclass B::Parser\nRacc_arg = []\nend\nend\nclass Other\nRacc_arg = []\nend\n"
    assert_equal 2, RaccRbsInline.annotate(source).scan("#: ::Racc::Parser::racc_arg").size
  end

  def test_places_magic_after_shebang_and_frozen_comment
    prefix = "#!/usr/bin/env ruby\n# frozen_string_literal: true\n"
    assert annotate("", prefix: prefix).start_with?(prefix + "# rbs_inline: enabled\n")
  end

  def test_retains_encoding_comment_on_second_line_and_original_bytes
    source = "#!/usr/bin/env ruby\n# coding: Windows-31J\nclass Parser\n# 日本語\nRacc_arg = []\nend\n".encode(Encoding::Windows_31J)
    result = RaccRbsInline.annotate(source)
    assert_equal source.encoding, result.encoding
    assert_equal source.b.sub("class Parser", "# rbs_inline: enabled\nclass Parser").sub("Racc_arg = []", "Racc_arg = [] #: ::Racc::Parser::racc_arg"), result.b
  end

  def test_preserves_crlf_and_input_object
    source = "class Parser\r\nRacc_arg = []\r\nend\r\n".freeze
    result = RaccRbsInline.annotate(source)
    assert_equal "# rbs_inline: enabled\r\nclass Parser\r\nRacc_arg = [] #: ::Racc::Parser::racc_arg\r\nend\r\n", result
    assert_equal "class Parser\r\nRacc_arg = []\r\nend\r\n", source
  end

  def test_idempotency_and_detection
    source = "class Parser\nRacc_arg = []\nend\n"
    refute RaccRbsInline.annotated?(source)
    result = RaccRbsInline.annotate(source)
    assert RaccRbsInline.annotated?(result)
    assert_equal result, RaccRbsInline.annotate(result)
    assert_equal "# rbs_inline: enabled", RaccRbsInline.annotate("# rbs_inline: enabled")
  end

  def test_magic_in_a_string_does_not_skip_annotation
    body = "text = \"# rbs_inline: enabled\\n\""
    result = annotate(body)
    assert_includes result, "Racc_arg = [] #: ::Racc::Parser::racc_arg"
  end

  def test_magic_in_a_heredoc_does_not_skip_annotation
    body = "text = <<'TEXT'\n# rbs_inline: enabled\nTEXT"
    assert_includes annotate(body), "Racc_arg = [] #: ::Racc::Parser::racc_arg"
  end

  def test_rejects_unsupported_reduction_parameters
    assert_raises(RaccRbsInline::Error) { annotate("def _reduce_1(val); val; end") }
  end

  def test_rejects_invalid_source_and_missing_parser
    ["class Parser", "class User; end", "Racc_arg = []"].each do |source|
      assert_raises(RaccRbsInline::Error) { RaccRbsInline.annotate(source) }
    end
  end

  def test_rejects_invalid_unwrapped_action_without_mutating_source
    source = "class Parser\nmodule_eval(<<'CODE')\ndef broken(\nCODE\nRacc_arg = []\nend\n"
    original = source.dup
    assert_raises(RaccRbsInline::Error) { RaccRbsInline.annotate(source) }
    assert_equal original, source
  end
end
