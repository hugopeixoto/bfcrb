require 'treetop'

class Cell
  attr_accessor :value
  def initialize v=0, n=nil, p=nil
    @value = v
    @next = n
    @prev = p
  end

  def next
    @next ||= Cell.new(0, nil, self)
  end

  def prev
    @prev ||= Cell.new(0, self, nil)
  end
end

Node = ::Treetop::Runtime::SyntaxNode

class Node
  def evaluate cell
    cell
  end
end

class Program < Node
  def evaluate cell
    script.evaluate cell
  end
end

class Sequence < Node
  def evaluate cell
    statements.elements.reduce(cell) do |cell, statement|
      statement.evaluate(cell)
    end
  end
end

class While < Node
  def evaluate cell
    while cell.value != 0
      cell = body.evaluate(cell)
    end

    cell
  end
end

class Increment < Node
  def evaluate cell
    cell.value = (cell.value + 1) % 256;
    cell
  end
end

class Decrement < Node
  def evaluate cell
    cell.value = (cell.value + 255) % 256;
    cell
  end
end

class Forward < Node
  def evaluate cell
    cell.next
  end
end

class Rewind < Node
  def evaluate cell
    cell.prev
  end
end

class Write < Node
  def evaluate cell
    print cell.value.chr
    cell
  end
end

class Read < Node
  def evaluate cell
    cell
  end
end

parser = Treetop.load('bf').new

parser.parse(File.read(ARGV[0])).evaluate Cell.new
