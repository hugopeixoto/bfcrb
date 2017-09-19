require 'ostruct'
require 'llvm/core'
require 'tempfile'

module Types
  module Cell
    Value = LLVM::Int8
    Struct = LLVM::Type.struct([], false, "cell_t").tap do |c|
      c.element_types = [Value, c.pointer, c.pointer]
    end

    ValueOffset = LLVM::Int(0)
    NextOffset = LLVM::Int(1)
    PrevOffset = LLVM::Int(2)
  end
end

class Generator
  Block = Struct.new(:head, :tail)

  Zero = LLVM::Int(0)

  StdIn  = LLVM::Int(0)
  StdOut  = LLVM::Int(1)
  StdErr  = LLVM::Int(2)

  attr_accessor :module, :current_block, :blocks, :functions

  def register_function name, args, ret, opts = {}, &block
    functions[name] = @module.functions.add(name, LLVM::Type.function(args, ret, opts), &block)
  end

  def initialize
    @module = LLVM::Module.new("bfcrb")
    @functions = OpenStruct.new

    register_function("read",  [LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int)
    register_function("write", [LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int)
    register_function("main",  [LLVM::Int32, LLVM::Int8.type.pointer.pointer], LLVM::Int32)

    block = functions.main.basic_blocks.append
    @blocks = [Block.new(block, block)]
  end

  def current_block
    blocks.last.tail
  end

  def setup_cell_functions
    register_function(
      "cell_init",
      [Types::Cell::Struct.pointer],
      LLVM::Type.void,
    ) do |f, cell_ptr|
      f.basic_blocks.append.build do |b|
        [
          Types::Cell::Value.from_i(0),
          Types::Cell::Struct.pointer.null,
          Types::Cell::Struct.pointer.null,
        ].each_with_index do |value, index|
          b.store(value, b.gep(cell_ptr, [Zero, LLVM::Int(index)]))
        end

        b.ret_void
      end
    end

    register_function(
      "cell_alloc",
      [],
      Types::Cell::Struct.pointer,
    ) do |f|
      f.basic_blocks.append.build do |b|
        b.ret(b.malloc(Types::Cell::Struct))
      end
    end

    register_function(
      "cell_next",
      [Types::Cell::Struct.pointer],
      Types::Cell::Struct.pointer,
    ) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 1
    end

    register_function(
      "cell_prev",
      [Types::Cell::Struct.pointer],
      Types::Cell::Struct.pointer,
    ) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 2
    end
  end

  def generate_cell_moving_function f, cell_ptr, idx
    entry = f.basic_blocks.append
    initialize = f.basic_blocks.append
    return_existing = f.basic_blocks.append

    entry.build do |b|
      b.cond(
        b.icmp(:eq, b.extract_value(b.load(cell_ptr), idx), Types::Cell::Struct.pointer.null),
        initialize,
        return_existing)
    end

    initialize.build do |b|
      prev_ptr = b.load(new_cell_pointer_ref(b))

      b.store(cell_ptr, b.gep(prev_ptr, [Zero, LLVM::Int.from_i(3-idx)]))
      b.store(prev_ptr, b.gep(cell_ptr, [Zero, LLVM::Int.from_i(idx)]))

      b.ret(prev_ptr)
    end

    return_existing.build do |b|
      b.ret(b.extract_value(b.load(cell_ptr), idx))
    end
  end

  def start
    setup_cell_functions

    current_block.build do |b|
      @current_cell_ptr = new_cell_pointer_ref b
    end
  end

  def new_cell_pointer_ref b
    cell_ptr_ptr = b.alloca(Types::Cell::Struct.pointer)
    b.store(b.call(functions.cell_alloc), cell_ptr_ptr)
    b.call(functions.cell_init, b.load(cell_ptr_ptr))

    cell_ptr_ptr
  end

  def current_value_ptr b
    b.gep(b.load(@current_cell_ptr), [Zero, Types::Cell::ValueOffset])
  end

  def current_value b
    b.load(current_value_ptr(b))
  end

  def finish
    current_block.build do |b|
      b.ret(Zero)
    end
  end

  def increment
    apply_delta_to_current_value 1
  end

  def decrement
    apply_delta_to_current_value -1
  end

  def apply_delta_to_current_value delta
    current_block.build do |b|
      b.store(b.add(current_value(b), Types::Cell::Value.from_i(delta)), current_value_ptr(b))
    end
  end

  def forward
    current_block.build do |b|
      b.store(b.call(functions.cell_next, b.load(@current_cell_ptr)), @current_cell_ptr)
    end
  end

  def backward
    current_block.build do |b|
      b.store(b.call(functions.cell_prev, b.load(@current_cell_ptr)), @current_cell_ptr)
    end
  end

  def loop_start
    loop_block = functions.main.basic_blocks.append

    blocks.push(Block.new(loop_block, loop_block))
  end

  def loop_finish
    loop_block = blocks.pop

    check = functions.main.basic_blocks.append
    escape_block = functions.main.basic_blocks.append

    loop_block.tail.build do |b|
      b.br(check)
    end

    current_block.build do |b|
      b.br(check)
    end

    check.build do |b|
      b.cond(
        b.icmp(:eq, current_value(b), Types::Cell::Value.from_i(0)),
        escape_block,
        loop_block.head)
    end

    blocks.last.tail = escape_block
  end

  def write
    current_block.build do |b|
      b.call(functions.write, StdOut, current_value_ptr(b), LLVM::Int.from_i(1))
    end
  end

  def read
    current_block.build do |b|
      b.call(functions.read, StdIn, current_value_ptr(b), LLVM::Int.from_i(1))
    end
  end
end
