require 'parslet'

class Transformer < Parslet::Transform
  rule(increment: simple(:x)) { Increment.new }
  rule(decrement: simple(:x)) { Decrement.new }
  rule(forward: simple(:x)) { Forward.new }
  rule(backward: simple(:x)) { Backward.new }
  rule(read: simple(:x)) { Read.new }
  rule(write: simple(:x)) { Write.new }
  rule(cycle: sequence(:instructions)) { While.new(instructions) }
  rule(program: sequence(:instructions)) { Program.new(instructions) }
end

class Program < Struct.new(:instructions)
  def codegen g
    g.start
    instructions.each { |instruction| instruction.codegen g }
    g.finish
  end
end

class While < Struct.new(:instructions)
  def codegen g
    g.loop_start
    instructions.each { |instruction| instruction.codegen g }
    g.loop_finish
  end
end

class Increment
  def codegen g
    g.increment
  end
end

class Decrement
  def codegen g
    g.decrement
  end
end

class Forward
  def codegen g
    g.forward
  end
end

class Backward
  def codegen g
    g.backward
  end
end

class Write
  def codegen g
    g.write
  end
end

class Read
  def codegen g
    g.read
  end
end
