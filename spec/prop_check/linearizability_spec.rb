# frozen_string_literal: true

require 'prop_check'

RSpec.describe PropCheck::Linearizability do
  include PropCheck::Generators

  subject(:check!) { described_class.check(history, initial_state: [], **options, &queue_step) }

  let(:options) { {} }

  let(:queue_step) do
    lambda do |queue, op|
      case op.function
      when :enq then queue + [op.arguments]
      when :deq
        next described_class.REJECT if queue.empty?

        op.result == queue.first ? queue.drop(1) : described_class.REJECT
      end
    end
  end

  describe '.check' do
    context 'with a legal history' do
      let(:history) do
        [
          [:invoke, 1, :enq, 0], [:ok, 1, :enq],
          [:invoke, 2, :enq, 1], [:ok, 2, :enq],
          [:invoke, 3, :deq], [:ok, 3, :deq, 0],
          [:invoke, 4, :deq], [:ok, 4, :deq, 1]
        ]
      end

      it 'is linearizable and returns the sequential witness' do
        result = check!
        expect(result).to be_linearizable
        expect(result.witness.map(&:function)).to eq(%i[enq enq deq deq])
      end

      it 'replays the witness against the model with the same results' do
        result = check!
        state = []
        result.witness.each do |op|
          state = queue_step.call(state, op)
          expect(state).not_to eq(PropCheck::Linearizability::REJECT)
        end
      end
    end

    context 'with same-value duplicate enqueues' do
      let(:history) do
        [
          [:invoke, 1, :enq, 7], [:invoke, 2, :enq, 7],
          [:ok, 1, :enq], [:ok, 2, :enq],
          [:invoke, 3, :deq], [:ok, 3, :deq, 7],
          [:invoke, 4, :deq], [:ok, 4, :deq, 7]
        ]
      end

      it 'keeps the duplicate values distinct by operation identity' do
        expect(check!).to be_linearizable
      end

      it 'still rejects when one of the duplicate results is wrong' do
        bad = history.dup
        bad[-1] = [:ok, 4, :deq, 8]
        result = described_class.check(bad, initial_state: [], &queue_step)
        expect(result).to be_non_linearizable
      end
    end

    context 'with operations interleaved across threads' do
      it 'reorders fully overlapping operations to find a legal order' do
        history = [
          [:invoke, 1, :enq, 0], [:invoke, 2, :enq, 1],
          [:ok, 2, :enq], [:ok, 1, :enq],
          [:invoke, 3, :deq], [:invoke, 4, :deq],
          [:ok, 3, :deq, 0], [:ok, 4, :deq, 1]
        ]
        expect(described_class.check(history, initial_state: [], &queue_step))
          .to be_linearizable
      end

      it 'preserves the real-time order of non-overlapping operations' do
        # Thread 1 enqueues 5 and dequeues 5 before thread 2 ever starts;
        # thread 2 then dequeues 5 from an empty queue, which is impossible.
        history = [
          [:invoke, 1, :enq, 5], [:ok, 1, :enq],
          [:invoke, 1, :deq], [:ok, 1, :deq, 5],
          [:invoke, 2, :deq], [:ok, 2, :deq, 5]
        ]
        result = described_class.check(history, initial_state: [], &queue_step)
        expect(result).to be_non_linearizable
      end
    end

    context 'with a non-linearizable history' do
      let(:history) do
        [
          [:invoke, 1, :enq, 0], [:ok, 1, :enq],
          [:invoke, 2, :deq], [:invoke, 3, :deq],
          [:ok, 2, :deq, 0], [:ok, 3, :deq, 0]
        ]
      end

      it 'is non-linearizable' do
        expect(check!).to be_non_linearizable
      end

      it 'returns a replayable small failing history' do
        minimal = check!.history
        expect(minimal).to eq([
                                [:invoke, 3, :deq, nil], [:ok, 3, :deq, 0]
                              ])
        replayed = described_class.check(minimal, initial_state: [],
                                                   minimize: false, &queue_step)
        expect(replayed).to be_non_linearizable
      end

      it 'becomes linearizable after the key offending operation is removed' do
        # Removing one of the duplicate consumers leaves a legal history.
        repaired = history.reject { |entry| entry[1] == 3 }
        expect(described_class.check(repaired, initial_state: [], &queue_step))
          .to be_linearizable
      end
    end

    context 'with the search budget exhausted' do
      it 'returns undecided instead of non-linearizable on a zero budget' do
        history = [
          [:invoke, 1, :enq, 0], [:ok, 1, :enq],
          [:invoke, 2, :deq], [:ok, 2, :deq, 1]
        ]
        result = described_class.check(history, initial_state: [],
                                              budget: 0, &queue_step)
        expect(result).to be_undecided
      end

      it 'returns undecided when the budget runs out mid-search' do
        history = [[:invoke, 0, :enq, 0], [:ok, 0, :enq]]
        60.times do |i|
          history << [:invoke, 100 + i, :deq]
        end
        60.times do |i|
          history << [:ok, 100 + i, :deq, i.zero? ? 0 : 1]
        end

        result = described_class.check(history, initial_state: [],
                                              budget: 50, minimize: false,
                                              &queue_step)
        expect(result).to be_undecided
      end
    end

    context 'with unreturned operations' do
      let(:history) { [[:invoke, 1, :enq, 9]] }

      it 'raises without an explicit pending policy' do
        expect { described_class.check(history, initial_state: [], &queue_step) }
          .to raise_error(ArgumentError, /unreturned operations/)
      end

      it 'rejects unknown pending policies' do
        expect do
          described_class.check(history, initial_state: [],
                                        pending_policy: :nope, &queue_step)
        end.to raise_error(ArgumentError, /unknown pending_policy/)
      end

      it 'discards pending operations with pending_policy :discard' do
        result = described_class.check(history, initial_state: [],
                                               pending_policy: :discard, &queue_step)
        expect(result).to be_linearizable
        expect(result.witness).to eq([])
      end

      it 'completes pending operations with pending_policy :complete' do
        result = described_class.check(history, initial_state: [],
                                               pending_policy: :complete, &queue_step)
        expect(result).to be_linearizable
        expect(result.witness.map(&:function)).to eq([:enq])
      end

      it 'lets the model reject a pending completion' do
        dequeue = [[:invoke, 1, :deq]]
        strict_step = lambda do |queue, op|
          next described_class.REJECT if op.pending?

          queue_step.call(queue, op)
        end
        result = described_class.check(dequeue, initial_state: [],
                                                pending_policy: :complete, &strict_step)
        expect(result).to be_non_linearizable
      end
    end

    context 'with failed and info entries' do
      it 'removes known failures before searching' do
        history = [
          [:invoke, 1, :deq], [:fail, 1, :deq, :empty],
          [:invoke, 2, :enq, 1], [:ok, 2, :enq],
          [:invoke, 3, :deq], [:ok, 3, :deq, 1]
        ]
        expect(described_class.check(history, initial_state: [], &queue_step))
          .to be_linearizable
      end
    end

    context 'with hash-shaped entries' do
      it 'accepts :f as the function key' do
        history = [
          { type: :invoke, process: 1, f: :enq, value: 7 },
          { type: :ok, process: 1, f: :enq },
          { type: :invoke, process: 2, f: :deq },
          { type: :ok, process: 2, f: :deq, value: 7 }
        ]
        expect(described_class.check(history, initial_state: [], &queue_step))
          .to be_linearizable
      end
    end

    context 'with malformed histories' do
      it 'rejects a return without an invocation' do
        expect do
          described_class.check([[:ok, 1, :deq, 0]], initial_state: [], &queue_step)
        end.to raise_error(ArgumentError, /without a matching invocation/)
      end

      it 'rejects nested invocations on one process' do
        history = [[:invoke, 1, :enq, 1], [:invoke, 1, :enq, 2]]
        expect do
          described_class.check(history, initial_state: [],
                                        pending_policy: :discard, &queue_step)
        end.to raise_error(ArgumentError, /before its previous operation returned/)
      end
    end

    context 'with a custom stable state key' do
      let(:rich_step) do
        lambda do |(content, _meta), op|
          case op.function
          when :enq then [content + [op.arguments], :ok]
          when :deq
            next described_class.REJECT if content.empty?

            if op.result == content.first
              [content.drop(1), :ok]
            else
              described_class.REJECT
            end
          end
        end
      end

      it 'merges equivalent branches with non-identical model states' do
        history = [
          [:invoke, 1, :enq, 0], [:invoke, 2, :enq, 1],
          [:ok, 1, :enq], [:ok, 2, :enq],
          [:invoke, 3, :deq], [:ok, 3, :deq, 0],
          [:invoke, 4, :deq], [:ok, 4, :deq, 1]
        ]
        result = described_class.check(
          history,
          initial_state: [[], :start],
          key: ->(state) { state.first },
          &rich_step
        )
        expect(result).to be_linearizable
      end
    end
  end

  describe '.assert_linearizable' do
    it 'returns the result for a linearizable history' do
      history = [
        [:invoke, 1, :enq, 0], [:ok, 1, :enq],
        [:invoke, 2, :deq], [:ok, 2, :deq, 0]
      ]
      result = described_class.assert_linearizable(history, initial_state: [], &queue_step)
      expect(result).to be_linearizable
    end

    it 'raises a NonLinearizableError carrying the check result' do
      history = [
        [:invoke, 1, :deq], [:ok, 1, :deq, 0]
      ]
      expect do
        described_class.assert_linearizable(history, initial_state: [], &queue_step)
      end.to raise_error(described_class::NonLinearizableError) do |error|
        expect(error.result).to be_non_linearizable
        expect(described_class.check(error.result.history, initial_state: [],
                                                 minimize: false, &queue_step))
          .to be_non_linearizable
      end
    end

    it 'raises when the search is undecided' do
      history = [
        [:invoke, 1, :deq], [:ok, 1, :deq, 1]
      ]
      expect do
        described_class.assert_linearizable(history, initial_state: [],
                                                     budget: 0, &queue_step)
      end.to raise_error(described_class::NonLinearizableError, /undecided/)
    end
  end

  describe 'property: legal random sequential schedules' do
    it 'is always linearizable' do
      values_gen = array(choose(0..3), min: 1, max: 6)
      PropCheck.forall(values: values_gen) do |values:|
        # Simulate a correct FIFO queue with genuine cross-thread overlap.
        # Two enqueues are in flight together (one per thread) and their
        # results return in reverse order; two dequeues likewise overlap.
        # Every dequeue result comes from the real FIFO order, so the
        # resulting history must be linearizable.
        history = []
        if values.size == 1
          history << [:invoke, 0, :enq, values.first]
          history << [:ok, 0, :enq]
          history << [:invoke, 1, :deq]
          history << [:ok, 1, :deq, values.first]
        else
          history << [:invoke, 0, :enq, values[0]]
          history << [:invoke, 1, :enq, values[1]]
          history << [:ok, 1, :enq]
          history << [:ok, 0, :enq]
          values.drop(2).each do |value|
            history << [:invoke, 0, :enq, value]
            history << [:ok, 0, :enq]
          end

          history << [:invoke, 0, :deq]
          history << [:invoke, 1, :deq]
          history << [:ok, 0, :deq, values[0]]
          history << [:ok, 1, :deq, values[1]]
          values.drop(2).each do |value|
            history << [:invoke, 1, :deq]
            history << [:ok, 1, :deq, value]
          end
        end

        described_class.assert_linearizable(history, initial_state: [], &queue_step)
      end
    end

    it 'finds a counterexample when dequeue results do not match FIFO' do
      # Enqueue [0, 1] sequentially; overlapping consumers returning
      # [1, 0] cannot both be right for a FIFO queue when the enqueues were
      # themselves sequential... unless enqueues overlap. Here they do not.
      bad = [
        [:invoke, 1, :enq, 0], [:ok, 1, :enq],
        [:invoke, 2, :enq, 1], [:ok, 2, :enq],
        [:invoke, 3, :deq], [:invoke, 4, :deq],
        [:ok, 3, :deq, 1], [:ok, 4, :deq, 1]
      ]
      result = described_class.check(bad, initial_state: [], &queue_step)
      expect(result).to be_non_linearizable
    end
  end
end
