require 'prop_check/helper'

##
# @api private
# Runs a property check using multiple worker threads.
#
# _Note: This class is an implementation detail of PropCheck._
#
# The coordinating thread (the one calling `#run`) hands out attempt
# indices to a fixed number of worker threads. Each worker deterministically
# generates the sample for its attempt and checks it, with the
# before/after/around hooks wrapped around that attempt, exactly like
# happens during a sequential run.
#
# Workers are allowed to finish out of order, but the coordinator only
# decides on the final outcome of the run once the results of all earlier
# attempts are known: the reported counterexample is always the failing
# sample with the lowest index, just like a sequential run would find.
# As soon as this decision is made, no new work is started and any
# still-queued attempts are discarded, so `#run` returns (and shrinking
# can happen in the coordinating thread) as early as possible.
#
# The amount of work generated ahead of time is bounded:
# at most `n_workers` attempts are being worked on,
# with at most `n_workers` more waiting in the bounded work queue.
class PropCheck::Property::ParallelRunner
  ##
  # The final result of a parallel run,
  # consumed by `PropCheck::Property#check`.
  Outcome = Struct.new(:status, :index, :generator_result, :exception, keyword_init: true)

  # Internal result of a single attempt, sent from a worker to the coordinator.
  AttemptResult = Struct.new(:index, :status, :generator_result, :exception, keyword_init: true) do
    def pass?
      status == :pass
    end
  end

  # `generate_attempt` is a callable that, given an attempt index,
  # deterministically generates the sample for that attempt.
  # (c.f. `PropCheck::Property#generate_attempt`)
  def initialize(generate_attempt, hooks, config)
    @generate_attempt = generate_attempt
    @hooks = hooks
    @config = config
    @n_workers = config.n_workers
    # Attempts at or beyond `limit` can never influence the result of the run.
    @limit = [@config.n_runs, @config.max_generate_attempts].min
    # Bounds the amount of not-yet-started work,
    # so inputs are never all generated at once.
    @work_queue = SizedQueue.new(@n_workers)
    @result_queue = Queue.new
  end

  def run(&block)
    workers = Array.new(@n_workers) { Thread.new { work_loop(&block) } }
    outcome = coordinate
    stop_workers
    workers.each(&:join)
    outcome
  end

  private

  # Each worker keeps taking attempts from the work queue,
  # until the queue is closed and drained by the coordinator.
  # Attempts that were still queued when the coordinator decided
  # the outcome are discarded without running them.
  def work_loop(&block)
    loop do
      index = @work_queue.pop
      break if index.nil? || @work_queue.closed?

      @result_queue << run_attempt(index, &block)
    end
  end

  # Runs a single attempt, with the hooks wrapped around generation
  # and checking, exactly like the sequential runner does.
  # The `ensure` inside `PropCheck::Hooks#call` guarantees that
  # the after-hooks run even when the check raises.
  def run_attempt(index, &block)
    generator_result = nil
    @hooks.call do
      generator_result = @generate_attempt.call(index)
      PropCheck::Helper.call_splatted(generator_result.root, &block)
    end
    AttemptResult.new(index: index, status: :pass)
  rescue SignalException, SystemExit => exception
    AttemptResult.new(index: index, status: :interrupted, exception: exception)
  rescue Exception => exception
    if generator_result
      AttemptResult.new(index: index, status: :failure,
                        generator_result: generator_result, exception: exception)
    else
      AttemptResult.new(index: index, status: :generation_error, exception: exception)
    end
  end

  # The main coordination loop: dispatches new attempts while capacity
  # allows, and collects results (which may arrive out of order).
  # A final decision is only made once the results of all earlier
  # attempts are known.
  def coordinate
    results = {}
    next_index = 0

    loop do
      next_index = dispatch(next_index)

      outcome = decide(results)
      return outcome if outcome

      result = @result_queue.pop
      results[result.index] = result
    end
  end

  # Fills the work queue without blocking, so at most `n_workers`
  # attempts are waiting to be started (and at most `n_workers` more
  # are currently being worked on).
  def dispatch(next_index)
    while next_index < @limit
      begin
        @work_queue.push(next_index, true)
      rescue ThreadError
        break
      end
      next_index += 1
    end
    next_index
  end

  # Looks at the results known so far and decides whether the final
  # outcome of the run is already certain.
  def decide(results)
    # The earliest attempt whose result is not yet known.
    first_unknown = (0...@limit).find { |index| !results.key?(index) }
    known_upto = first_unknown || @limit

    # The earliest non-passing attempt whose predecessors all passed
    # determines the final outcome, regardless of the order
    # in which later attempts finished.
    decisive = (0...known_upto).find { |index| !results[index].pass? }
    return final_outcome(results[decisive]) if decisive

    return unless known_upto == @limit

    # All attempts finished successfully.
    if @limit < @config.n_runs
      Outcome.new(status: :exhausted)
    else
      Outcome.new(status: :success)
    end
  end

  def final_outcome(result)
    case result.status
    when :failure
      Outcome.new(status: :failure, index: result.index,
                  generator_result: result.generator_result, exception: result.exception)
    else
      # Interrupts and generation errors are reraised as-is,
      # exactly like they propagate in a sequential run.
      Outcome.new(status: :error, index: result.index, exception: result.exception)
    end
  end

  # Stops the workers as soon as the outcome is decided:
  # no new attempts are started and queued attempts are discarded.
  # Attempts already in flight finish (running their hooks to completion)
  # before `#run` returns.
  def stop_workers
    @work_queue.close
  end
end

