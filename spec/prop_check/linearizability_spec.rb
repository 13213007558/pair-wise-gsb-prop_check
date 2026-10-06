RSpec.describe PropCheck::Linearizability do
  def queue_model
    lambda do |queue, operation|
      queue = (queue || []).dup
      case operation.name
      when :enqueue
        queue.push(operation.arguments.first)
        [queue, nil]
      when :dequeue
        [queue.drop(1), queue.first]
      else
        raise "unknown operation #{operation.name.inspect}"
      end
    end
  end

  def enqueue(id, value, call_time, return_time, thread: nil, pending: false)
    {
      id: id,
      name: :enqueue,
      arguments: [value],
      result: nil,
      call_time: call_time,
      return_time: pending ? nil : return_time,
      thread_id: thread,
      pending: pending
    }
  end

  def dequeue(id, result, call_time, return_time, thread: nil, pending: false)
    {
      id: id,
      name: :dequeue,
      arguments: [],
      result: result,
      call_time: call_time,
      return_time: pending ? nil : return_time,
      thread_id: thread,
      pending: pending
    }
  end

  it 'finds a legal order for duplicate values enqueued by concurrent operations' do
    history = [
      enqueue(:a, :x, 0, 3, thread: 1),
      enqueue(:b, :x, 1, 4, thread: 2),
      dequeue(:d1, :x, 2, 6, thread: 3),
      dequeue(:d2, :x, 5, 7, thread: 4)
    ]

    outcome = described_class.check(history, queue_model)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to contain_exactly(:a, :b, :d1, :d2)
    expect(outcome.witness.map(&:name)).to eq(%i[enqueue enqueue dequeue dequeue])
  end

  it 'reorders overlapping operations across threads while preserving real order' do
    history = [
      enqueue(:first, 1, 0, 4, thread: 1),
      enqueue(:second, 2, 1, 3, thread: 2),
      dequeue(:second_result, 2, 2, 5, thread: 3),
      dequeue(:first_result, 1, 6, 7, thread: 4)
    ]

    outcome = described_class.check(history, queue_model)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to eq(%i[second first second_result first_result])
  end

  it 'preserves non-overlapping operations and returns a replayable minimal counterexample' do
    register_model = lambda do |value, operation|
      operation.name == :write ? [operation.arguments.first, nil] : [value, value]
    end
    history = [
      {id: :write, name: :write, arguments: [2], result: nil, call_time: 0, return_time: 1, thread_id: 1},
      {id: :stale_read, name: :read, arguments: [], result: 1, call_time: 2, return_time: 3, thread_id: 2}
    ]

    outcome = described_class.check(history, register_model, initial_state: 1)

    expect(outcome).to be_nonlinearizable
    expect(outcome.small_history.map(&:id)).to contain_exactly(:write, :stale_read)
    replay = outcome.small_history.map(&:to_h)
    expect(described_class.check(replay, register_model, initial_state: 1)).to be_nonlinearizable
  end

  it 'finds a counterexample that becomes linearizable after removing the key operation' do
    register_model = lambda do |value, operation|
      operation.name == :write ? [operation.arguments.first, nil] : [value, value]
    end
    history = [
      {id: :key_write, name: :write, arguments: [2], result: nil, call_time: 0, return_time: 1, thread_id: 1},
      {id: :stale_read, name: :read, arguments: [], result: 1, call_time: 2, return_time: 3, thread_id: 2}
    ]

    outcome = described_class.check(history, register_model, initial_state: 1)
    without_key = history.reject { |operation| operation[:id] == :key_write }

    expect(outcome).to be_nonlinearizable
    expect(outcome.small_history.map(&:id)).to contain_exactly(:key_write, :stale_read)
    expect(described_class.check(without_key, register_model, initial_state: 1)).to be_linearizable
  end

  it 'raises a replayable small history when used as an assertion' do
    history = [
      enqueue(:first, 1, 0, 1),
      dequeue(:wrong, 2, 2, 3)
    ]

    expect do
      described_class.assert_linearizable!(history, queue_model)
    end.to raise_error(described_class::NonLinearizableError) do |error|
      rendered = PP.pp(error.small_history.map(&:to_h), +"")
      expect(error.small_history).to all(be_a(described_class::Operation))
      expect(rendered).to include(":wrong")
    end
  end

  it 'merges equivalent states supplied through a stable state key' do
    transitions = 0
    model = lambda do |state, operation|
      transitions += 1
      queue = state.fetch(:items).dup
      queue.push(operation.arguments.first) if operation.name == :enqueue
      [{items: queue, seen: operation.id}, queue.first]
    end
    state_key = ->(state) { state.fetch(:items) }
    history = [
      enqueue(:a, 1, 0, 5),
      enqueue(:b, 1, 1, 6),
      enqueue(:c, 1, 2, 7),
      dequeue(:wrong, 2, 7, 8)
    ]

    described_class.check(history, model, initial_state: {items: [], seen: nil}, state_key: state_key)

    expect(transitions).to eq(7)
  end

  it 'completes a pending operation when using the explicit completion policy' do
    history = [
      enqueue(:first, 1, 0, 2),
      dequeue(:pending_dequeue, 99, 3, nil, pending: true)
    ]

    outcome = described_class.check(history, queue_model, pending: :complete)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to eq(%i[first pending_dequeue])
  end

  it 'discards a pending operation when using the explicit discard policy' do
    history = [
      enqueue(:first, 1, 0, 2),
      dequeue(:ignored, 99, 3, nil, pending: true)
    ]

    outcome = described_class.check(history, queue_model, pending: :discard)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to eq([:first])
    expect(outcome.discarded_operations.map(&:id)).to eq([:ignored])
  end

  it 'reports undetermined rather than non-linearizable when the search budget is reached' do
    history = [
      enqueue(:first, 1, 0, 1),
      dequeue(:wrong, 2, 2, 3)
    ]

    outcome = described_class.check(history, queue_model, budget: 0, minimize: false)

    expect(outcome).to be_undetermined
    expect(outcome).not_to be_nonlinearizable
    expect(outcome.attempts).to eq(0)
    expect do
      described_class.assert_linearizable!(history, queue_model, budget: 0, minimize: false)
    end.to raise_error(described_class::UndeterminedError, /undetermined, not non-linearizable/)
  end

  it 'does not mark an unfinished budgeted state as a permanently impossible state' do
    history = [
      enqueue(:a, 1, 0, 1),
      enqueue(:b, 2, 2, 3),
      dequeue(:wrong_a, 2, 4, 5),
      dequeue(:wrong_b, 2, 6, 7)
    ]

    expect(described_class.check(history, queue_model, budget: 2, minimize: false)).to be_undetermined
    expect(described_class.check(history, queue_model, budget: 100)).to be_nonlinearizable
  end

  it 'treats a return at the next operation call boundary as non-overlapping' do
    history = [
      enqueue(:first, 1, 0, 1),
      dequeue(:wrong, 2, 1, 2)
    ]

    expect(described_class.check(history, queue_model)).to be_nonlinearizable
  end

  it 'rejects unknown pending policies and invalid call/return boundaries' do
    expect { described_class.check([], queue_model, pending: :maybe) }
      .to raise_error(ArgumentError, /unknown pending policy/)
    expect do
      described_class.check([enqueue(:bad, 1, 0, -1)], queue_model)
    end.to raise_error(PropCheck::Errors::UserError, /returns before it was called/)
    expect do
      described_class.check([{arguments: [], call_time: 0, return_time: 1}], queue_model)
    end.to raise_error(PropCheck::Errors::UserError, /requires a name/)
  end

  it 'accepts an empty history and returns an empty witness' do
    outcome = described_class.check([], queue_model)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to eq([])
  end

  it 'accepts Operation records, heterogeneous ids and common field aliases' do
    history = [
      described_class::Operation.new(0, 0, :enqueue, [1], nil, 0, 2, 1, false),
      {op: :dequeue, args: [], returns: 1, call: 1, return: 3, thread: 2}
    ]

    outcome = described_class.linearize(history, queue_model)

    expect(outcome).to be_linearizable
    expect(outcome.witness_ids).to eq([0, 1])
  end

  it 'rejects stable state keys that cannot be used in a hash' do
    history = [enqueue(:a, 1, 0, 1)]

    expect do
      described_class.check(history, queue_model, state_key: ->(_state) { BasicObject.new })
    end.to raise_error(PropCheck::Errors::UserError, /hashable, stable key/)
  end

  it 'rejects pending records that contain a return boundary' do
    history = [{id: :a, name: :enqueue, arguments: [1], result: nil,
                call_time: 0, return_time: 2, pending: true}]

    expect do
      described_class.check(history, queue_model)
    end.to raise_error(PropCheck::Errors::UserError, /pending operation.*must not have a return time/)
  end
end
