require 'ostruct'
require 'llvm/core'

class Generator
  Int8 = LLVM::Int8.type
  PCHAR = Int8.pointer

  CellType = LLVM::Int8
  Cell = LLVM::Type.struct([], false, "cell_t").tap do |c|
    c.element_types = [CellType, c.pointer, c.pointer]
  end

  Block = Struct.new(:head, :tail)

  Zero = LLVM::Int(0)
  One  = LLVM::Int(1)
  Two  = LLVM::Int(2)

  StdOut = One
  StdIn  = Zero

  attr_accessor :module, :current_function, :current_block, :blocks, :functions

  def register_function name, args, ret, &block
    functions[name] = @module.functions.add(name, LLVM::Type.function(args, ret), &block)
  end

  def initialize
    @module = LLVM::Module.new("bfcrb")
    @functions = OpenStruct.new

    register_function('read',  [LLVM::Int, Int8.pointer, LLVM::Int], LLVM::Int)
    register_function('write', [LLVM::Int, Int8.pointer, LLVM::Int], LLVM::Int)
    register_function("main",  [LLVM::Int32, PCHAR.pointer], LLVM::Int32)

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
    register_function("cell_init", [Cell.pointer], LLVM::Type.void) do |f, cell_ptr|
      f.basic_blocks.append.build do |b|

        b.store(CellType.from_i(0), b.gep(cell_ptr, [Zero, Zero]))
        b.store(Cell.pointer.null,  b.gep(cell_ptr, [Zero, One]))
        b.store(Cell.pointer.null,  b.gep(cell_ptr, [Zero, Two]))

        b.ret_void
      end
    end

    register_function("cell_alloc", [], Cell.pointer) do |f|
      f.basic_blocks.append.build do |b|
        b.ret(b.malloc(Cell))
      end
    end

    register_function("cell_next", [Cell.pointer], Cell.pointer) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 1
    end

    register_function("cell_prev", [Cell.pointer], Cell.pointer) do |f, cell_ptr|
      generate_cell_moving_function f, cell_ptr, 2
    end
  end

  def generate_cell_moving_function f, cell_ptr, idx
    entry           = f.basic_blocks.append
    initialize      = f.basic_blocks.append
    return_existing = f.basic_blocks.append

    entry.build do |b|
      b.cond(
        b.icmp(:eq, b.extract_value(b.load(cell_ptr), idx), Cell.pointer.null),
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
      @ppcell = new_cell_pointer_ref b
    end
  end

  def new_cell_pointer_ref b
    cell_ptr_ptr = b.alloca(Cell.pointer)
    b.store(b.call(functions.cell_alloc), cell_ptr_ptr)
    b.call(functions.cell_init, b.load(cell_ptr_ptr))

    cell_ptr_ptr
  end

  def current_cell_ptr b
    b.load(@ppcell)
  end

  def current_value_ptr b
    b.gep(current_cell_ptr(b), [Zero, Zero])
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
      b.store(b.add(current_value(b), CellType.from_i(delta)), current_value_ptr(b))
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
