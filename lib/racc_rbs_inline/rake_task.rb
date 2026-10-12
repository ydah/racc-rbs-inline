# frozen_string_literal: true
# rbs_inline: enabled

require "rake"
require_relative "cli"

module RaccRbsInline
  class RakeTask
    include Rake::DSL

    attr_accessor :grammar #: String?
    attr_accessor :output #: String?
    attr_accessor :options #: Array[String]

    #: (?Symbol | String name) ?{ (RakeTask) -> void } -> void
    def initialize(name = :parser)
      @grammar = nil
      @output = nil
      @options = []
      yield self if block_given?
      grammar = @grammar
      output = @output
      raise ArgumentError, "grammar and output are required" unless grammar && output

      desc "Generate #{output} with RBS inline annotations"
      task name => output
      file output => grammar do
        FileUtils.mkdir_p(File.dirname(output))
        status = CLI.run(["generate", grammar, "-o", output, "--", *@options])
        raise Error, "parser generation failed (exit #{status})" unless status.zero?
      end
    end
  end
end
