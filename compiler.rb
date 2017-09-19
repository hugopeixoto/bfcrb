require 'tempfile'

class Compiler
  def compile code_module, filename = 'a.out'
    #code_module.dump

    Tempfile.open do |file|
      code_module.write_bitcode file

      rasm, wasm = IO.pipe
      spawn "llc-#{LLVM::LLVM_VERSION}", "-relocation-model=pic", in: file, out: wasm
      spawn 'as', '-o', filename, '-', in: rasm

      Process.wait
    end
  end
end
