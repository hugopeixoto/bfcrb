require 'ostruct'
require 'llvm/core'

class Generator
  Zero = LLVM::Int(0)

  StdIn = LLVM::Int(0)
  StdOut = LLVM::Int(1)
  StdErr = LLVM::Int(2)

  PageSize = LLVM::Int(4096)

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
    apply_delta_to_current_value LLVM::Int8.from_i(1)
  end

  def decrement
    apply_delta_to_current_value LLVM::Int8.from_i(-1)
  end

  def forward
    current_block.build do |b|
      b.call(functions.cell_move, LLVM::Int.from_i(1))
    end
  end

  def backward
    current_block.build do |b|
      b.call(functions.cell_move, LLVM::Int.from_i(-1))
    end
  end

  def write
    current_block.build do |b|
      cell_ptr = current_value_ptr(b)

      b.call(functions.write, StdOut, cell_ptr, LLVM::Int.from_i(1))
    end
  end

  def read
    current_block.build do |b|
      cell_ptr = current_value_ptr(b)

      b.call(functions.read, StdIn, cell_ptr, LLVM::Int.from_i(1))
    end
  end

  def loop_start
    loop_block = functions.main.basic_blocks.append

    blocks.push([loop_block, loop_block])
  end

  def loop_finish
    loop_start_block, loop_finish_block = blocks.pop

    check_block = functions.main.basic_blocks.append
    escape_block = functions.main.basic_blocks.append

    loop_finish_block.build do |b|
      b.br(check_block)
    end

    current_block.build do |b|
      b.br(check_block)
    end

    check_block.build do |b|
      b.cond(
        b.icmp(:eq, current_value(b), LLVM::Int8.from_i(0)),
        escape_block,
        loop_start_block)
    end

    blocks.last[1] = escape_block
  end

  private
  def current_block
    blocks.last[1]
  end

  def apply_delta_to_current_value delta
    current_block.build do |b|
      cell_ptr = current_value_ptr(b)

      b.store(b.add(b.load(cell_ptr), delta), cell_ptr)
    end
  end

  def current_value_ptr b
    b.gep(b.load(@tape), [b.load(@index)])
  end

  def current_value b
    b.load(current_value_ptr(b))
  end

  def setup_global_state
    @tape = @module.globals.add(LLVM::Int8.type.pointer, :tape) do |var|
      var.linkage = :private
      var.initializer = var.type.null
    end

    @size = @module.globals.add(LLVM::Int, :size) do |var|
      var.linkage = :private
      var.initializer = PageSize
    end

    @index = @module.globals.add(LLVM::Int, :index) do |var|
      var.linkage = :private
      var.initializer = Zero
    end
  end

  def setup_external_functions
    {
      "read" => [[LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int],
      "write" => [[LLVM::Int, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int],
      "realloc" => [[LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int8.type.pointer],
      "memset" => [[LLVM::Int8.type.pointer, LLVM::Int8.type, LLVM::Int], LLVM::Int8.type.pointer],
      "memmove" => [[LLVM::Int8.type.pointer, LLVM::Int8.type.pointer, LLVM::Int], LLVM::Int8.type.pointer],
    }.each do |name, (args, ret)|
      register_function(name, args, ret)
    end

    register_function("dprintf", [LLVM::Int, LLVM::Int8.type.pointer], LLVM::Int, varargs: true)
  end

  def setup_cell_functions
    register_function("cell_move", [LLVM::Int], LLVM::Type.void) do |f, delta|
      fwd_check_block = f.basic_blocks.append
      bwd_check_block = f.basic_blocks.append
      fwd_expand_block = f.basic_blocks.append
      bwd_expand_block = f.basic_blocks.append
      return_block = f.basic_blocks.append

      fwd_check_block.build do |b|
        b.store(b.add(b.load(@index), delta), @index)
        b.cond(
          b.icmp(:slt, b.load(@index), b.load(@size)),
          bwd_check_block,
          fwd_expand_block,
        )
      end

      bwd_check_block.build do |b|
        b.cond(
          b.icmp(:slt, b.load(@index), Zero),
          bwd_expand_block,
          return_block,
        )
      end

      fwd_expand_block.build do |b|
        final_size = b.add(b.load(@size), PageSize)
        b.store(b.call(functions.realloc, b.load(@tape), final_size), @tape)

        b.call(functions.memset, b.gep(b.load(@tape), [b.load(@size)]), LLVM::Int8.from_i(0), PageSize)
        b.store(final_size, @size)
        b.ret_void
      end

      bwd_expand_block.build do |b|
        final_size = b.add(b.load(@size), PageSize)
        b.store(b.call(functions.realloc, b.load(@tape), final_size), @tape)

        b.call(functions.memmove, b.gep(b.load(@tape), [PageSize]), b.gep(b.load(@tape), [Zero]), b.load(@size))
        b.call(functions.memset, b.gep(b.load(@tape), [Zero]), LLVM::Int8.from_i(0), PageSize)

        b.store(final_size, @size)
        b.store(b.add(b.load(@index), PageSize), @index)
        b.ret_void
      end

      return_block.build do |b|
        b.ret_void
      end
    end
  end

  def setup_main
    register_function(
      "main",
      [LLVM::Int32, LLVM::Int8.type.pointer.pointer],
      LLVM::Int32
    )

    block = functions.main.basic_blocks.append
    @blocks = [[block, block]]

    current_block.build do |b|
      b.store(b.array_malloc(LLVM::Int8, PageSize, "tape"), @tape)

      b.call(functions.memset, b.load(@tape), LLVM::Int8.from_i(0), PageSize)
    end
  end

  def register_function(name, args, ret, opts = {}, &block)
    functions[name] = @module.functions.add(
      name,
      LLVM::Type.function(args, ret, opts),
      &block
    )
  end
end
