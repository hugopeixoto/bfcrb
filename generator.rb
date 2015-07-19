require 'ostruct'
require 'llvm/core'

class Generator
  include LLVM

  Int8 = LLVM::Int8.type
  PCHAR = Int8.pointer

  CellType = LLVM::Int8
  Cell = Type.struct([], false, "cell_t").tap do |c|
    c.element_types = [CellType, c.pointer, c.pointer]
  end

  CellPointer = Cell.pointer

  Block = Struct.new(:head, :tail)

  Zero = LLVM::Int(0)
  One  = LLVM::Int(1)
  Two  = LLVM::Int(2)

  StdOut = LLVM::Int(1)
  StdIn  = LLVM::Int(0)

  attr_accessor :module, :current_function, :current_block, :blocks, :functions
  def initialize
    @module = LLVM::Module.new("bfcrb")
    @functions = OpenStruct.new

    functions.printf = @module.functions.add('printf', Type.function([PCHAR], LLVM::Int32, varargs: true))
    functions.read = @module.functions.add('read', Type.function([LLVM::Int, Int8.pointer, LLVM::Int], LLVM::Int))
    functions.write = @module.functions.add('write', Type.function([LLVM::Int, Int8.pointer, LLVM::Int], LLVM::Int))

    functions.main = @module.functions.add("main", Type.function([LLVM::Int32, PCHAR.pointer], LLVM::Int32))

    @current_function = functions.main

    block = @current_function.basic_blocks.append("entry")
    @blocks = [Block.new(block, block)]
  end

  def current_block
    blocks.last.tail
  end

  def save filename=nil
    filename ||= 'a.out'

    Tempfile.open 'something' do |file|
      @module.write_bitcode file

      rasm,wasm = IO.pipe
      spawn 'llc-3.5', in: file, out: wasm
      spawn 'as', '-o', filename, '-', in: rasm

      Process.wait
    end
  end

  def setup_cell_functions
    functions.cell_init = @module.functions.add(
        "cell_init",
        Type.function([CellPointer], Type.void)) do |f, cell_ptr|
      f.basic_blocks.append.build do |b|
        cell = b.load(cell_ptr)

        cell = b.insert_value(cell, CellType.from_i(0), 0)
        cell = b.insert_value(cell, CellPointer.null, 1)
        cell = b.insert_value(cell, CellPointer.null, 2)

        b.store(cell, cell_ptr)

        b.ret_void
      end
    end

    functions.cell_alloc = @module.functions.add(
        "cell_alloc",
        Type.function([], CellPointer)) do |f|
      f.basic_blocks.append.build do |b|
        b.ret(b.malloc(Cell))
      end
    end

    functions.cell_next = @module.functions.add(
        "cell_next",
        Type.function([CellPointer], CellPointer)) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 1
    end

    functions.cell_prev = @module.functions.add(
        "cell_prev",
        Type.function([CellPointer], CellPointer)) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 2
    end
  end

  def generate_cell_moving_function f, cell_ptr, idx
    entry           = f.basic_blocks.append
    initialize      = f.basic_blocks.append
    return_existing = f.basic_blocks.append

    entry.build do |b|
      b.cond(
        b.icmp(:eq, b.extract_value(b.load(cell_ptr), idx), CellPointer.null),
        initialize,
        return_existing)
    end

    initialize.build do |b|
      prev_ptr = b.load(new_cell_pointer_ref(b))

      prev = b.insert_value(b.load(prev_ptr), cell_ptr, 3-idx)
      b.store(prev, prev_ptr)

      cell = b.insert_value(b.load(cell_ptr), prev_ptr, idx)
      b.store(cell, cell_ptr)

      b.ret(prev_ptr)
    end

    return_existing.build do |b|
      b.ret(b.extract_value(b.load(cell_ptr), idx))
    end
  end

  def start
    setup_cell_functions

    current_block.build do |b|
      @ppcell = new_cell_pointer_ref b
    end
  end

  def new_cell_pointer_ref b
    cell_ptr_ptr = b.alloca(CellPointer)
    b.store(b.call(functions.cell_alloc), cell_ptr_ptr)
    b.call(functions.cell_init, b.load(cell_ptr_ptr))

    cell_ptr_ptr
  end

  def current_value b
    b.extract_value(b.load(b.load(@ppcell)), 0)
  end

  def current_value_ptr b
    b.gep(b.load(@ppcell), [Zero, Zero])
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
      pcell = b.load(@ppcell)
      cell = b.load(pcell)

      cell = b.insert_value(cell, b.add(b.extract_value(cell, 0), CellType.from_i(delta)), 0)

      b.store(cell, pcell)
    end
  end

  def forward
    current_block.build do |b|
      b.store(b.call(functions.cell_next, b.load(@ppcell)), @ppcell)
    end
  end

  def rewind
    current_block.build do |b|
      b.store(b.call(functions.cell_prev, b.load(@ppcell)), @ppcell)
    end
  end

  def loop_start
    loop_block = current_function.basic_blocks.append

    blocks.push(Block.new(loop_block, loop_block))
  end

  def loop_finish
    loop_block = blocks.pop

    escape_block = current_function.basic_blocks.append
    check = current_function.basic_blocks.append

    loop_block.tail.build do |b|
      b.br(check)
    end

    current_block.build do |b|
      b.br(check)
    end

    check.build do |b|
      b.cond(
        b.icmp(:eq, current_value(b), CellType.from_i(0)),
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
