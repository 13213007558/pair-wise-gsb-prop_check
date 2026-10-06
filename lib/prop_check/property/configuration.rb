module PropCheck
  class Property
    ## Configure PropCheck
    #
    # Configurations can be set globally,
    # but also overridden on a per-generator basis.
    # c.f. PropCheck.configure, PropCheck.configuration and PropCheck::Property#with_config
    #
    # ## Available options
    # - `verbose:` When true, shows detailed options of the data generation and shrinking process. (Default: false)
    # - `n_runs:` The amount of iterations each `forall` is being run.
    # - `n_workers:` The amount of parallel worker threads used to generate and check samples.
    #   When larger than 1, samples are speculatively checked in parallel, but the logical
    #   sequence of samples (and thus the counterexample that is found) is exactly the same
    #   as when running sequentially, given the same `seed`. (Default: 1)
    # - `max_generate_attempts:` The amount of times the library tries a generator in total
    #    before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `max_shrink_steps:` The amount of times shrinking is attempted. (Default: 10_000)
    # - `max_consecutive_attempts:` The amount of times the library tries a filtered generator consecutively
    #    again before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `default_epoch:` The 'base' value to use for date/time generators like
    #    `PropCheck::Generators#date` `PropCheck::Generators#future_date` `PropCheck::Generators#time`, etc.
    #    (Default: `DateTime.now`)
    # - `resize_function:` A proc that can be used to resize _all_ generators.
    #    Takes the current size as integer and should return a new integer.
    #   (Default: `proc { |size| size }`)
    # - `seed:` The seed from which the random number generator of each sample is derived.
    #   When `nil`, a random seed is picked on every run. Set it explicitly to make
    #   the generated samples reproducible. (Default: nil)
    Configuration = Struct.new(
      :verbose,
      :n_runs,
      :n_workers,
      :max_generate_attempts,
      :max_shrink_steps,
      :max_consecutive_attempts,
      :default_epoch,
      :resize_function,
      :seed,
      keyword_init: true
    ) do
      def initialize(
        verbose: false,
        n_runs: 100,
        n_workers: 1,
        max_generate_attempts: 10_000,
        max_shrink_steps: 10_000,
        max_consecutive_attempts: 30,
        default_epoch: DateTime.now,
        resize_function: proc { |size| size },
        seed: nil
      )
        super
      end

      def merge(other)
        Configuration.new(**to_h.merge(other.to_h))
      end
    end
  end
end
