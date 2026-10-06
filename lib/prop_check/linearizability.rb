# frozen_string_literal: true

module PropCheck
  ##
  # = Linearizability checking for short concurrent histories
  #
  # A *history* is a sequence of invocation/return boundary events observed
  # while a concurrent data structure was exercised. Each completed
  # operation is a pair of entries:
  #
  #   [:invoke, process, function, arguments]
  #   [:ok,     process, function, result]
  #
  # Entries may also be keyword hashes:
  # `{ type: :invoke, process: 1, f: :enqueue, value: 0 }`.
  #
  # Entries are kept in the given order, which is taken to be the real-time
  # order of the boundary events. Entries of the same process must not
  # interleave; the process of a return entry must match the process of the
  # unmatched invocation it completes.
  #
  # A history is *linearizable* when every completed operation can be placed
  # in some total order that:
  #
  # 1. respects real time: if operation A returned before operation B was
  #    invoked, A must come first;
  # 2. is legal with respect to the sequential model supplied by the user.
  #
  # The checker implements the classic bounded search of Wing & Gong
  # (1993): completed operations whose invocation interval is still open are
  # pooled and may be linearised in any order; whenever a new invocation
  # boundary is reached, every earlier, already-completed operation is first
  # forced into the order, which enforces real time.
  #
  # Operations whose result is :fail are known failures and are removed
  # from the history before searching (they never take effect).
  #
  # Invocations without a matching return are treated per the
  # `pending_policy:` option:
  #
  # * :discard  – the operation never took effect and is removed;
  # * :complete – the operation is assumed to take effect after the last
  #   observed boundary; the step block is called with result nil;
  # * nil (default) – an ArgumentError is raised, forcing the caller to
  #   state explicitly how such operations should be handled.
  #
  # If the search exceeds `budget` attempted model steps, the verdict is
  # :undecided; it is never reported as non-linearizable.
  module Linearizability
    ##
    # Sentinel returned by a model step to reject a tentative ordering.
    REJECT = :__prop_check_linearizability_reject__

    ##
    # One call against the system under test.
    Operation = Struct.new(:id, :process, :function, :arguments, :result, :pending,
                           keyword_init: true) do
      def pending?
        pending
      end
    end

    ## A single invocation or return boundary entry.
    Record = Struct.new(:type, :process, :function, :value, :operation_id,
                        keyword_init: true)

    ##
    # Outcome of a check.
    #
    # `verdict` is one of :linearizable, :non_linearizable, :undecided.
    # `witness` is an array of {PropCheck::Linearizability::Operation}
    # describing a legal sequential order. `history` is a normalised,
    # replayable copy of the checked history; for non-linearizable histories
    # it is shrunk to a small failing history.
    Result = Struct.new(:verdict, :witness, :history, :steps_tried,
                        keyword_init: true) do
      def linearizable?
        verdict == :linearizable
      end

      def non_linearizable?
        verdict == :non_linearizable
      end

      def undecided?
        verdict == :undecided
      end
    end

    class << self
      ## Builds an invocation boundary entry.
      def invoke(process, function, arguments = nil)
        Record.new(type: :invoke, process: process, function: function, value: arguments)
      end

      ## Builds a successful return boundary entry.
      def ok(process, function, result = nil)
        Record.new(type: :ok, process: process, function: function, value: result)
      end

      ##
      # Builds a failed return boundary entry. Failed operations are removed
      # from the history before searching.
      def fail(process, function, result = nil)
        Record.new(type: :fail, process: process, function: function, value: result)
      end

      ## Builds an information-only marker entry (ignored by the search).
      def info(process, function, value = nil)
        Record.new(type: :info, process: process, function: function, value: value)
      end

      ##
      # Checks `history` against the sequential model defined by `step`.
      #
      # `step` is called as `step.call(state, operation)` where
      # `operation` is a {PropCheck::Linearizability::Operation}. It must
      # return the next model state, or {REJECT} when the operation cannot
      # happen in that state.
      #
      # Options:
      #
      # * `initial_state:` state before any operation (default nil).
      # * `key:` block mapping a model state to a stable key used to merge
      #   equivalent search branches (default: the state itself).
      # * `budget:` maximum number of attempted model steps before giving
      #   up (default 10_000).
      # * `pending_policy:` :discard or :complete (see module docs).
      # * `minimize:` when false, the non-linearizable history is returned
      #   without shrinking (default true).
      def check(history, initial_state: nil, budget: 10_000, pending_policy: nil,
                minimize: true, key: nil, &step)
        raise ArgumentError, 'a block describing the sequential model is required' unless block_given?
        unless pending_policy.nil? || %i[discard complete].include?(pending_policy)
          raise ArgumentError,
                "unknown pending_policy #{pending_policy.inspect}; expected :discard or :complete"
        end

        records, operations = normalize(history)
        if operations.each_value.any?(&:pending?) && pending_policy.nil?
          raise ArgumentError,
                'history contains unreturned operations; pass pending_policy: :discard or :complete'
        end
        verdict, witness, steps_tried =
          run_search(records, operations, initial_state, budget, pending_policy, step, key)

        result_history =
          if verdict == :non_linearizable && minimize
            minimize_history(records, initial_state, budget, pending_policy, step, key)
          else
            replayable_records(records)
          end

        Result.new(
          verdict: verdict,
          witness: witness,
          history: result_history,
          steps_tried: steps_tried
        )
      end

      ##
      # Like {#check}, but raises {NonLinearizableError} whenever the history
      # is not confirmed linearizable (including budget-exhausted searches).
      # Intended for use inside a PropCheck.forall property.
      def assert_linearizable(history, **options, &step)
        result = check(history, **options, &step)
        return result if result.linearizable?

        raise NonLinearizableError.new(result)
      end

      private

      def normalize(history)
        records = []
        operations = {}
        open_by_process = {}
        next_id = 0

        history.each do |entry|
          type, process, function, value = unpack_entry(entry)

          case type
          when :invoke
            if open_by_process.key?(process)
              raise ArgumentError,
                    "process #{process.inspect} invoked #{function.inspect} before its previous operation returned"
            end

            id = next_id
            next_id += 1
            operations[id] = Operation.new(
              id: id, process: process, function: function,
              arguments: value, result: nil, pending: true
            )
            open_by_process[process] = id
            records << Record.new(type: :invoke, process: process, function: function,
                                  value: value, operation_id: id)
          when :ok, :fail
            id = open_by_process.delete(process)
            if id.nil?
              raise ArgumentError,
                    "#{type.inspect} entry for process #{process.inspect} without a matching invocation"
            end

            operation = operations.fetch(id)
            if function != operation.function
              raise ArgumentError,
                    "return of #{function.inspect} completes invocation of #{operation.function.inspect}"
            end

            operation.result = value
            operation.pending = false
            records << Record.new(type: type, process: process, function: function,
                                  value: value, operation_id: id)
          when :info
            records << Record.new(type: :info, process: process, function: function,
                                  value: value)
          else
            raise ArgumentError, "unknown history entry type #{type.inspect}"
          end
        end

        [records, operations]
      end

      def unpack_entry(entry)
        if entry.is_a?(Hash)
          [entry.fetch(:type), entry.fetch(:process),
           entry.fetch(:f, entry[:function]), entry[:value]]
        else
          entry
        end
      end

      def run_search(records, operations, initial_state, budget, pending_policy, step,
                     key_block)
        steps = 0
        exhausted = false

        key_of = ->(state) { key_block.nil? ? state : key_block.call(state) }

        apply_step = lambda do |state, operation|
          if steps >= budget
            exhausted = true
            next :budget
          end

          steps += 1
          next_state =
            begin
              step.call(state, operation)
            rescue StandardError
              REJECT
            end
          next_state == REJECT ? :reject : next_state
        end

        invoke_at = {}
        return_at = {}
        records.each_with_index do |record, index|
          case record.type
          when :invoke then invoke_at[record.operation_id] = index
          when :ok, :fail then return_at[record.operation_id] = index
          end
        end

        # Scan. Frontier tuple:
        #   [state, pool, prefix, deferred]
        #
        # At an invocation boundary the completed pool is drained against
        # the model, except for operations that overlap an invocation which
        # is still pending at the end of the history: those are deferred
        # (moved to +deferred+, in real-time boundary groups) and solved
        # together with the pending completions at the end, because the
        # pending completion could legally take effect before them.
        final_pending = operations.each_value.select(&:pending?).map(&:id)
        completion_pending = pending_policy == :complete ? final_pending : []
        frontier = [[initial_state, [], [], []]]

        # Drains the pool for real time. Operations overlapping a
        # final-pending invocation are kept aside (deferred) in groups whose
        # relative order against later invocations is fixed.
        drain = lambda do |frontiers, boundary_index|
          worklist = frontiers.dup
          survivors = []
          seen = {}

          until worklist.empty?
            state, pool, prefix, deferred = worklist.shift
            already_deferred = deferred.flat_map(&:last)
            overlaps_pending = pool.select do |id|
              next false if already_deferred.include?(id)

              completion_pending.any? do |pid|
                invoke_at.fetch(pid) < boundary_index &&
                  invoke_at.fetch(pid) < return_at.fetch(id)
              end
            end
            forced = pool - overlaps_pending
            new_group = [boundary_index, overlaps_pending - already_deferred]
            next_deferred =
              if overlaps_pending.empty?
                deferred
              else
                deferred + [new_group]
              end

            if forced.empty?
              survivors << [state, [], prefix, next_deferred]
              next
            end

            forced.each do |id|
              outcome = apply_step.call(state, operations.fetch(id))
              next if outcome == :reject || outcome == :budget

              candidate = [outcome, forced - [id], prefix + [id], next_deferred]
              signature = [key_of.call(outcome), candidate[1], candidate[2],
                           candidate[3]]
              next if seen.key?(signature)

              seen[signature] = true
              worklist << candidate
            end
          end

          survivors
        end

        records.each do |record|
          case record.type
          when :invoke
            index = invoke_at.fetch(record.operation_id)
            frontier = drain.call(frontier, index)
            return [:undecided, nil, steps] if exhausted && frontier.empty?
          when :ok
            id = record.operation_id
            frontier = frontier.map do |state, pool, prefix, deferred|
              [state, pool + [id], prefix, deferred]
            end
            frontier = merge_frontiers(frontier, key_of)
          when :fail, :info
            nil
          end
        end
        frontier = merge_frontiers(frontier, key_of)
        # Final boundary: drain the last pool, deferring ops that overlap a
        # pending invocation exactly like the in-history boundaries.
        last_index = records.size
        # Under :discard nothing is deferred during the scan, so the same
        # drain is correct for both policies here; under :complete it moves
        # the last overlapping ops into the final deferred group.
        frontier = drain.call(frontier, last_index)
        return [:undecided, nil, steps] if exhausted && frontier.empty?

        if pending_policy == :complete && final_pending.any?
          final_pending.each { |id| operations.fetch(id).pending = false }

          # Final joint search: the fixed prefix keeps its model-checked
          # order; every deferred boundary group is ordered after the prefix
          # and before anything invoked at that boundary (which is already
          # in a later prefix/group). Pending completions are inserted into
          # the deferred groups inside their invocation intervals.
          survivors = []
          frontier.each do |state, _pool, prefix, deferred|
            state_after_prefix = replay_prefix(initial_state, prefix,
                                               operations, apply_step)
            next if state_after_prefix.nil?

            order = solve_deferred(state_after_prefix, prefix, deferred,
                                  final_pending, invoke_at, return_at,
                                  operations, apply_step)
            survivors << order unless order.nil?
          end
          return [:undecided, nil, steps] if exhausted

          if survivors.empty?
            return [:non_linearizable, nil, steps]
          end

          order = survivors.first
          return [:linearizable, order.map { |id| operations.fetch(id) }, steps]
        end

        # :discard (or no pending ops): pending invocations never took effect.
        if frontier.empty?
          [:non_linearizable, nil, steps]
        else
          _state, _pool, order, _deferred = frontier.first
          [:linearizable, order.map { |id| operations.fetch(id) }, steps]
        end
      end

      # Replays a fixed prefix from the initial state, returning the state
      # reached (or nil when a step rejects or exhausts the budget).
      def replay_prefix(initial_state, prefix, operations, apply_step)
        state = initial_state
        prefix.each do |id|
          outcome = apply_step.call(state, operations.fetch(id))
          return nil if outcome == :reject || outcome == :budget

          state = outcome
        end
        state
      end

      # Solves the deferred tail. +deferred+ is a list of
      # [boundary_index, completed_ids] groups in real-time order: every op
      # of an earlier group precedes every op of a later group. Pending
      # completions overlap the groups and are inserted inside their
      # invocation intervals. Returns a full legal order (array of ids), or
      # nil when the budget is exhausted / no order is legal.
      def solve_deferred(state_after_prefix, prefix, deferred, pending_ids,
                         invoke_at, return_at, operations, apply_step)
        order = nil
        budget_hit = false

        # For each boundary group [boundary_index, ids], the completed ids
        # must all be placed before the next group, and any pending op
        # invoked before that boundary may be interleaved with them (it
        # overlaps them by construction). Pending ops may also be skipped
        # here and placed in a later group / at the end.
        solve_group = lambda do |state, groups, pending_left, built_order|
          if groups.empty?
            # All remaining pending ops complete at the end, in any order.
            finish = lambda do |st, pend, ord|
              if pend.empty?
                order = ord
                return
              end

              pend.each do |pid|
                outcome = apply_step.call(st, operations.fetch(pid))
                if outcome == :budget
                  budget_hit = true
                  next
                end
                next if outcome == :reject

                finish.call(outcome, pend - [pid], ord + [pid])
                return if order
              end
            end
            finish.call(state, pending_left, built_order)
            return
          end

          boundary_index, group_ids = groups.first
          eligible = pending_left.select { |pid| invoke_at.fetch(pid) < boundary_index }

          interleave = nil
          interleave = lambda do |st, comp_left, pend_eligible, pend_later, ord|
            if comp_left.empty?
              solve_group.call(st, groups.drop(1), pend_eligible + pend_later, ord)
              return
            end

            comp_left.each do |cid|
              outcome = apply_step.call(st, operations.fetch(cid))
              if outcome == :budget
                budget_hit = true
                next
              end
              next if outcome == :reject

              interleave.call(outcome, comp_left - [cid], pend_eligible,
                              pend_later, ord + [cid])
              return if order
            end

            pend_eligible.each do |pid|
              outcome = apply_step.call(st, operations.fetch(pid))
              if outcome == :budget
                budget_hit = true
                next
              end
              next if outcome == :reject

              interleave.call(outcome, comp_left, pend_eligible - [pid],
                              pend_later, ord + [pid])
              return if order
            end
          end
          interleave.call(state, group_ids, eligible, pending_left - eligible,
                          built_order)
        end

        solve_group.call(state_after_prefix, deferred, pending_ids, prefix)
        return nil if budget_hit && order.nil?

        order
      end
      def merge_frontiers(frontier, key_of)
        grouped = {}
        frontier.each do |state, pool, prefix, deferred|
          signature = [key_of.call(state), pool, deferred]
          grouped[signature] ||= [state, pool, prefix, deferred]
        end
        grouped.values
      end

      def minimize_history(records, initial_state, budget, pending_policy, step,
                           key_block)
        pairs = operation_pairs(records)
        kept = pairs.keys

        changed = true
        while changed
          changed = false

          kept.dup.each do |id|
            candidate_records = pairs.values_at(*(kept - [id])).flatten
            verdict, = search_records(candidate_records, initial_state, budget,
                                      pending_policy, step, key_block)
            next unless verdict == :non_linearizable

            kept.delete(id)
            changed = true
          end
        end

        replayable_records(pairs.values_at(*kept).flatten)
      end

      def operation_pairs(records)
        pairs = {}
        records.each do |record|
          next unless record.operation_id

          (pairs[record.operation_id] ||= []) << record
        end
        pairs
      end

      def search_records(records, initial_state, budget, pending_policy, step,
                         key_block)
        operations = {}
        records.each do |record|
          next unless record.operation_id

          id = record.operation_id
          operations[id] ||= Operation.new(
            id: id, process: record.process, function: record.function,
            arguments: nil, result: nil, pending: true
          )
          operation = operations.fetch(id)
          case record.type
          when :invoke
            operation.arguments = record.value
          when :ok, :fail
            operation.result = record.value
            operation.pending = false
          end
        end
        run_search(records, operations, initial_state, budget, pending_policy, step,
                   key_block)
      end

      def replayable_records(records)
        records.map do |record|
          [record.type, record.process, record.function, record.value]
        end
      end
    end

    ##
    # Raised by {Linearizability.assert_linearizable} for non-linearizable
    # or undecided histories. Carries the check result in +result+.
    class NonLinearizableError < PropCheck::Errors::UserError
      attr_reader :result

      def initialize(result)
        @result = result
        super(build_message(result))
      end

      private

      def build_message(result)
        case result.verdict
        when :undecided
          "linearizability undecided after #{result.steps_tried} model steps (budget exhausted)"
        else
          "history is not linearizable; minimal failing history: #{result.history.inspect}"
        end
      end
    end
  end
end
