# frozen_string_literal: true
# rbs_inline: enabled

require_relative "racc_rbs_inline/version"

module RaccRbsInline
  class Error < StandardError; end

  #: (String source) -> String
  def self.annotate(source)
    Annotator.new.annotate(source)
  end

  #: (String source) -> bool
  def self.annotated?(source)
    Annotator.new.annotated?(source)
  end
end

require_relative "racc_rbs_inline/annotator"
