# frozen_string_literal: true

require 'prop_check/generator'
require 'prop_check/lazy_tree'

module PropCheck
  class StateMachine
    INVALID_REFERENCE = Object.new.freeze
    private_constant :INVALID_REFERENCE
    FILTER_ME = :"_PropCheck.filter_me"

    SymbolicHandle = Struct.new(:id) do
      def inspect
        "H#{id}"
      end

      def to_ruby
        inspect
      end
    end

    Invocation = Struct.new(:name, :args) do
      def inspect
        "#{name}(#{args.map(&:inspect).join(', ')})"
      end

      def to_ruby
        "#{name}(#{args.map { |arg| ruby_value(arg) }.join(', ')})"
      end

      private def ruby_value(value)
        return value.to_ruby if value.respond_to?(:to_ruby)
        return value.inspect if value.is_a?(Symbol) && value.to_s.start_with?('H')

        value.inspect
      end
    end

    Command = Struct.new(:name, :args_generator, :available, :precondition, :next_state,
                         :execute, :postcondition, :weight, keyword_init: true)

    GeneratedStep = Struct.new(:index, :command, :args_tree, keyword_init: true)

    def self.define(&block)
      DSL.new.tap { |dsl| dsl.instance_eval(&block) }.build
    end

    def initialize(initial_state:, setup:, teardown:, commands:)
      @initial_state = initial_state
      @setup = setup
      @teardown = teardown
      @commands = commands
      @generator = CommandSequenceGenerator.new(self)
      @property = PropCheck::Property.forall(@generator)
      freeze
    end

    attr_reader :initial_state, :setup, :teardown, :commands, :generator

    def command(name)
      @commands.find { |command| command.name == name } ||
        raise(ArgumentError, "Unknown state machine command #{name.inspect}")
    end

    def property
      @property
    end

    def with_config(**config)
      Check.new(self, property.with_config(**config))
    end

    def check(&block)
      with_config.check(&block)
    end

    def run(invocations)
      system = nil
      actual_handles = {}
      failure = nil
      state = @initial_state.call

      begin
        system = @setup.call
        invocations.each do |invocation|
          command = command(invocation.name)
          next unless command.available.call(state) && command.precondition.call(state, invocation.args)

          resolved_args = resolve_handles(invocation.args, actual_handles)
          result = call_with_args(command.execute, system, resolved_args)
          handle_index = actual_handles.length
          actual_handles[handle_index] = result
          state = command.next_state.call(state, resolved_args, SymbolicHandle.new(handle_index))
          call_postcondition(command, state, resolved_args, result)
        end
      rescue SignalException, SystemExit
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        failure = e
      ensure
        begin
          @teardown.call(system)
        rescue Exception => cleanup_error # rubocop:disable Lint/RescueException
          failure ||= cleanup_error
        end
      end

      raise failure if failure
    end

    def initial_model_state
      @initial_state.call
    end

    def precondition_holds?(command, state, args)
      command.precondition.call(state, args)
    end

    def command_available?(command, state)
      command.available.call(state)
    end

    def build_sequence_tree(steps, **kwargs)
      SequenceTreeBuilder.new(self).build(steps, **kwargs)
    end

    private def call_with_args(callback, system, args)
      return callback.call(system) if callback.arity == 1

      callback.call(system, args)
    end

    private def call_postcondition(command, state, args, result)
      return if command.postcondition.nil?

      case command.postcondition.arity
      when 0 then command.postcondition.call
      when 1 then command.postcondition.call(result)
      when 2 then command.postcondition.call(state, result)
      else command.postcondition.call(state, args, result)
      end
    end

    private def resolve_handles(value, actual_handles)
      case value
      when SymbolicHandle
        unless actual_handles.key?(value.id)
          raise Errors::UserError, "Command references unknown symbolic handle #{value.inspect}"
        end

        actual_handles.fetch(value.id)
      when Array
        value.map { |item| resolve_handles(item, actual_handles) }
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[resolve_handles(key, actual_handles)] = resolve_handles(item, actual_handles)
        end
      when Struct
        value.members.each_with_object(value.class.new) do |member, copy|
          copy[member] = resolve_handles(value[member], actual_handles)
        end
      else
        value
      end
    end

    class DSL
      def initialize
        @initial_state = proc {}
        @setup = proc { Object.new }
        @commands = []
        @teardown = proc { |_system| }
      end

      def initial_state(&block)
        @initial_state = block
      end

      def setup(&block)
        @setup = block
      end

      def teardown(&block)
        @teardown = block
      end

      def command(name, args: nil, available: nil, precondition: nil, next_state: nil, execute:,
                  postcondition: nil, weight: 1)
        raise ArgumentError, 'Command weight must be positive' unless weight.positive?
        raise ArgumentError, 'execute is required' if execute.nil?

        args_generator = args || proc { Generator.wrap([]) }
        available ||= proc { true }
        precondition ||= proc { true }
        next_state ||= proc { |state, _args, _result| state }

        @commands << Command.new(
          name: name,
          args_generator: args_generator,
          available: available,
          precondition: precondition,
          next_state: next_state,
          execute: execute,
          postcondition: postcondition,
          weight: weight
        )
      end

      def build
        raise ArgumentError, 'State machine has no commands' if @commands.empty?

        StateMachine.new(
          initial_state: @initial_state,
          setup: @setup,
          teardown: @teardown,
          commands: @commands
        )
      end
    end

    class Check
      def initialize(machine, property)
        @machine = machine
        @property = property
        freeze
      end

      def with_config(**config, &block)
        self.class.new(@machine, @property.with_config(**config)).check(&block)
      end

      def check(&block)
        @property.check do |invocations|
          @machine.run(invocations)
          block&.call(invocations)
        end
      end
    end

    class CommandSequenceGenerator < Generator
      def initialize(machine)
        @machine = machine
        super() { |**kwargs| generate_sequence(**kwargs) }
      end

      private def generate_sequence(**kwargs)
        state = @machine.initial_model_state
        steps = []
        length = PropCheck::Generators.choose(0..kwargs.fetch(:size)).generate(**kwargs).root

        length.times do |index|
          step = generate_step(state, index, **kwargs)
          break if step.nil?

          steps << step
          state = next_model_state(step.command, state, step.args_tree.root, step.index)
        end

        @machine.build_sequence_tree(steps, validate: false)
      end

      private def generate_step(state, index, **kwargs)
        available = available_commands(state)
        return nil if available.empty?

        kwargs.fetch(:max_consecutive_attempts).times do
          command = choose_weighted(available, kwargs.fetch(:rng))
          args_tree = args_generator(command, state, **kwargs)
          args = args_tree.root
          next if args == StateMachine::FILTER_ME
          next unless @machine.precondition_holds?(command, state, args)

          return GeneratedStep.new(index: index, command: command, args_tree: args_tree)
        end

        nil
      end

      private def available_commands(state)
        @machine.commands.select { |command| @machine.command_available?(command, state) }
      end

      private def choose_weighted(commands, rng)
        weighted = commands.flat_map { |command| [command] * command.weight }
        weighted.fetch(rng.rand(weighted.length))
      end

      private def args_generator(command, state, **kwargs)
        generator =
          if command.args_generator.is_a?(Proc)
            command.args_generator.call(state)
          else
            command.args_generator
          end

        generator.generate(**kwargs)
      end

      private def next_model_state(command, state, args, index)
        command.next_state.call(state, args, SymbolicHandle.new(index))
      end
    end

    class SequenceTreeBuilder
      def initialize(machine)
        @machine = machine
      end

      def build(steps, validate: true)
        normalized = normalize(steps)
        return LazyTree.wrap(StateMachine::FILTER_ME) if validate && normalized.nil?

        normalized ||= []
        root = normalized.map { |step| Invocation.new(step[:command].name, step[:args]) }
        LazyTree.new(root, children(steps))
      end

      private def children(steps)
        deletion_children = steps.each_with_index.lazy.map do |_, index|
          remaining = steps.reject.with_index { |_, other_index| other_index == index }
          build(remaining)
        end

        argument_children = steps.each_with_index.lazy.flat_map do |step, index|
          step.args_tree.children.lazy.map do |child_tree|
            replaced = steps.map.with_index do |other_step, other_index|
              next other_step unless index == other_index

              GeneratedStep.new(index: other_step.index, command: other_step.command, args_tree: child_tree)
            end
            build(replaced)
          end
        end

        PropCheck::Helper.lazy_append(deletion_children, argument_children)
      end

      private def normalize(steps)
        state = @machine.initial_model_state
        handle_map = {}
        normalized = []

        steps.each do |step|
          args = remap_handles(step.args_tree.root, handle_map)
          return nil if args == INVALID_REFERENCE
          return nil unless @machine.command_available?(step.command, state)
          return nil unless @machine.precondition_holds?(step.command, state, args)

          new_handle = SymbolicHandle.new(normalized.length)
          state = step.command.next_state.call(state, args, new_handle)
          normalized << { command: step.command, args: args }
          handle_map[step.index] = new_handle.id
        end

        normalized
      end

      private def remap_handles(value, handle_map)
        case value
        when SymbolicHandle
          return INVALID_REFERENCE unless handle_map.key?(value.id)

          SymbolicHandle.new(handle_map.fetch(value.id))
        when Array
          mapped = value.map { |item| remap_handles(item, handle_map) }
          mapped.include?(INVALID_REFERENCE) ? INVALID_REFERENCE : mapped
        when Hash
          value.each_with_object({}) do |(key, item), result|
            mapped_key = remap_handles(key, handle_map)
            mapped_item = remap_handles(item, handle_map)
            invalid = mapped_key == INVALID_REFERENCE || mapped_item == INVALID_REFERENCE
            return INVALID_REFERENCE if invalid

            result[mapped_key] = mapped_item
          end
        when Struct
          value.members.each_with_object(value.class.new) do |member, copy|
            member_value = remap_handles(value[member], handle_map)
            return INVALID_REFERENCE if member_value == INVALID_REFERENCE
            copy[member] = member_value
          end
        else
          value
        end
      end
    end
  end

  def state_machine(&block)
    StateMachine.define(&block)
  end
end
