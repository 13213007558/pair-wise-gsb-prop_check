require 'pp'
require 'set'

module PropCheck
  module Linearizability
    Operation = Struct.new(:id, :index, :name, :args, :result, :call_time, :return_time, :thread,
                           :pending) do
      def completed?
        !pending
      end

      def pending?
        pending
      end

      def arguments
        args
      end

      def params
        args
      end

      def operation
        name
      end

      def returns
        result
      end

      def thread_id
        thread
      end

      def invocation_time
        call_time
      end

      def completion_time
        return_time
      end

      def to_h
        {
          id: id,
          name: name,
          arguments: args,
          result: result,
          call_time: call_time,
          return_time: return_time,
          thread_id: thread,
          pending: pending
        }
      end
    end

    class Outcome
      attr_reader :status, :witness, :witness_ids, :discarded_operations, :history,
                  :small_history, :attempts, :budget

      def initialize(status, history:, witness: nil, discarded_operations: [], small_history: nil,
                     attempts: 0, budget: nil)
        @status = status
        @history = history
        @witness = witness || []
        @witness_ids = @witness.map(&:id)
        @discarded_operations = discarded_operations
        @small_history = small_history
        @attempts = attempts
        @budget = budget
      end

      def linearizable?
        status == :linearizable
      end

      def nonlinearizable?
        status == :nonlinearizable
      end

      def undetermined?
        status == :undetermined
      end

      def budget_exceeded?
        undetermined?
      end

      def to_h
        {
          status: status,
          witness: witness.map(&:to_h),
          witness_ids: witness_ids,
          discarded_operations: discarded_operations.map(&:to_h),
          history: history.map(&:to_h),
          small_history: small_history&.map(&:to_h),
          attempts: attempts,
          budget: budget
        }
      end
    end

    class NonLinearizableError < PropCheck::Errors::UserError
      attr_reader :outcome

      def initialize(outcome)
        @outcome = outcome
        super(build_message)
      end

      def small_history
        outcome.small_history
      end

      private

      def build_message
        replayable_history = small_history.map(&:to_h)
        "History is not linearizable. Small replayable history:\n" + PP.pp(replayable_history, +"")
      end
    end

    class UndeterminedError < PropCheck::Errors::UserError
      attr_reader :outcome

      def initialize(outcome)
        @outcome = outcome
        super("Linearizability search exhausted its budget after #{outcome.attempts} model calls; " \
              "the result is undetermined, not non-linearizable.")
      end
    end

    def self.check(history, model = nil, initial_state: nil, state_key: nil, pending: :complete,
                   budget: 10_000, minimize: true, &model_block)
      checker = model || model_block
      raise ArgumentError, 'A sequential model callable or block is required.' unless checker.respond_to?(:call)
      raise ArgumentError, 'budget cannot be negative.' if budget && budget.negative?
      raise ArgumentError, "unknown pending policy #{pending.inspect}." unless %i[complete discard].include?(pending)

      operations = Normalizer.call(history)
      stable_key = state_key || ->(state) { state }
      raise ArgumentError, 'state_key must respond to #call.' unless stable_key.respond_to?(:call)

      outcome = Searcher.call(
        operations,
        model: checker,
        initial_state: initial_state,
        state_key: stable_key,
        pending_policy: pending,
        budget: budget
      )

      if outcome.nonlinearizable? && minimize
        small_history = Minimizer.call(
          operations,
          model: checker,
          initial_state: initial_state,
          state_key: stable_key,
          pending_policy: pending,
          budget: budget
        )
        outcome = Outcome.new(
          :nonlinearizable,
          history: operations,
          small_history: small_history,
          attempts: outcome.attempts,
          budget: budget
        )
      elsif outcome.nonlinearizable?
        outcome = Outcome.new(
          :nonlinearizable,
          history: operations,
          small_history: operations,
          attempts: outcome.attempts,
          budget: budget
        )
      end

      outcome
    end

    def self.linearize(history, model = nil, **options, &block)
      check(history, model, **options, &block)
    end

    def self.assert_linearizable!(history, model = nil, **options, &block)
      outcome = check(history, model, **options, &block)
      raise NonLinearizableError, outcome if outcome.nonlinearizable?
      raise UndeterminedError, outcome if outcome.undetermined?

      outcome
    end

    module Normalizer
      extend self

      def call(history)
        raise PropCheck::Errors::UserError, 'history must be an array.' unless history.is_a?(Array)

        used_ids = {}
        history.each_with_index.map do |raw, index|
          op = raw.is_a?(Operation) ? from_operation(raw, index) : from_hash(raw, index)
          validate!(op, used_ids)
          used_ids[op.id] = true
          op
        end
      end

      private

      def from_operation(operation, index)
        Operation.new(
          operation.id.nil? ? index : operation.id,
          index,
          operation.name,
          operation.args,
          operation.result,
          operation.call_time,
          operation.return_time,
          operation.thread,
          operation.pending
        )
      end

      def from_hash(raw, index)
        unless raw.is_a?(Hash)
          raise PropCheck::Errors::UserError, "operation at index #{index} must be a hash or Operation."
        end

        name = first_present(raw, :name, :operation, :op)
        call_time = first_present(raw,
                                  :call_time, :call, :start, :start_time, :invoked_at, :invocation_time)
        return_time = first_present(raw,
                                    :return_time, :return, :finish, :finish_time, :end, :end_time,
                                    :completed_at, :completion_time)
        pending = raw.key?(:pending) ? raw[:pending] : return_time.nil?
        args = first_present(raw, :arguments, :args, :params, :input, default: [])
        result = first_present(raw, :result, :returns, :return_value, :output, default: nil)
        thread = raw.fetch(:thread_id) { raw.fetch(:thread, nil) }

        Operation.new(raw.fetch(:id, index), index, name, args, result, call_time, return_time,
                      thread, pending)
      end

      def validate!(op, used_ids)
        if op.name.nil?
          raise PropCheck::Errors::UserError, "operation at index #{op.index} requires a name."
        end
        if op.call_time.nil?
          raise PropCheck::Errors::UserError, "operation #{op.id.inspect} requires a call time."
        end
        unless op.pending.equal?(true) || op.pending.equal?(false)
          raise PropCheck::Errors::UserError, "operation #{op.id.inspect} pending flag must be true or false."
        end
        if used_ids.key?(op.id)
          raise PropCheck::Errors::UserError, "duplicate operation id #{op.id.inspect}."
        end

        validate_times!(op)
      end

      def validate_times!(op)
        ordered?(op.call_time, op.call_time)
        if op.pending
          unless op.return_time.nil?
            raise PropCheck::Errors::UserError,
                  "pending operation #{op.id.inspect} must not have a return time."
          end

          return
        end
        if op.return_time.nil?
          raise PropCheck::Errors::UserError,
                "completed operation #{op.id.inspect} requires a return time."
        end

        ordered?(op.return_time, op.return_time)
        return unless ordered?(op.return_time, op.call_time) < 0

        raise PropCheck::Errors::UserError,
              "operation #{op.id.inspect} returns before it was called."
      rescue ArgumentError, NoMethodError
        raise PropCheck::Errors::UserError,
              "operation #{op.id.inspect} has incomparable call/return times."
      end

      def ordered?(left, right)
        result = left <=> right
        unless result.is_a?(Integer)
          raise PropCheck::Errors::UserError, 'incomparable call/return times.'
        end

        result
      end

      def first_present(hash, *keys, default: nil)
        keys.each do |key|
          return hash.fetch(key) if hash.key?(key)
        end
        default
      end
    end

    class Searcher
      def initialize(operations, model:, initial_state:, state_key:, pending_policy:, budget:)
        @operations = operations
        @initial_state = initial_state
        @model = model
        @state_key = state_key
        @pending_policy = pending_policy
        @remaining_budget = budget
        @original_budget = budget
        @attempts = 0
        @dead = {}
        @active = Set.new
      end

      def self.call(operations, **options)
        new(operations, **options).call
      end

      def call
        @executable = @pending_policy == :discard ? @operations.select(&:completed?) : @operations
        @discarded = @pending_policy == :discard ? @operations.select(&:pending?) : []
        @completed = @operations.select(&:completed?)
        @required_count = @executable.size

        status, witness = search(@initial_state, 0, [], Set.new)
        case status
        when :linearizable
          Outcome.new(:linearizable, history: @operations, witness: witness,
                      discarded_operations: @discarded, attempts: @attempts, budget: @original_budget)
        when :budget
          Outcome.new(:undetermined, history: @operations, discarded_operations: @discarded,
                      attempts: @attempts, budget: @original_budget)
        else
          Outcome.new(:nonlinearizable, history: @operations, discarded_operations: @discarded,
                      attempts: @attempts, budget: @original_budget)
        end
      end

      private

      def search(state, used, path, active)
        return [:linearizable, path] if used_bits(used) == @required_count
        candidates = @executable.reject { |op| bit_used?(used, op) }.select { |op| eligible?(op, used) }
        return [:dead_end, nil] if candidates.empty?
        return [:budget, nil] if budget_exhausted?

        key = nil
        begin
          key = memo_key(state, used)
          return [:dead_end, nil] if @dead.key?(key)
          return [:skipped, nil] if active.include?(key)
        rescue TypeError, NoMethodError
          raise PropCheck::Errors::UserError,
                'state_key must return a hashable, stable key.'
        end

        active.add(key)
        found_budget = false
        candidates.each do |operation|
          status, next_state = apply(state, operation)
          next if status == :mismatch
          if status == :budget
            found_budget = true
            break
          end

          next_used = used | bit_for(operation)
          next_active = active.dup
          result, found_witness = search(next_state, next_used, path + [operation], next_active)
          return [result, found_witness] if result == :linearizable
          found_budget = true if result == :budget
        end

        active.delete(key)
        return [:budget, nil] if found_budget

        @dead[key] = true
        [:dead_end, nil]
      end

      def apply(state, operation)
        if @remaining_budget && @remaining_budget.zero?
          return [:budget, nil]
        end

        @remaining_budget -= 1 if @remaining_budget
        @attempts += 1

        model_result = @model.call(state, operation)
        unless model_result.is_a?(Array) && model_result.length == 2
          raise PropCheck::Errors::UserError,
                "model must return [new_state, expected_result] for operation #{operation.id.inspect}."
        end

        next_state, expected_result = model_result
        if operation.completed? && !observed_matches?(operation.result, expected_result)
          [:mismatch, nil]
        else
          [:applied, next_state]
        end
      end

      def observed_matches?(observed, expected)
        observed == expected
      end

      def eligible?(operation, used)
        @completed.all? do |other|
          next true if other.id == operation.id
          next true if bit_used?(used, other)
          next true unless other.return_time <= operation.call_time

          false
        end
      end

      def memo_key(state, used)
        [@state_key.call(state), used]
      end

      def bit_for(operation)
        1 << operation.index
      end

      def bit_used?(used, operation)
        bit = bit_for(operation)
        used & bit == bit
      end

      def used_bits(used)
        used.to_s(2).count('1')
      end

      def budget_exhausted?
        @remaining_budget && @remaining_budget.zero?
      end
    end

    module Minimizer
      extend self

      def call(operations, model:, initial_state:, state_key:, pending_policy:, budget:)
        current = operations

        loop do
          removed = false
          current.each do |operation|
            candidate = normalize(current.reject { |item| item.id == operation.id })
            outcome = Searcher.call(
              candidate,
              model: model,
              initial_state: initial_state,
              state_key: state_key,
              pending_policy: pending_policy,
              budget: budget
            )
            next unless outcome.nonlinearizable?

            current = candidate
            removed = true
            break
          end

          break unless removed
        end

        current
      end

      private

      def normalize(operations)
        Normalizer.call(operations.map(&:to_h))
      end
    end

    private_constant :Normalizer, :Searcher, :Minimizer
  end
end
