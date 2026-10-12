class TypedCalc
  # @racc-type NUMBER exp target : Integer
  # @racc-type '+' '(' ')' : String
rule
  target: exp { result = val[0] }
  exp: NUMBER { result = val[0] }
     | exp '+' NUMBER { result = val[0] + val[2] }
     | '(' exp ')' { result = val[1] }
end

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
