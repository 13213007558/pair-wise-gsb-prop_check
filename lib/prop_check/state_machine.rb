# frozen_string_literal: true

module PropCheck
  module StateMachine
    MISSING_HANDLE = Object.new.freeze
    private_constant :MISSING_HANDLE

    SymbolicHandle = Struct.new(:id) do
      def inspect
        "h#{id}"
      end

      alias to_s inspect
    end

    Execution = Struct.new(:system, :command, :result, :model_before, :model_after,
                           :handles, :returned_handle, keyword_init: true) do
      def symbolic_handle_for(actual_handle)
        handles.key(actual_handle)
      end
    end

    class PostconditionError < PropCheck::Errors::Error; end

    class Sequence < Array
      def initialize(commands, steps: commands)
        super(commands)
        @steps = steps
      end

      attr_reader :steps

      def inspect
        to_a.inspect
      end

      alias to_s inspect
    end

    Step = Struct.new(:command, :tree, :handle, :before_model, :after_model)

    class Command
      def self.generator(_model)
        raise NotImplementedError, "#{self}.#{__method__} is not implemented."
      end

      def self.produces_handle?(_command)
        false
      end

      def self.precondition?(_model, _command)
        true
      end

      def self.next_state(model, _command, _handle = nil)
        model
      end

      def execute(_system)
        raise NotImplementedError, "#{self.class}#execute is not implemented."
      end

      def postcondition?(_execution)
        true
      end
    end

    class Definition
      include PropCheck::Generators

      def initialize(initial_state:, setup:, cleanup:, commands:)
        @initial_state = initial_state
        @setup = setup
        @cleanup = cleanup
        @commands = commands
      end

      attr_reader :initial_state, :setup, :cleanup, :commands

      def generator
        Generator.new do |**kwargs|
          steps = generate_steps(**kwargs)
          build_tree(steps)
        end
      end

      def run(sequence)
        system = @setup.call
        actual_handles = {}

        begin
          sequence.steps.each do |step|
            run_step(system, step, actual_handles)
          end
        ensure
          @cleanup.call(system)
        end
      end

      private

      def initial_model
        if @initial_state.respond_to?(:call)
          @initial_state.call
        else
          @initial_state
        end
      end

      def generate_steps(**kwargs)
        model = initial_model
        count = nonnegative_integer.generate(**kwargs).root
        steps = []

        count.times do
          step = generate_step(model, steps, **kwargs)
          break if step.nil?

          steps << step
          model = step.after_model
        end

        steps
      end

      def generate_step(model, previous_steps, **kwargs)
        choices = available_choices(model)
        return nil if choices.empty?

        attempts = kwargs.fetch(:max_consecutive_attempts, 30)
        attempts.times do
          klass, command_generator = choices.sample(random: kwargs.fetch(:rng, Random.new))
          tree = command_generator.generate(**kwargs)
          command = tree.root
          command_class = command.class

          next unless precondition_satisfied?(command_class, model, command)

          handle = new_handle(previous_steps) if produces_handle?(command_class, command)
          next_model = next_model_state(command_class, model, command, handle)
          return Step.new(command, tree, handle, model, next_model)
        end

        nil
      end

      def available_choices(model)
        @commands.each_with_object([]) do |klass, choices|
          command_generator = klass.generator(model)
          choices << [klass, command_generator] unless command_generator.nil?
        end
      end

      def new_handle(steps, offset = 0)
        id = steps.count { |step| step.handle }
        SymbolicHandle.new(id + offset)
      end

      def build_tree(steps)
        root = Sequence.new(steps.map(&:command), steps: steps)
        children = tree_children(steps).map { |child_steps| build_tree(child_steps) }
        LazyTree.new(root, children)
      end

      def tree_children(steps)
        Helper.lazy_append(deletion_children(steps), parameter_children(steps))
      end

      def deletion_children(steps)
        steps.each_with_index.lazy.flat_map do |_, index|
          remaining = steps.each_with_index.reject { |_, candidate_index|
            candidate_index == index
          }.map(&:first)
          candidate = simulate(remaining).steps
          same_commands?(steps, candidate) ? [] : [candidate]
        end
      end

      def parameter_children(steps)
        steps.each_with_index.lazy.flat_map do |step, index|
          prefix_steps = simulate(steps[0...index]).steps
          step.tree.children.lazy.flat_map do |child_tree|
            candidate = parameter_candidate(steps, index, child_tree, prefix_steps)
            candidate.nil? ? [] : [candidate]
          end
        end
      end

      def parameter_candidate(steps, index, child_tree, prefix_steps)
        mapping = handle_mapping(prefix_steps)
        command = replace_handles(child_tree.root, mapping)
        return if command.equal?(MISSING_HANDLE)

        model = prefix_steps.last ? prefix_steps.last.after_model : initial_model
        return unless precondition_satisfied?(command.class, model, command)

        old_step = steps[index]
        handle = nil
        if produces_handle?(command.class, command)
          handle = new_handle(prefix_steps)
          mapping[old_step.handle] = handle if old_step.handle
        end

        next_model = next_model_state(command.class, model, command, handle)
        candidate_step = Step.new(command, child_tree, handle, model, next_model)
        suffix_steps = simulate(steps[(index + 1)..-1] || [], mapping, next_model,
                                []).steps
        candidate = prefix_steps + [candidate_step] + suffix_steps
        return if same_commands?(steps, candidate)

        candidate
      end

      def simulate(steps, mapping = {}, model = initial_model, accepted = [])
        steps.each do |step|
          handle = nil
          if step.handle
            handle = new_handle(accepted)
            mapping[step.handle] = handle
          end

          command = replace_handles(step.command, mapping)
          next if command.equal?(MISSING_HANDLE)
          next unless precondition_satisfied?(command.class, model, command)

          next_model = next_model_state(command.class, model, command, handle)
          accepted << Step.new(command, step.tree, handle, model, next_model)
          model = next_model
        end

        Sequence.new(accepted.map(&:command), steps: accepted)
      end

      def handle_mapping(steps)
        steps.each_with_object({}) do |step, mapping|
          mapping[step.handle] = step.handle if step.handle
        end
      end

      def same_commands?(steps, candidate)
        steps.map(&:command) == candidate.to_a
      end

      def precondition_satisfied?(klass, model, command)
        return Command.precondition?(model, command) unless klass.respond_to?(:precondition?)

        klass.precondition?(model, command)
      end

      def produces_handle?(klass, command)
        return false unless klass.respond_to?(:produces_handle?)

        klass.produces_handle?(command)
      end

      def next_model_state(klass, model, command, handle)
        return Command.next_state(model, command, handle) unless klass.respond_to?(:next_state)

        klass.next_state(model, command, handle)
      end

      def replace_handles(value, mapping)
        case value
        when SymbolicHandle
          mapping.fetch(value, MISSING_HANDLE)
        when Array
          replace_array(value, mapping)
        when Hash
          replace_hash(value, mapping)
        when Struct
          replace_struct(value, mapping)
        else
          replace_object(value, mapping)
        end
      end

      def replace_array(value, mapping)
        value.map do |element|
          replaced = replace_handles(element, mapping)
          return MISSING_HANDLE if replaced.equal?(MISSING_HANDLE)

          replaced
        end
      end

      def replace_hash(value, mapping)
        value.each_with_object({}) do |(key, element), result|
          replaced_key = replace_handles(key, mapping)
          replaced_value = replace_handles(element, mapping)
          return MISSING_HANDLE if replaced_key.equal?(MISSING_HANDLE) || replaced_value.equal?(MISSING_HANDLE)

          result[replaced_key] = replaced_value
        end
      end

      def replace_struct(value, mapping)
        members = value.members.map do |member|
          replaced = replace_handles(value.public_send(member), mapping)
          return MISSING_HANDLE if replaced.equal?(MISSING_HANDLE)

          replaced
        end

        value.class.new(*members)
      end

      def replace_object(value, mapping)
        return value if value.instance_variables.empty?

        copy = begin
          value.dup
        rescue TypeError
          return value
        end

        value.instance_variables.each do |name|
          replaced = replace_handles(value.instance_variable_get(name), mapping)
          return MISSING_HANDLE if replaced.equal?(MISSING_HANDLE)

          copy.instance_variable_set(name, replaced)
        end

        copy
      end

      def run_step(system, step, actual_handles)
        command = replace_handles(step.command, actual_handles)
        result = command.execute(system)
        actual_handles[step.handle] = result if step.handle

        execution = Execution.new(
          system: system,
          command: command,
          result: result,
          model_before: step.before_model,
          model_after: step.after_model,
          handles: actual_handles,
          returned_handle: step.handle
        )

        return unless command.respond_to?(:postcondition?)
        return if command.postcondition?(execution)

        raise PostconditionError, "Postcondition failed for command #{command.inspect} (#{result.inspect})."
      end
    end

    module_function

    def define(initial_state:, setup:, cleanup:, commands:)
      Definition.new(
        initial_state: initial_state,
        setup: setup,
        cleanup: cleanup,
        commands: commands
      )
    end
  end

  def forall_commands(initial_state:, setup:, cleanup:, commands:, &block)
    definition = StateMachine.define(
      initial_state: initial_state,
      setup: setup,
      cleanup: cleanup,
      commands: commands
    )

    PropCheck.forall(definition.generator) do |sequence|
      block.call(sequence) if block
      definition.run(sequence)
    end
  end
end
