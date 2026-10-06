# frozen_string_literal: true

RSpec.describe PropCheck::StateMachine do
  class BuggyHandleStore
    attr_reader :closed

    def initialize(recorder)
      @recorder = recorder
      @handles = {}
      @next_id = 0
      @closed = false
      @recorder.created << object_id
    end

    def create
      id = @next_id
      @next_id += 1
      @handles[id] = :live
      id
    end

    def delete(id)
      @handles[id] = :deleted
      :deleted
    end

    def get(id)
      return :found if @handles.key?(id)

      :not_found
    end

    def close
      return if @closed

      @closed = true
      @recorder.closed << object_id
    end
  end

  Recorder = Struct.new(:created, :closed, keyword_init: true)

  let(:machine) do
    recorder = self.recorder
    handle_choice = ->(state) do
      handles = state[:live] + state[:deleted]
      PropCheck::Generators.one_of(*handles.map { |handle| PropCheck::Generators.constant(handle) })
                              .map { |handle| [handle] }
    end

    PropCheck.state_machine do
      initial_state { { live: [], deleted: [] } }
      setup { BuggyHandleStore.new(recorder) }
      teardown(&:close)

      command(
        :create,
        next_state: ->(state, _args, handle) do
          state.merge(live: state[:live] + [handle])
        end,
        execute: ->(store) { store.create }
      )

      command(
        :delete,
        args: ->(state) do
          PropCheck::Generators.one_of(
            *state[:live].map { |handle| PropCheck::Generators.constant(handle) }
          )
          .map { |handle| [handle] }
        end,
        available: ->(state) { !state[:live].empty? },
        precondition: ->(state, args) { state[:live].include?(args.fetch(0)) },
        next_state: ->(state, args, _result) do
          handle = args.fetch(0)
          state.merge(
            live: state[:live] - [handle],
            deleted: state[:deleted] + [handle]
          )
        end,
        execute: ->(store, args) { store.delete(args.fetch(0)) }
      )

      command(
        :get,
        args: handle_choice,
        available: ->(state) { !(state[:live] + state[:deleted]).empty? },
        precondition: ->(state, args) do
          (state[:live] + state[:deleted]).include?(args.fetch(0))
        end,
        execute: ->(store, args) { store.get(args.fetch(0)) },
        postcondition: ->(state, args, result) do
          handle = args.fetch(0)
          raise 'deleted handle was still found' if state[:deleted].include?(handle) && result == :found
        end
      )
    end
  end

  let(:recorder) { Recorder.new(created: [], closed: []) }

  it 'shrinks to create, delete, and use of the same symbolic handle' do
    error = nil

    expect do
      machine.with_config(n_runs: 100).check
    end.to raise_error do |raised|
      error = raised
    end

    expect(error).to be_a(RuntimeError)
    expect(error.message).to include('deleted handle was still found')

    shrunken = error.prop_check_info.fetch(:shrunken_input)
    expect(shrunken.map(&:name)).to eq(%i[create delete get])
    expect(shrunken.map(&:args)).to eq([[], [h(0)], [h(0)]])
    expect { machine.run(shrunken) }.to raise_error('deleted handle was still found')
  end

  it 'uses a fresh system and always runs teardown while shrinking' do
    expect do
      machine.with_config(n_runs: 100).check
    end.to raise_error(RuntimeError)

    expect(recorder.created.size).to eq(recorder.closed.size)
    expect(recorder.created).not_to be_empty
  end

  it 'removes commands whose references or preconditions become invalid while shrinking' do
    create = machine.command(:create)
    delete = machine.command(:delete)
    handle0 = described_class::SymbolicHandle.new(0)
    handle1 = described_class::SymbolicHandle.new(1)
    empty_tree = PropCheck::LazyTree.new([])
    handle_tree = PropCheck::LazyTree.new([handle0])
    dangling_tree = PropCheck::LazyTree.new([handle1])

    create_step = described_class::GeneratedStep.new(
      index: 0, command: create, args_tree: empty_tree
    )
    delete_step = described_class::GeneratedStep.new(
      index: 1, command: delete, args_tree: handle_tree
    )
    dangling_delete_step = described_class::GeneratedStep.new(
      index: 2, command: delete, args_tree: dangling_tree
    )

    tree = machine.build_sequence_tree(
      [create_step, delete_step, dangling_delete_step],
      validate: false
    )

    deletion_roots = tree.children.first(3).map(&:root)

    expect(deletion_roots).to include(
      [
        described_class::Invocation.new(:create, []),
        described_class::Invocation.new(:delete, [described_class::SymbolicHandle.new(0)])
      ]
    )
    expect(deletion_roots).not_to include(an_object_satisfying do |commands|
      commands.any? { |command| command.args.include?(handle1) }
    end)

    invalid_delete = machine.build_sequence_tree([delete_step], validate: true)
    expect(invalid_delete.root).to eq(:"_PropCheck.filter_me")
  end

  it 'shrinks arguments but filters candidates that no longer satisfy preconditions' do
    simple_machine = PropCheck.state_machine do
      command(
        :use,
        precondition: ->(_state, args) { args.fetch(0).positive? },
        execute: ->(_system, args) { args.fetch(0) }
      )
    end

    args_tree = PropCheck::LazyTree.new(
      [10],
      [PropCheck::LazyTree.new([0]), PropCheck::LazyTree.new([5])].lazy
    )
    step = described_class::GeneratedStep.new(
      index: 0, command: simple_machine.command(:use), args_tree: args_tree
    )

    tree = simple_machine.build_sequence_tree([step], validate: false)

    expect(tree.children.first(2).map(&:root)).to eq([
      [],
      [described_class::Invocation.new(:use, [5])]
    ])
  end

  it 'does not execute a failed precondition as a product failure' do
    guarded_machine = PropCheck.state_machine do
      command(
        :use,
        precondition: ->(_state, args) { args.fetch(0) > 10 },
        execute: ->(_system, args) { raise 'must not execute' if args.fetch(0) <= 10 }
      )
    end
    invalid_use = [
      described_class::Invocation.new(:use, [0])
    ]

    expect { guarded_machine.run(invalid_use) }.not_to raise_error
  end

  it 'runs teardown even when a command raises' do
    lifecycle = []
    failing_machine = PropCheck.state_machine do
      setup { lifecycle << :setup; Object.new }
      teardown { |_system| lifecycle << :teardown }
      command(
        :fail,
        execute: ->(_system) { raise 'boom' }
      )
    end

    expect { failing_machine.run([described_class::Invocation.new(:fail, [])]) }
      .to raise_error('boom')
    expect(lifecycle).to eq(%i[setup teardown])
  end

  it 'preserves configuration through chained calls' do
    machine = PropCheck.state_machine do
      command(:noop, execute: ->(_system) { true })
    end

    check = machine.with_config(n_runs: 1)

    expect(check.instance_variable_get(:@property).configuration.n_runs).to eq(1)
    expect { check.check }.not_to raise_error
  end

  it 'runs teardown with nil when setup raises' do
    lifecycle = []
    failing_machine = PropCheck.state_machine do
      setup { raise 'setup failed' }
      teardown { |_system| lifecycle << :teardown }
      command(:noop, execute: ->(_system) { true })
    end

    expect { failing_machine.run([]) }.to raise_error('setup failed')
    expect(lifecycle).to eq([:teardown])
  end

  it 'still runs teardown when SystemExit is raised' do
    lifecycle = []
    exiting_machine = PropCheck.state_machine do
      setup { lifecycle << :setup; Object.new }
      teardown { |_system| lifecycle << :teardown }
      command(:exit, execute: ->(_system) { raise SystemExit })
    end

    expect do
      exiting_machine.run([described_class::Invocation.new(:exit, [])])
    end.to raise_error(SystemExit)
    expect(lifecycle).to eq(%i[setup teardown])
  end

  private def h(id)
    PropCheck::StateMachine::SymbolicHandle.new(id)
  end
end
