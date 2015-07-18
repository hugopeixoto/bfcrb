require 'treetop'
require_relative 'generator'

Node = ::Treetop::Runtime::SyntaxNode

class Node
  def codegen g
  end
end

class Program < Node
  def codegen g
    g.start
    script.codegen g
    g.finish
  end
end

class Sequence < Node
  def codegen g
    statements.elements.each do |statement|
      statement.codegen g
    end
  end
end

class While < Node
  def codegen g
    g.loop_start
    body.codegen g
    g.loop_finish
  end
end

class Increment < Node
  def codegen g
    g.increment
  end
end

class Decrement < Node
  def codegen g
    g.decrement
  end
end

class Forward < Node
  def codegen g
    g.forward
  end
end

class Rewind < Node
  def codegen g
    g.rewind
  end
end

class Write < Node
  def codegen g
    g.write
  end
end

class Read < Node
  def codegen g
    g.read
  end
end

parser = Treetop.load('bf').new

Generator.new.tap do |g|
  parser.parse(File.read(ARGV[0])).codegen g

  g.save "bf.bc"
end



