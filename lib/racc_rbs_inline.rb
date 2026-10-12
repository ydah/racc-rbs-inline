# frozen_string_literal: true
# rbs_inline: enabled

require_relative "racc_rbs_inline/version"

module RaccRbsInline
  class Error < StandardError; end

  #: (String source, ?grammar: String?, ?grammar_filename: String) -> String
  def self.annotate(source, grammar: nil, grammar_filename: "grammar.y")
    Annotator.new.annotate(source, grammar: grammar, grammar_filename: grammar_filename)
  end

  #: (String source) -> bool
  def self.annotated?(source)
    Annotator.new.annotated?(source)
  end
end

require_relative "racc_rbs_inline/annotator"
