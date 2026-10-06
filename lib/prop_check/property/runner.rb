# frozen_string_literal: true

require 'thread'

class PropCheck::Property::Runner
  Result = Struct.new(
    :index,
    :status,
    :tree,
    :exception,
    :successful_before,
    keyword_init: true
  )

  def initialize(generator, hooks, config, &block)
    @generator = generator
    @hooks = hooks
    @config = config
    @block = block
    @master_rng = config.seed.nil? ? Random.new : Random.new(config.seed)
  end

  def call
    return run_serially if @config.workers == 1

    run_parallel
  end

  private

  def run_serially
    successful = 0
    next_index = 0

    while successful < @config.n_runs && next_index < @config.max_generate_attempts do
      result = run_case(next_index, successful, child_rng)
      next_index += 1

      return [successful, result] unless result.status == :success

      successful += 1
    end

    [successful, nil]
  end

  def run_parallel
    return [0, nil] if @config.n_runs.zero?

    worker_count = [@config.workers, @config.n_runs].min
    mutex = Mutex.new
    condition = ConditionVariable.new
    state = ParallelState.new(worker_count)
    workers = []

    mutex.synchronize { fill_jobs(state, mutex, condition) }

    worker_count.times do
      workers << start_worker(state, mutex, condition)
    end

    successful = 0
    buffered = {}
    next_index = 0
    selected = nil

    loop do
      message = nil
      mutex.synchronize do
        condition.wait(mutex) while state.results.empty? && !state.finished?
        message = state.results.shift
      end

      break if message.nil?

      buffered[message.index] = message

      while buffered.key?(next_index)
        result = buffered.delete(next_index)
        consumed_index = next_index
        next_index += 1

        if result.status == :success
          successful += 1
          mutex.synchronize do
            state.successful = successful
            state.processed = consumed_index + 1
            fill_jobs(state, mutex, condition)
          end
          break if successful >= @config.n_runs
        else
          result.successful_before = successful
          selected = result
          mutex.synchronize do
            state.processed = consumed_index + 1
            state.failure_seen = true
            stop_if_finished(state, mutex, condition)
          end
          break
        end
      end

      break if selected || successful >= @config.n_runs
    end

    mutex.synchronize do
      drain_results(state)
      stop_workers(state, condition) if selected || successful >= @config.n_runs
    end

    workers.each(&:join)

    return [@config.n_runs, nil] if selected.nil? && successful >= @config.n_runs

    [successful, selected]
  end

  def start_worker(state, mutex, condition)
    thread = Thread.new do
      loop do
        job = nil

        mutex.synchronize do
          condition.wait(mutex) while state.jobs.empty? && !state.finished?
          job = state.jobs.shift
        end

        break if job.nil?

        index, seed = job
        result = run_case(index, 0, Random.new(seed))

        mutex.synchronize do
          state.results << result
          state.completed += 1
          state.failure_seen = true if result.status != :success
          stop_if_finished(state, mutex, condition)
          condition.signal
        end
      end
    end
    thread.report_on_exception = false
    thread
  end

  def fill_jobs(state, mutex, condition)
    while state.next_index - state.processed < state.worker_count &&
          !state.failure_seen &&
          state.next_index < @config.n_runs &&
          state.next_index < @config.max_generate_attempts
      seed = child_seed(@master_rng)
      state.jobs << [state.next_index, seed]
      state.next_index += 1
      condition.signal
    end
  end

  def stop_if_finished(state, _mutex, condition)
    return unless state.results.empty? && state.jobs.empty? &&
                  state.next_index == state.completed

    state.finished = true
    condition.broadcast
  end

  def stop_workers(state, condition)
    state.failure_seen = true
    state.finished = true
    condition.broadcast
  end

  def drain_results(state)
    state.processed = state.completed
  end

  def run_case(index, successful_before, rng)
    generated = false
    property_exception = nil
    generated_tree = nil

    tree =
      @hooks.call do
        result = @generator.generate(
          size: @config.resize_function.call(index + 1).to_i,
          rng: rng,
          max_consecutive_attempts: @config.max_consecutive_attempts,
          config: @config
        )

        generated_tree = result
        generated = true
        begin
          PropCheck::Helper.call_splatted(result.root, &@block)
        rescue SignalException, SystemExit
          raise
        rescue Exception => e
          property_exception = e
          raise
        end

        result
      end

    Result.new(index: index, status: :success, tree: tree, successful_before: successful_before)
  rescue SignalException, SystemExit => e
    Result.new(index: index, status: :fatal, exception: e, successful_before: successful_before)
  rescue Exception => e
    status = generated && e.equal?(property_exception) ? :failure : :error
    Result.new(index: index, status: status, tree: generated_tree, exception: e,
               successful_before: successful_before)
  end

  def child_rng
    Random.new(child_seed(@master_rng))
  end

  def child_seed(rng)
    rng.bytes(8).unpack1('Q>')
  end

  class ParallelState
    attr_accessor :next_index, :successful, :failure_seen, :completed, :processed,
                  :worker_count, :jobs, :results, :finished

    def initialize(worker_count)
      @next_index = 0
      @successful = 0
      @failure_seen = false
      @completed = 0
      @processed = 0
      @worker_count = worker_count
      @jobs = []
      @results = []
      @finished = false
    end

    def finished?
      @finished
    end
  end
end
