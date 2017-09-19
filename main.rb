require_relative 'generator'
require_relative 'parser'
require_relative 'transformer'
require_relative 'compiler'

ast = Parser.new.parse(File.read(ARGV[0]))
ast = Transformer.new.apply(ast)

generator = Generator.new
ast.codegen generator

Compiler.new.compile(generator.module, ARGV[1])
