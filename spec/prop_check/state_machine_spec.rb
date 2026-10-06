require 'spec_helper'

RSpec.describe PropCheck::StateMachine do
  class DeletedHandleError < StandardError; end

  class BrokenMemory
    def initialize
      @entries = {}
      @next_id = 0
      @closed = false
    end

    attr_reader :closed

    def create(value)
      raise 'memory closed' if @closed

      id = @next_id
      @entries[id] = value
      @next_id += 1
      id
    end

    def delete(handle)
      raise 'memory closed' if @closed

      @entries.key?(handle)
    end

    def read(handle)
      raise 'memory closed' if @closed

      @entries.fetch(handle) { raise DeletedHandleError, 'handle was deleted' }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class CorrectMemory < BrokenMemory
    def delete(handle)
      @entries.delete(handle)
    end
  end

  class PlainDeleteCommand
    def initialize(handle)
      @handle = handle
    end

    attr_reader :handle

    def execute(memory)
      memory.delete(@handle)
    end

    def postcondition?(execution)
      execution.result.is_a?(Integer)
    end
  end

  class CreateCommand < Struct.new(:value)
    G = PropCheck::Generators

    def self.generator(_model)
      G.choose(0..2).map { |value| new(value) }
    end

    def self.produces_handle?(_command)
      true
    end

    def self.next_state(model, _command, handle)
      model.merge(
        alive: model[:alive] + [handle],
        handles: model[:handles] + [handle]
      )
    end

    def execute(memory)
      memory.create(value)
    end

    def postcondition?(execution)
      execution.returned_handle.is_a?(PropCheck::StateMachine::SymbolicHandle) &&
        execution.result.is_a?(Integer)
    end

    def inspect
      "create(#{value.inspect})"
    end
  end

  class DeleteCommand < Struct.new(:handle)
    G = PropCheck::Generators

    def self.generator(model)
      return nil if model[:alive].empty?

      G.choose(0...model[:alive].length).map do |index|
        new(model[:alive][index])
      end
    end

    def self.precondition?(model, command)
      model[:alive].include?(command.handle)
    end

    def self.next_state(model, command, _handle = nil)
      model.merge(alive: model[:alive].reject { |handle| handle == command.handle })
    end

    def execute(memory)
      memory.delete(handle)
    end

    def inspect
      "delete(#{handle.inspect})"
    end
  end

  class ReadCommand < Struct.new(:handle)
    G = PropCheck::Generators

    def self.generator(model)
      return nil if model[:handles].empty?

      G.choose(0...model[:handles].length).map do |index|
        new(model[:handles][index])
      end
    end

    def self.precondition?(model, command)
      model[:handles].include?(command.handle)
    end

    def execute(memory)
      begin
        memory.read(handle)
      rescue DeletedHandleError => error
        error
      end
    end

    def postcondition?(execution)
      deleted = !execution.model_after[:alive].include?(execution.symbolic_handle_for(handle))
      deleted == execution.result.is_a?(DeletedHandleError)
    end

    def inspect
      "read(#{handle.inspect})"
    end
  end

  let(:initial_model) do
    { alive: [], handles: [] }
  end

  let(:commands) do
    [CreateCommand, DeleteCommand, ReadCommand]
  end

  let(:state_machine) do
    PropCheck::StateMachine.define(
      initial_state: initial_model,
      setup: proc { BrokenMemory.new },
      cleanup: proc(&:close),
      commands: commands
    )
  end

  it 'passes when the memory correctly rejects deleted handles' do
    PropCheck.forall_commands(
      initial_state: initial_model,
      setup: proc { CorrectMemory.new },
      cleanup: proc(&:close),
      commands: commands
    )
  end

  it 'shrinks to a valid create-delete-read sequence' do
    shrunken_sequence = nil

    expect do
      PropCheck.forall(state_machine.generator).with_config(n_runs: 200) do |sequence|
        state_machine.run(sequence)
      end
    end.to raise_error(PropCheck::StateMachine::PostconditionError) do |error|
      shrunken_sequence = error.prop_check_info[:shrunken_input]
    end

    symbolic_handle = PropCheck::StateMachine::SymbolicHandle.new(0)
    expect(shrunken_sequence.length).to eq(3)
    expect(shrunken_sequence.map(&:class)).to eq([CreateCommand, DeleteCommand, ReadCommand])
    expect(shrunken_sequence[1].handle).to eq(symbolic_handle)
    expect(shrunken_sequence[2].handle).to eq(symbolic_handle)
    expect(shrunken_sequence.inspect).to eq('[create(0), delete(h0), read(h0)]')
    expect { state_machine.run(shrunken_sequence) }.to raise_error(
      PropCheck::StateMachine::PostconditionError
    )
  end

  it 'runs cleanup on a fresh instance even when a command fails' do
    closed = []
    definition = PropCheck::StateMachine.define(
      initial_state: initial_model,
      setup: proc { BrokenMemory.new },
      cleanup: proc { |memory| memory.close; closed << memory },
      commands: commands
    )

    expect do
      PropCheck.forall(definition.generator).with_config(n_runs: 50) do |sequence|
        definition.run(sequence)
      end
    end.to raise_error(PropCheck::StateMachine::PostconditionError)

    expect(closed).not_to be_empty
    expect(closed).to all(be_closed)
  end

  it 'replaces symbolic handles inside ordinary command objects' do
    definition = PropCheck::StateMachine.define(
      initial_state: initial_model,
      setup: proc { BrokenMemory.new },
      cleanup: proc(&:close),
      commands: commands
    )
    memory = CorrectMemory.new
    real_handle = memory.create(9)
    command = PlainDeleteCommand.new(PropCheck::StateMachine::SymbolicHandle.new(0))
    tree = PropCheck::LazyTree.new(command)
    step = PropCheck::StateMachine::Step.new(
      command, tree, nil, initial_model, initial_model
    )

    definition.send(:run_step, memory, step, PropCheck::StateMachine::SymbolicHandle.new(0) => real_handle)
    expect { memory.read(real_handle) }.to raise_error(DeletedHandleError)
    memory.close
  end

  it 'discards a shrunken parameter that references a missing handle' do
    create = CreateCommand.new(0)
    create_tree = PropCheck::LazyTree.new(create)
    create_step = PropCheck::StateMachine::Step.new(
      create,
      create_tree,
      PropCheck::StateMachine::SymbolicHandle.new(0),
      initial_model,
      { alive: [PropCheck::StateMachine::SymbolicHandle.new(0)],
        handles: [PropCheck::StateMachine::SymbolicHandle.new(0)] }
    )
    delete = DeleteCommand.new(PropCheck::StateMachine::SymbolicHandle.new(0))
    delete_step = PropCheck::StateMachine::Step.new(
      delete,
      PropCheck::LazyTree.new(delete),
      nil,
      create_step.after_model,
      initial_model
    )
    invalid_child = PropCheck::LazyTree.new(
      DeleteCommand.new(PropCheck::StateMachine::SymbolicHandle.new(9))
    )

    candidate = state_machine.send(
      :parameter_candidate,
      [create_step, delete_step],
      1,
      invalid_child,
      [create_step]
    )

    expect(candidate).to be_nil
  end

  it 'skips commands whose precondition becomes false during replay' do
    handle = PropCheck::StateMachine::SymbolicHandle.new(0)
    create = CreateCommand.new(0)
    delete = DeleteCommand.new(handle)
    delete_again = DeleteCommand.new(handle)
    after_create = { alive: [handle], handles: [handle] }
    after_delete = { alive: [], handles: [handle] }

    create_step = PropCheck::StateMachine::Step.new(
      create, PropCheck::LazyTree.new(create), handle, initial_model, after_create
    )
    delete_step = PropCheck::StateMachine::Step.new(
      delete, PropCheck::LazyTree.new(delete), nil, after_create, after_delete
    )
    invalid_step = PropCheck::StateMachine::Step.new(
      delete_again, PropCheck::LazyTree.new(delete_again), nil, after_delete, after_delete
    )

    sequence = state_machine.send(:simulate, [create_step, delete_step, invalid_step])

    expect(sequence.to_a).to eq([create, delete])
  end
end
