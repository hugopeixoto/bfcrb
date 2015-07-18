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

class Comment
  def evaluate cell
    cell
  end
end

class Sequence < Struct.new(:statements)
  def evaluate cell
    statements.reduce(cell) do |cell, statement|
      statement.evaluate(cell)
    end
  end
end

class While < Struct.new(:body)
  def evaluate cell
    while cell.value != 0
      cell = body.evaluate(cell)
    end

    cell
  end
end

class Increment
  def evaluate cell
    cell.value = (cell.value + 1) % 256;
    cell
  end
end

class Decrement
  def evaluate cell
    cell.value = (cell.value + 255) % 256;
    cell
  end
end

class Forward
  def evaluate cell
    cell.next
  end
end

class Rewind
  def evaluate cell
    cell.prev
  end
end

class Write
  def evaluate cell
    print cell.value.chr
    cell
  end
end

class Read
  def evaluate cell
    cell
  end
end

parser = Treetop.load('bf').new

parser.parse(File.read(ARGV[0])).to_ast.evaluate Cell.new
