require_relative 'core_ext/module'
require_relative 'visitor'

module Crystal
  # Base class for nodes in the grammar.
  class ASTNode
    attr_accessor :line_number
    attr_accessor :column_number
    attr_accessor :source_code
    attr_accessor :parent

    def location
      [@line_number, @column_number]
    end

    def location=(line_and_column_number)
      @line_number, @column_number = line_and_column_number
    end

    def self.inherited(klass)
      name = klass.simple_name.downcase

      klass.class_eval %Q(
        def accept(visitor)
          if visitor.visit_#{name} self
            accept_children visitor
          end
          visitor.end_visit_#{name} self
        end
      )

      Visitor.class_eval %Q(
        def visit_#{name}(node)
          true
        end

        def end_visit_#{name}(node)
        end
      )
    end

    def accept_children(visitor)
    end
  end

  # A container for one or many expressions.
  # A method's body and a block's body, for
  # example, are Expressions.
  class Expressions < ASTNode
    include Enumerable

    attr_accessor :expressions

    def self.from(obj)
      case obj
      when nil
        new
      when Expressions
        obj
      when ::Array
        new obj
      else
        new [obj]
      end
    end

    def initialize(expressions = [])
      @expressions = expressions
      @expressions.each { |e| e.parent = self }
    end

    def each(&block)
      @expressions.each(&block)
    end

    def [](i)
      @expressions[i]
    end

    def last
      @expressions.last
    end

    def <<(exp)
      exp.parent = self
      @expressions << exp
    end

    def empty?
      @expressions.empty?
    end

    def accept_children(visitor)
      expressions.each { |exp| exp.accept visitor }
    end

    def ==(other)
      other.class == self.class && other.expressions == expressions
    end

    def clone
      exps = self.class.new expressions.map(&:clone)
      exps.location = location
      exps
    end
  end

  # An array literal.
  #
  #  '[' ( expression ( ',' expression )* ) ']'
  #
  class Array < Expressions
  end

  # Class definition:
  #
  #     'class' name [ '<' superclass ]
  #       body
  #     'end'
  #
  class ClassDef < ASTNode
    attr_accessor :name
    attr_accessor :body
    attr_accessor :superclass

    def initialize(name, body = nil, superclass = nil)
      @name = name
      @body = Expressions.from body
      @body.parent = self
      @superclass = superclass
    end

    def accept_children(visitor)
      body.accept visitor
    end

    def ==(other)
      other.class == self.class && other.name == name && other.body == body && other.superclass == superclass
    end

    def clone
      class_def = self.class.new name, body.clone, superclass
      class_def.location = location
      class_def
    end
  end

  # The nil literal.
  #
  #     'nil'
  #
  class Nil < ASTNode
    def ==(other)
      other.class == self.class
    end

    def clone
      self.class.new
    end
  end

  # A bool literal.
  #
  #     'true' | 'false'
  #
  class Bool < ASTNode
    attr_accessor :value

    def initialize(value)
      @value = value
    end

    def ==(other)
      other.class == self.class && other.value == value
    end

    def clone
      self.class.new value
    end
  end

  # An integer literal.
  #
  #     \d+
  #
  class Int < ASTNode
    attr_accessor :value

    def initialize(value)
      @value = value.to_i
    end

    def ==(other)
      other.class == self.class && other.value.to_i == value.to_i
    end

    def clone
      self.class.new value
    end
  end

  # A float literal.
  #
  #     \d+.\d+
  #
  class Float < ASTNode
    attr_accessor :value

    def initialize(value)
      @value = value.to_f
    end

    def ==(other)
      other.class == self.class && other.value.to_f == value.to_f
    end

    def clone
      self.class.new value
    end
  end

  # A char literal.
  #
  #     "'" \w "'"
  #
  class Char < ASTNode
    attr_accessor :value

    def initialize(value)
      @value = value
    end

    def ==(other)
      other.class == self.class && other.value.to_i == value.to_i
    end

    def clone
      self.class.new value
    end
  end

  # A method definition.
  #
  #     [ receiver '.' ] 'def' name
  #       body
  #     'end'
  #   |
  #     [ receiver '.' ] 'def' name '(' [ arg [ ',' arg ]* ] ')'
  #       body
  #     'end'
  #   |
  #     [ receiver '.' ] 'def' name arg [ ',' arg ]*
  #       body
  #     'end'
  #
  class Def < ASTNode
    attr_accessor :receiver
    attr_accessor :name
    attr_accessor :args
    attr_accessor :body

    def initialize(name, args, body, receiver = nil)
      @name = name
      @args = args
      @args.each { |arg| arg.parent = self } if @args
      @body = Expressions.from body
      @body.parent = self
      @receiver = receiver
      @receiver.parent = self if @receiver
    end

    def accept_children(visitor)
      reciever.accept visitor if receiver
      args.each { |arg| arg.accept visitor }
      body.accept visitor
    end

    def ==(other)
      other.class == self.class && other.receiver == receiver && other.name == name && other.args == args && other.body == body
    end

    def clone
      a_def = self.class.new name, args.map(&:clone), body.clone, receiver ? receiver.clone : nil
      a_def.location = location
      a_def
    end
  end

  # A local variable, instance variable, constant,
  # or def or block argument.
  class Var < ASTNode
    attr_accessor :name

    def initialize(name)
      @name = name
    end

    def instance_var?
      @name.start_with? '@'
    end

    def constant?
      name[0] == name[0].upcase
    end

    def ==(other)
      other.class == self.class && other.name == name
    end

    def clone
      var = self.class.new name
      var.location = location
      var
    end
  end

  # A method call.
  #
  #     [ obj '.' ] name '(' ')' [ block ]
  #   |
  #     [ obj '.' ] name '(' arg [ ',' arg ]* ')' [ block]
  #   |
  #     [ obj '.' ] name arg [ ',' arg ]* [ block ]
  #   |
  #     arg name arg
  #
  # The last syntax is for infix operators, and name will be
  # the symbol of that operator instead of a string.
  #
  class Call < ASTNode
    attr_accessor :obj
    attr_accessor :name
    attr_accessor :args
    attr_accessor :block
    attr_accessor :target_def

    attr_accessor :name_column_number
    attr_accessor :has_parenthesis

    def initialize(obj, name, args = [], block = nil, name_column_number = nil, has_parenthesis = false)
      @obj = obj
      @obj.parent = self if @obj
      @name = name
      @args = args || []
      @args.each { |arg| arg.parent = self }
      @block = block
      @block.parent = self if @block
      @name_column_number = name_column_number
      @has_parenthesis = has_parenthesis
    end

    def accept_children(visitor)
      obj.accept visitor if obj
      args.each { |arg| arg.accept visitor }
      block.accept visitor if block
    end

    def ==(other)
      other.class == self.class && other.obj == obj && other.name == name && other.args == args && other.block == block
    end

    def clone
      call = self.class.new obj ? obj.clone : nil, name, args.map(&:clone), block ? block.clone : nil
      call.location = location
      call
    end

    def name_column_number
      @name_column_number || column_number
    end
  end

  # An if expression.
  #
  #     'if' cond
  #       then
  #     [
  #     'else'
  #       else
  #     ]
  #     'end'
  #
  # An if elsif end is parsed as an If whose
  # else is another If.
  class If < ASTNode
    attr_accessor :cond
    attr_accessor :then
    attr_accessor :else

    def initialize(cond, a_then, a_else = nil)
      @cond = cond
      @cond.parent = self
      @then = Expressions.from a_then
      @then.parent = self
      @else = Expressions.from a_else
      @else.parent = self
    end

    def accept_children(visitor)
      self.cond.accept visitor
      self.then.accept visitor
      self.else.accept visitor if self.else
    end

    def ==(other)
      other.class == self.class && other.cond == cond && other.then == self.then && other.else == self.else
    end

    def clone
      a_if = self.class.new cond.clone, self.then.clone, self.else.clone
      a_if.location = location
      a_if
    end
  end

  # Assign expression.
  #
  #     target '=' value
  #
  class Assign < ASTNode
    attr_accessor :target
    attr_accessor :value

    def initialize(target, value)
      @target = target
      @target.parent = self
      @value = value
      @value.parent = self
    end

    def accept_children(visitor)
      target.accept visitor
      value.accept visitor
    end

    def ==(other)
      other.class == self.class && other.target == target && other.value == value
    end

    def clone
      assign = self.class.new target.clone, value.clone
      assign.location = location
      assign
    end
  end

  # While expression.
  #
  #     'while' cond
  #       body
  #     'end'
  #
  class While < ASTNode
    attr_accessor :cond
    attr_accessor :body

    def initialize(cond, body = nil)
      @cond = cond
      @cond.parent = self
      @body = Expressions.from body
      @body.parent = self
    end

    def accept_children(visitor)
      cond.accept visitor
      body.accept visitor
    end

    def ==(other)
      other.class == self.class && other.cond == cond && other.body == body
    end

    def clone
      a_while = self.class.new cond.clone, body.clone
      a_while.location = location
      a_while
    end
  end

  # A code block.
  #
  #     'do' [ '|' arg [ ',' arg ]* '|' ]
  #       body
  #     'end'
  #   |
  #     '{' [ '|' arg [ ',' arg ]* '|' ] body '}'
  #
  class Block < ASTNode
    attr_accessor :args
    attr_accessor :body

    def initialize(args = [], body = nil)
      @args = args
      @args.each { |arg| arg.parent = self } if @args
      @body = Expressions.from body
      @body.parent = self
    end

    def accept_children(visitor)
      args.each { |arg| arg.accept visitor }
      body.accept visitor
    end

    def ==(other)
      other.class == self.class && other.args == args && other.body == body
    end

    def clone
      block = self.class.new args.map(&:clone), body.clone
      block.location = location
      block
    end
  end

  ['return', 'break', 'next', 'yield'].each do |keyword|
    # A #{keyword} expression.
    #
    #     '#{keyword}' [ '(' ')' ]
    #   |
    #     '#{keyword}' '(' arg [ ',' arg ]* ')'
    #   |
    #     '#{keyword}' arg [ ',' arg ]*
    #
    class_eval %Q(
      class #{keyword.capitalize} < ASTNode
        attr_accessor :exps

        def initialize(exps = [])
          @exps = exps
          @exps.each { |exp| exp.parent = self }
        end

        def accept_children(visitor)
          exps.each { |e| e.accept visitor }
        end

        def ==(other)
          other.class == self.class && other.exps == exps
        end

        def clone
          ret = self.class.new exps.clone
          ret.location = location
          ret
        end
      end
    )
  end
end
