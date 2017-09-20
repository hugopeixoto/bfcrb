require 'ostruct'
require 'llvm/core'

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

  StdIn = LLVM::Int(0)
  StdOut = LLVM::Int(1)
  StdErr = LLVM::Int(2)

  attr_accessor :module, :blocks, :functions

  def initialize
    @module = LLVM::Module.new("bfcrb")
    @functions = OpenStruct.new
  end

  def start
    setup_global_state
    setup_external_functions
    setup_cell_functions
    setup_main
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

  def forward
    current_block.build do |b|
      b.call(functions.cell_next)
    end
  end

  def backward
    current_block.build do |b|
      b.call(functions.cell_prev)
    end
  end

  def loop_start
    loop_block = functions.main.basic_blocks.append

    blocks.push(Block.new(loop_block, loop_block))
  end

  def loop_finish
    loop_block = blocks.pop

    check_block = functions.main.basic_blocks.append
    escape_block = functions.main.basic_blocks.append

    loop_block.tail.build do |b|
      b.br(check_block)
    end

    current_block.build do |b|
      b.br(check_block)
    end

    check_block.build do |b|
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

  private
  def apply_delta_to_current_value delta
    current_block.build do |b|
      b.store(
        b.add(current_value(b), Types::Cell::Value.from_i(delta)),
        current_value_ptr(b),
      )
    end
  end

  def current_value_ptr b
    b.gep(b.load(@cell), [Zero, Types::Cell::ValueOffset])
  end

  def current_value b
    b.load(current_value_ptr(b))
  end

  def setup_global_state
    @cell = @module.globals.add(Types::Cell::Struct.pointer, :cell_ptr) do |var|
      var.linkage = :private
      var.initializer = var.type.null
    end
  end

  def setup_external_functions
    register_function("read", [LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int)
    register_function("write", [LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int)
  end

  def setup_cell_functions
    register_function("cell_next", [], LLVM::Type.void) do |f|
      generate_cell_moving_function f, 1
    end

    register_function("cell_prev", [], LLVM::Type.void) do |f|
      generate_cell_moving_function f, 2
    end
  end

  def setup_main
    register_function(
      "main",
      [LLVM::Int32, LLVM::Int8.type.pointer.pointer],
      LLVM::Int32
    )

    block = functions.main.basic_blocks.append
    @blocks = [Block.new(block, block)]

    current_block.build do |b|
      b.store(b.malloc(Types::Cell::Struct), @cell)

      [
        Types::Cell::Value.from_i(0),
        Types::Cell::Struct.pointer.null,
        Types::Cell::Struct.pointer.null,
      ].each_with_index do |value, index|
        b.store(
          value,
          b.gep(b.load(@cell), [Zero, LLVM::Int.from_i(index)]),
        )
      end
    end
  end

  def generate_cell_moving_function f, idx
    entry = f.basic_blocks.append
    initialize = f.basic_blocks.append
    return_existing = f.basic_blocks.append

    entry.build do |b|
      b.cond(
        b.icmp(
          :eq,
          b.load(b.gep(b.load(@cell), [Zero, LLVM::Int.from_i(idx)])),
          Types::Cell::Struct.pointer.null
        ),
        initialize,
        return_existing)
    end

    initialize.build do |b|
      new_cell_ptr = b.alloca(Types::Cell::Struct.pointer)
      b.store(b.malloc(Types::Cell::Struct), new_cell_ptr)

      b.store(Types::Cell::Value.from_i(0), b.gep(b.load(new_cell_ptr), [Zero, Types::Cell::ValueOffset]))
      b.store(b.load(@cell), b.gep(b.load(new_cell_ptr), [Zero, LLVM::Int.from_i(3-idx)]))
      b.store(b.load(new_cell_ptr), b.gep(b.load(@cell), [Zero, LLVM::Int.from_i(idx)]))

      b.store(b.load(new_cell_ptr), @cell)
      b.ret_void
    end

    return_existing.build do |b|
      b.store(b.load(b.gep(b.load(@cell), [Zero, LLVM::Int.from_i(idx)])), @cell)
      b.ret_void
    end
  end

  def current_block
    blocks.last.tail
  end

  def register_function(name, args, ret, opts = {}, &block)
    functions[name] = @module.functions.add(
      name,
      LLVM::Type.function(args, ret, opts),
      &block
    )
  end
end