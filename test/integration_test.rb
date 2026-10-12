# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/integration_helpers"

class IntegrationTest < Minitest::Test
  include IntegrationHelpers

  VARIANTS.each_key do |variant|
    define_method("test_#{variant}_golden_and_behavior") do
      skip "Racc 1.6 does not support --frozen" if variant == "frozen" && legacy_racc?
      Dir.mktmpdir do |dir|
        original = generate_variant(dir, variant)
        annotated = RaccRbsInline.annotate(original)
        expected = expected_golden(variant)
        assert_equal expected, normalize_golden(annotated)
        assert_equal annotated, RaccRbsInline.annotate(annotated)
        if %w[embedded executable].include?(variant)
          runtime = /###### racc\/parser\.rb begin\n.*?###### racc\/parser\.rb end/m
          refute_nil original[runtime]
          assert_equal original[runtime], annotated[runtime]
        end
        klass = variant == "nested" ? "A::B::SumParser" : "SumParser"
        token = variant == "convert" ? "Integer" : ":NUMBER"
        runner = "load File.expand_path(ARGV.fetch(0)); p #{klass}.new([[#{token}, 2], ['+', '+'], [#{token}, 3], [false, nil]]).do_parse"
        before, err, status = command(RbConfig.ruby, "-e", runner, "parser.rb", chdir: dir)
        assert status.success?, err
        File.write(File.join(dir, "parser.rb"), annotated)
        after, err, status = command(RbConfig.ruby, "-e", runner, "parser.rb", chdir: dir)
        assert status.success?, err
        assert_equal "5\n", before
        assert_equal before, after
      end
    end
  end

  def test_both_type_checking_routes
    Dir.mktmpdir do |dir|
      source = RaccRbsInline.annotate(generate_variant(dir, "default"))
      write_type_project(dir, source)
      native = steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
      assert_empty native

      out, err, status = gem_command("rbs-inline", "rbs-inline", "parser.rb", chdir: dir)
      assert status.success?, err
      assert_includes out, "def _reduce_1:"
      File.write(File.join(dir, "sig/generated.rbs"), out)
      out, err, status = gem_command("rbs", "rbs", "-I", "sig", "validate", chdir: dir)
      assert status.success?, "#{out}#{err}"
      File.write(File.join(dir, "Steepfile"), File.read(File.join(dir, "Steepfile")).sub("inline: true", "inline: false"))
      extracted = steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
      assert_empty extracted
    end
  end

  def test_strict_diagnostics_reject_corrupt_nt_base
    Dir.mktmpdir do |dir|
      source = RaccRbsInline.annotate(generate_variant(dir, "default"))
      source = source.sub(/racc_nt_base = \d+/, 'racc_nt_base = "broken"')
      write_type_project(dir, source)
      diagnostics = steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
      assert diagnostics.any? { |d| d["code"] == "Ruby::FalseAssertion" && d["severity"] == "ERROR" }, diagnostics.inspect
    end
  end

  def test_runtime_allows_user_constructors_and_array_tokens
    Dir.mktmpdir do |dir|
      write_type_project(dir, <<~RUBY)
        class UserParser < Racc::Parser
          def initialize(text, mode: :default)
          end

          def next_token
            token = [] #: Array[untyped]
            token << :NUMBER
            token << 1
            token
          end
        end
      RUBY
      diagnostics = steep_diagnostics(dir).flat_map { |entry| entry.fetch("diagnostics") }
      assert_empty diagnostics
    end
  end
end
