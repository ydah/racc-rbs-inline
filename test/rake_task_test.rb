# frozen_string_literal: true

require_relative "test_helper"
require "racc_rbs_inline/rake_task"

class RakeTaskTest < Minitest::Test
  def setup
    @application = Rake.application
    Rake.application = Rake::Application.new
    @dir = Dir.mktmpdir("racc-rbs-inline-rake-")
  end

  def teardown
    Rake.application = @application
    FileUtils.remove_entry(@dir)
  end

  def test_file_task_generates_an_annotated_parser_and_respects_timestamps
    grammar = File.join(@dir, "parser.y")
    output = File.join(@dir, "lib", "parser.rb")
    File.write(grammar, "class Example\nrule\n  target: NUMBER { result = val[0] }\nend\n")
    RaccRbsInline::RakeTask.new(:parser) do |task|
      task.grammar = grammar
      task.output = output
      task.options = ["--embedded"]
    end
    assert_equal [grammar], Rake::Task[output].prerequisites
    Rake::Task[:parser].invoke
    assert RaccRbsInline.annotated?(File.binread(output))
    assert_includes File.binread(output), "class Parser"
    timestamp = File.mtime(output)
    Rake::Task[output].reenable
    Rake::Task[output].invoke
    assert_equal timestamp, File.mtime(output)
  end

  def test_configuration_requires_grammar_and_output
    assert_raises(ArgumentError) { RaccRbsInline::RakeTask.new(:parser) }
    assert_raises(ArgumentError) do
      RaccRbsInline::RakeTask.new(:parser) { |task| task.grammar = "parser.y" }
    end
  end

  def test_generation_failure_raises_and_preserves_output
    grammar = File.join(@dir, "bad.y")
    output = File.join(@dir, "parser.rb")
    File.write(grammar, "invalid grammar\n")
    File.write(output, "existing parser\n")
    File.utime(Time.at(0), Time.at(0), output)
    RaccRbsInline::RakeTask.new(:parser) do |task|
      task.grammar = grammar
      task.output = output
    end
    capture_io do
      assert_raises(RaccRbsInline::Error) { Rake::Task[:parser].invoke }
    end
    assert_equal "existing parser\n", File.read(output)
  end
end
