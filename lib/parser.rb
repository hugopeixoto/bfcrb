require 'parslet'

class Parser < Parslet::Parser
  rule(:noop) { match('[^+\-><,.\[\]]').repeat(1) }

  rule(:increment) { str('+').as(:increment) }
  rule(:decrement) { str('-').as(:decrement) }
  rule(:forward) { str('>').as(:forward) }
  rule(:backward) { str('<').as(:backward) }
  rule(:read) { str(',').as(:read) }
  rule(:write) { str('.').as(:write) }
  rule(:cycle) { str('[') >> instructions.as(:cycle) >> str(']') }

  rule(:instruction) {
    increment | decrement |
    forward | backward |
    read | write |
    cycle | noop
  }

  rule(:instructions) { instruction.repeat }

  rule(:program) { instructions.as(:program) }

  root(:program)
end
