class SumParser
rule
  sum: NUMBER { result = val[0] }
     | sum '+' NUMBER { result = val[0] + val[2] }
end

---- header
# Header preserved by annotation.

---- inner
  # @rbs @tokens: Array[Array[untyped]]

  #: (Array[Array[untyped]] tokens) -> void
  def initialize(tokens)
    @tokens = tokens
  end

  #: () -> Array[untyped]?
  def next_token
    @tokens.shift
  end

---- footer
# Footer preserved by annotation.
